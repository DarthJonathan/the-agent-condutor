//! One background owner of the existing stdio engine, with user-only local IPC.
use crate::{bridge::RunSummary, model::Run, remote, storage::Store};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    hash::{Hash, Hasher},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{Mutex, broadcast, mpsc, oneshot, watch},
};

#[derive(Default)]
pub struct Snapshot {
    pub state: Option<Value>,
    pub runs: HashMap<String, Arc<Value>>,
    pub remote_status: Option<Value>,
}
pub type Shared = Arc<Mutex<Snapshot>>;
pub struct Request {
    pub command: Value,
    pub done: Option<oneshot::Sender<Result<()>>>,
}

fn socket(root: &Path) -> Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    let directory = PathBuf::from(format!("/tmp/conductor-{}", unsafe { libc::geteuid() }));
    if !directory.exists() {
        let mut builder = fs::DirBuilder::new();
        builder.mode(0o700);
        let _ = builder.create(&directory);
    }
    let meta = fs::symlink_metadata(&directory)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        bail!("The private engine socket directory has unsafe permissions")
    }
    let mut hash = std::hash::DefaultHasher::new();
    root.hash(&mut hash);
    Ok(directory.join(format!("{:016x}.sock", hash.finish())))
}
fn runtime() -> Result<tokio::runtime::Runtime> {
    Ok(tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()?)
}
pub fn connect(data_dir: Option<PathBuf>) -> Result<()> {
    let root = Store::new(data_dir).root;
    fs::create_dir_all(&root)?;
    let root = root.canonicalize()?;
    runtime()?.block_on(async {
        let address = socket(&root)?;
        let mut connection = UnixStream::connect(&address).await;
        if connection.is_err() {
            use std::os::unix::process::CommandExt;
            let mut child = std::process::Command::new(std::env::current_exe()?);
            child.args(["--daemon", "--data-dir"]).arg(&root).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
            // The host survives the UI process. No credentials enter its argv.
            unsafe { child.pre_exec(|| { libc::setsid(); Ok(()) }); }
            child.spawn()?;
            for _ in 0..100 { tokio::time::sleep(Duration::from_millis(100)).await; connection = UnixStream::connect(&address).await; if connection.is_ok() { break } }
        }
        let socket = connection.context("Could not attach to the background engine")?;
        let (mut incoming, mut outgoing) = socket.into_split();
        let mut stdin = tokio::io::stdin(); let mut stdout = tokio::io::stdout();
        tokio::select! { r = tokio::io::copy(&mut stdin, &mut outgoing) => { r?; }, r = tokio::io::copy(&mut incoming, &mut stdout) => { r?; } }
        Ok(())
    })
}
pub fn run(data_dir: Option<PathBuf>) -> Result<()> {
    let root = Store::new(data_dir).root;
    fs::create_dir_all(&root)?;
    runtime()?.block_on(serve(root.canonicalize()?))
}
async fn serve(root: PathBuf) -> Result<()> {
    use std::os::unix::{
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        io::AsRawFd,
    };
    let address = socket(&root)?;
    let lock_path = address.with_extension("lock");
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(lock_path)?;
    if lock.metadata()?.uid() != unsafe { libc::geteuid() } || lock.metadata()?.mode() & 0o077 != 0
    {
        bail!("Unsafe engine lock permissions")
    }
    while unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        if !std::env::args().any(|arg| arg == "--supervise") {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    let _ = fs::remove_file(&address);
    let listener = UnixListener::bind(&address)?;
    fs::set_permissions(&address, fs::Permissions::from_mode(0o600))?;
    let mut engine = tokio::process::Command::new(std::env::current_exe()?)
        .args(["--bridge", "--data-dir"])
        .arg(&root)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()?;
    let mut input = engine.stdin.take().unwrap();
    let mut output = BufReader::new(engine.stdout.take().unwrap()).lines();
    let (sender, mut requests) = mpsc::channel::<Request>(128);
    let (events, _) = broadcast::channel::<Arc<Value>>(32);
    let shared = Arc::new(Mutex::new(Snapshot::default()));
    let initial = remote::load(&root).await;
    let (config_sender, config_receiver) = watch::channel(initial);
    let remote_task = tokio::spawn(remote::serve(
        root.clone(),
        shared.clone(),
        sender.clone(),
        events.clone(),
        config_receiver,
    ));
    let clients = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let mut idle = tokio::time::interval(Duration::from_secs(2));
    idle.tick().await;
    let mut remote_config = config_sender.borrow().clone();
    let mut pending: HashMap<String, oneshot::Sender<Result<()>>> = HashMap::new();
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    loop {
        tokio::select! {
            _ = terminate.recv() => { break; },
            _ = tokio::signal::ctrl_c() => { break; },
            accepted = listener.accept() => {
                let (connection, _) = accepted?; let tx = sender.clone(); let rx = events.subscribe(); let current = shared.lock().await; let snapshot = current.state.clone(); let status = current.remote_status.clone().unwrap_or_else(|| remote::status(&remote_config, "connecting", None)); drop(current); let count = clients.clone(); count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                tokio::spawn(async move { let _ = client(connection, tx, rx, snapshot, status).await; count.fetch_sub(1, std::sync::atomic::Ordering::Relaxed); });
            },
            line = output.next_line() => {
                let Some(line) = line? else { break; };
                let Ok(event) = serde_json::from_str::<Value>(&line) else { continue };
                if event["type"] == "remote_result" && let Some(id) = event["request_id"].as_str() && let Some(done) = pending.remove(id) {
                    let result = if event["error"] == true { Err(anyhow::anyhow!("{}", event["message"].as_str().unwrap_or("Engine rejected command"))) } else { Ok(()) };
                    let _ = done.send(result);
                }
                { let mut current = shared.lock().await;
                  match event["type"].as_str() {
                    Some("state") => { current.state = Some(event.clone()); if let Some(runs) = event["runs"].as_array() { for run in runs { if let Some(id) = run["id"].as_str() { let _ = sender.try_send(Request{command:json!({"type":"get_run","run_id":id}),done:None}); } } } },
                    Some("run_updated"|"run_detail") => {
                        if let Some(id) = event["run"]["id"].as_str() { current.runs.insert(id.into(), Arc::new(event["run"].clone())); }
                        if let Ok(run) = serde_json::from_value::<Run>(event["run"].clone()) && let Some(state) = &mut current.state && let Some(runs) = state["runs"].as_array_mut() {
                            let summary = serde_json::to_value(RunSummary::from(&run))?;
                            if let Some(existing) = runs.iter_mut().find(|r| r["id"] == summary["id"]) { *existing = summary } else { runs.insert(0, summary); runs.truncate(100); }
                        }
                        if let Some(runs) = current.state.as_ref().and_then(|state| state["runs"].as_array()) {
                            let retained: std::collections::HashSet<String> = runs.iter().filter_map(|r|r["id"].as_str().map(str::to_owned)).collect();
                            current.runs.retain(|id,_|retained.contains(id));
                        }
                    },
                    Some("run_deleted") => { if let Some(id) = event["run_id"].as_str() { current.runs.remove(id); if let Some(state) = &mut current.state && let Some(runs) = state["runs"].as_array_mut() { runs.retain(|r| r["id"] != id); } } },
                    Some("agents_updated") => { if let Some(state) = &mut current.state { state["agents"] = event["agents"].clone() } },
                    Some("settings_updated") => { if let Some(state) = &mut current.state { state["settings"] = event["settings"].clone() } },
                    Some("claude_config_updated") => { if let Some(state) = &mut current.state { state["claude_config"] = event["claude_config"].clone(); state["model_catalogs"] = event["model_catalogs"].clone(); } },
                    _ => {}
                  }
                }
                if event["type"] != "settings_updated" { let _ = events.send(Arc::new(event)); }
            },
            Some(request) = requests.recv() => {
                let mut done = request.done;
                let kind = request.command["type"].as_str().unwrap_or("");
                let result = if kind == "remote_configure" {
                    match remote::configure(&root, &request.command).await {
                        Ok(config) => { remote_config = Some(config.clone()); config_sender.send_replace(Some(config)); remote::announce(&shared, &events, &remote_config, "connecting", None).await; Ok(()) },
                        Err(error) => Err(error),
                    }
                } else if kind == "remote_disable" {
                    remote_config = None; config_sender.send_replace(None); let _ = fs::remove_file(root.join("remote.json")); remote::announce(&shared, &events, &None, "disabled", None).await; Ok(())
                } else if kind == "shutdown" { Ok(()) } else if done.is_some() && !remote_config.as_ref().is_some_and(|config| request.command["_remote_device"] == serde_json::json!(config.device_id) && config.workspaces.iter().any(|w| request.command["_remote_workspace"] == serde_json::json!(w.id))) {
                    Err(anyhow::anyhow!("Remote permission changed before delivery"))
                } else if done.is_some() && request.command["_remote_expires"].as_str().and_then(|date|chrono::DateTime::parse_from_rfc3339(date).ok()).is_none_or(|date|date <= chrono::Utc::now()) {
                    Err(anyhow::anyhow!("Remote command expired before delivery"))
                } else {
                    let command = if done.is_some() { json!({"type":"remote_command","request_id":request.command["_remote_id"],"command":request.command}) } else { request.command.clone() };
                    let mut bytes = serde_json::to_vec(&command)?; bytes.push(b'\n');
                    let written = input.write_all(&bytes).await.map_err(anyhow::Error::from);
                    if written.is_ok() && let Some(reply) = done.take() { pending.insert(request.command["_remote_id"].as_str().unwrap_or("").into(), reply); }
                    written
                };
                if let Err(error) = &result { let _ = events.send(Arc::new(json!({"type":"notice","message":format!("{error:#}"),"error":true}))); }
                if let Some(done) = done { let _ = done.send(result); }
            },
            _ = idle.tick() => { pending.retain(|_, done| !done.is_closed()); if remote_config.is_none() && clients.load(std::sync::atomic::Ordering::Relaxed) == 0 { break } },
        }
    }
    remote_task.abort();
    let _ = input.write_all(b"{\"type\":\"shutdown\"}\n").await;
    let _ = tokio::time::timeout(Duration::from_secs(6), engine.wait()).await;
    let _ = fs::remove_file(address);
    Ok(())
}
async fn client(
    socket: UnixStream,
    sender: mpsc::Sender<Request>,
    mut events: broadcast::Receiver<Arc<Value>>,
    initial: Option<Value>,
    status: Value,
) -> Result<()> {
    let (read, mut write) = socket.into_split();
    let mut lines = BufReader::new(read).lines();
    if let Some(state) = initial {
        write_event(&mut write, &state).await?;
    }
    write_event(&mut write, &status).await?;
    loop {
        tokio::select! {
            line = lines.next_line() => { let Some(line) = line? else { break }; if line.len() > 1024*1024 { bail!("Local request exceeds 1 MiB") }; let request: Value = serde_json::from_str(&line)?; if request["type"] == "shutdown" { break }; sender.send(Request{command:request,done:None}).await?; },
            event = events.recv() => { match event { Ok(event) => write_event(&mut write, &event).await?, Err(_) => break } },
        }
    }
    Ok(())
}
async fn write_event<W: AsyncWriteExt + Unpin>(write: &mut W, event: &Value) -> Result<()> {
    let mut bytes = serde_json::to_vec(event)?;
    bytes.push(b'\n');
    write.write_all(&bytes).await?;
    Ok(())
}
