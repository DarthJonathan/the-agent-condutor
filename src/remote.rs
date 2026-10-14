//! Outbound-only HTTPS relay. Local settings and folder grants remain authoritative.
use crate::{
    host::{Request, Shared},
    model::{Effort, Provider, Settings},
    team,
};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    pub id: Uuid,
    pub label: String,
    pub path: PathBuf,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub backend_url: String,
    pub device_id: Uuid,
    pub email: String,
    pub workspaces: Vec<Workspace>,
    #[serde(default, skip_serializing)]
    pub token: String,
}
fn validate(config: &Config) -> Result<()> {
    let url = reqwest::Url::parse(&config.backend_url)?;
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        bail!("Remote servers require HTTPS; HTTP is allowed only on localhost")
    }
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        bail!("Enter a server origin without credentials, query or path")
    }
    if config.workspaces.len() > 50 || !config.token.starts_with("cdv_") || config.token.len() != 47
    {
        bail!("Invalid device enrollment")
    }
    let mut ids = std::collections::HashSet::new();
    for w in &config.workspaces {
        if !ids.insert(w.id)
            || w.label.is_empty()
            || w.label.len() > 160
            || w.path.canonicalize()? != w.path
            || !w.path.is_dir()
        {
            bail!("Share existing folders with distinct IDs")
        }
    }
    Ok(())
}
pub async fn configure(root: &Path, command: &Value) -> Result<Config> {
    let mut config: Config = serde_json::from_value(command["config"].clone())?;
    config.token = command["token"].as_str().unwrap_or("").into();
    validate(&config)?;
    private_save(&root.join("remote.json"), &config)?;
    Ok(config)
}
pub async fn load(root: &Path) -> Option<Config> {
    let mut config: Config =
        serde_json::from_slice(&fs::read(root.join("remote.json")).ok()?).ok()?;
    // The signed UI executable accesses its own Keychain entry without opening a window.
    let ui = std::env::current_exe()
        .ok()?
        .parent()?
        .join("agent-conductor");
    let mut helper = tokio::process::Command::new(ui);
    helper
        .args(["--remote-credential", &config.device_id.to_string()])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(10), helper.output())
        .await
        .ok()?
        .ok()?;
    if !output.status.success() {
        return None;
    }
    config.token = String::from_utf8(output.stdout).ok()?.trim().into();
    validate(&config).ok()?;
    Some(config)
}
pub fn status(config: &Option<Config>, state: &str, message: Option<&str>) -> Value {
    json!({"type":"remote_state","remote":{"state":if config.is_some(){state}else{"disabled"},"config":config,"message":message}})
}
pub async fn announce(
    shared: &Shared,
    events: &broadcast::Sender<Arc<Value>>,
    config: &Option<Config>,
    state: &str,
    message: Option<&str>,
) {
    let event = status(config, state, message);
    shared.lock().await.remote_status = Some(event.clone());
    let _ = events.send(Arc::new(event));
}
fn private_save<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    use std::{io::Write, os::unix::fs::OpenOptionsExt};
    let temp = path.with_extension(format!("{}.tmp", Uuid::new_v4()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    file.write_all(&serde_json::to_vec(value)?)?;
    file.sync_all()?;
    fs::rename(temp, path)?;
    Ok(())
}
pub async fn serve(
    root: PathBuf,
    shared: Shared,
    sender: mpsc::Sender<Request>,
    events: broadcast::Sender<Arc<Value>>,
    mut configurations: watch::Receiver<Option<Config>>,
) {
    loop {
        let config = configurations.borrow_and_update().clone();
        let Some(config) = config else {
            if configurations.changed().await.is_err() {
                break;
            };
            continue;
        };
        let result = tokio::select! {
            result = connected(&root,&config,&shared,&sender,&events) => Some(result),
            changed = configurations.changed() => { if changed.is_err(){break}; None },
        };
        if let Some(result) = result {
            let message = if result.is_err() {
                "Relay unavailable or device revoked. Commands are paused; reconnect or pair again."
            } else {
                "Remote sharing disconnected"
            };
            announce(&shared, &events, &Some(config), "offline", Some(message)).await;
            tokio::select! { _ = tokio::time::sleep(Duration::from_secs(5)) => {}, changed = configurations.changed() => { if changed.is_err(){break} } }
        }
    }
}
fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        .build()?)
}
async fn request(
    client: &reqwest::Client,
    config: &Config,
    method: reqwest::Method,
    path: &str,
    body: Option<&Value>,
) -> Result<Value> {
    let mut req = client
        .request(
            method,
            format!("{}/api/v1{path}", config.backend_url.trim_end_matches('/')),
        )
        .bearer_auth(&config.token);
    if let Some(body) = body {
        req = req.json(body)
    }
    let response = req.send().await?;
    if !response.status().is_success() {
        bail!("Relay request failed ({})", response.status().as_u16())
    }
    Ok(response.json().await?)
}
async fn connected(
    root: &Path,
    config: &Config,
    shared: &Shared,
    sender: &mpsc::Sender<Request>,
    events: &broadcast::Sender<Arc<Value>>,
) -> Result<()> {
    let client = client()?;
    loop {
        if shared.lock().await.state.is_some() {
            break;
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::try_join!(
        publish(&client, config, shared, events),
        commands(&client, config, root, shared, sender)
    )
    .map(|_| ())
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Patch {
    pub op: String,
    pub path: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<Value>,
}
pub fn diff(old: &Value, new: &Value, path: &mut Vec<String>, changes: &mut Vec<Patch>) {
    if old == new {
        return;
    }
    match (old, new) {
        (Value::Object(a), Value::Object(b)) => {
            for key in a.keys().filter(|key| !b.contains_key(*key)) {
                let mut p = path.clone();
                p.push(key.clone());
                changes.push(Patch {
                    op: "remove".into(),
                    path: p,
                    value: None,
                });
            }
            for (key, value) in b {
                path.push(key.clone());
                if let Some(previous) = a.get(key) {
                    diff(previous, value, path, changes)
                } else {
                    changes.push(Patch {
                        op: "set".into(),
                        path: path.clone(),
                        value: Some(value.clone()),
                    })
                };
                path.pop();
            }
        }
        (Value::Array(a), Value::Array(b)) if b.len() >= a.len() => {
            for (i, value) in b.iter().enumerate() {
                path.push(i.to_string());
                if let Some(previous) = a.get(i) {
                    diff(previous, value, path, changes)
                } else {
                    changes.push(Patch {
                        op: "set".into(),
                        path: path.clone(),
                        value: Some(value.clone()),
                    })
                };
                path.pop();
            }
        }
        (Value::String(a), Value::String(b)) if b.starts_with(a) => changes.push(Patch {
            op: "append".into(),
            path: path.clone(),
            value: Some(Value::String(b[a.len()..].into())),
        }),
        _ => changes.push(Patch {
            op: "set".into(),
            path: path.clone(),
            value: Some(new.clone()),
        }),
    }
}
fn project(raw: &Value, workspace: &Workspace) -> Value {
    let mut run = raw.clone();
    run["workspace"] = json!(workspace.id);
    run["title"] = json!(crate::model::clip(
        raw["prompt"].as_str().unwrap_or("Conversation"),
        120
    ));
    if let Some(prompt) = run["prompt"].as_str() {
        run["prompt"] = json!(crate::model::clip(prompt, 64 * 1024));
    }
    if let Some(info) = run.get_mut("workspace_info").and_then(Value::as_object_mut) {
        info.remove("project");
        info.remove("path");
    }
    if let Some(chat) = run.get_mut("conversation").and_then(Value::as_object_mut) {
        chat.remove("sessions");
        chat.remove("pending_exchange");
        if let Some(messages) = chat.get_mut("messages").and_then(Value::as_array_mut) {
            let end = messages.len();
            let start = end.saturating_sub(32);
            let mut position = 0;
            messages.retain(|m| {
                let keep = position >= start
                    || m["question_request"].is_object()
                        && m["question_request"]["answers"].is_null()
                    || m["approval_request"].is_object()
                        && m["approval_request"]["decision"].is_null();
                position += 1;
                keep
            });
            for message in messages {
                if let Some(m) = message.as_object_mut() {
                    m.remove("logs");
                    m.remove("reasoning");
                    m.remove("session_id");
                    if let Some(text) = m
                        .get("text")
                        .and_then(Value::as_str)
                        .filter(|t| t.len() > 96 * 1024)
                    {
                        let clipped = crate::model::clip(text, 96 * 1024).to_owned();
                        m.insert("text".into(), json!(clipped));
                        m.insert("remote_truncated".into(), json!(true));
                    }
                }
            }
        }
        if let Some(mailbox) = chat.get_mut("mailbox").and_then(Value::as_array_mut) {
            let start = mailbox.len().saturating_sub(64);
            mailbox.drain(..start);
            for mail in mailbox {
                if let Some(text) = mail["text"].as_str() {
                    mail["text"] = json!(crate::model::clip(text, 4096));
                }
            }
        }
    }
    if let Some(stages) = run.get_mut("stages").and_then(Value::as_array_mut) {
        for stage in stages {
            if let Some(s) = stage.as_object_mut() {
                s.remove("logs");
                s.remove("reasoning");
                s.remove("session_id");
                if let Some(text) = s.get("output").and_then(Value::as_str) {
                    let text = crate::model::clip(text, 32 * 1024).to_owned();
                    s.insert("output".into(), json!(text));
                }
            }
        }
    }
    if let Some(files) = run
        .pointer_mut("/changes/files")
        .and_then(Value::as_array_mut)
    {
        files.truncate(20);
        for file in files {
            if let Some(text) = file["diff"].as_str() {
                file["diff"] = json!(crate::model::clip(text, 16 * 1024));
            }
        }
    }
    if let Some(checks) = run
        .pointer_mut("/changes/checks")
        .and_then(Value::as_array_mut)
    {
        let start = checks.len().saturating_sub(16);
        checks.drain(..start);
        for check in checks {
            if let Some(text) = check["output"].as_str() {
                check["output"] = json!(crate::model::clip(text, 16 * 1024));
            }
        }
    }
    // A long local history must not stall all device uploads by exceeding the relay cap.
    // Keep the complete transcript locally and make omitted remote history explicit.
    let original_messages = raw
        .pointer("/conversation/messages")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    while serde_json::to_vec(&run).is_ok_and(|data| data.len() > 3 * 1024 * 1024) {
        let Some(messages) = run
            .pointer_mut("/conversation/messages")
            .and_then(Value::as_array_mut)
        else {
            break;
        };
        if messages.len() <= 1 {
            break;
        }
        messages.drain(..messages.len() / 2);
    }
    let retained_messages = run
        .pointer("/conversation/messages")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    run["remote_omitted_messages"] = json!(original_messages.saturating_sub(retained_messages));
    run
}
async fn publish(
    client: &reqwest::Client,
    config: &Config,
    shared: &Shared,
    events: &broadcast::Sender<Arc<Value>>,
) -> Result<()> {
    let generation = Uuid::new_v4();
    let mut sent: HashMap<String, (Uuid, u64, Value)> = HashMap::new();
    let mut sources: HashMap<String, Arc<Value>> = HashMap::new();
    let mut advertised = Value::Null;
    let mut last = tokio::time::Instant::now() - Duration::from_secs(20);
    let mut online = false;
    loop {
        let (state, runs) = {
            let snapshot = shared.lock().await;
            (
                snapshot.state.clone().unwrap_or(Value::Null),
                snapshot.runs.clone(),
            )
        };
        let connections:Vec<Value>=state["settings"]["agents"].as_array().into_iter().flatten().map(|agent|json!({"provider":agent["provider"],"model":agent["model"],"effort":agent["effort"],"available":state["agents"].as_array().is_some_and(|agents|agents.iter().any(|a|a["provider"]==agent["provider"]&&a["status"]=="ready")),"snippets_only":state["protocol_version"]==2 && serde_json::from_value::<Provider>(agent["provider"].clone()).ok().zip(serde_json::from_value::<crate::model::DeepSeekMode>(state["settings"]["deepseek_mode"].clone()).ok()).is_some_and(|(provider,mode)|crate::runner::supports_snippets(provider,mode))})).collect();
        let advertisement = json!({"workspaces":config.workspaces.iter().map(|w|json!({"id":w.id,"label":w.label})).collect::<Vec<_>>(),"connections":connections});
        if advertisement != advertised || last.elapsed() > Duration::from_secs(15) {
            request(
                client,
                config,
                reqwest::Method::PUT,
                "/device/workspaces",
                Some(&advertisement),
            )
            .await?;
            advertised = advertisement;
            last = tokio::time::Instant::now();
        }
        if !online {
            announce(shared, events, &Some(config.clone()), "online", None).await;
            online = true;
        }
        let mut current = std::collections::HashSet::new();
        for (id, raw) in runs {
            let path = raw
                .pointer("/workspace_info/project")
                .and_then(Value::as_str)
                .or_else(|| raw["workspace"].as_str())
                .unwrap_or("");
            let Some(w) = config
                .workspaces
                .iter()
                .find(|w| w.path.to_str() == Some(path))
            else {
                continue;
            };
            current.insert(id.clone());
            if sources
                .get(&id)
                .is_some_and(|previous| Arc::ptr_eq(previous, &raw))
            {
                continue;
            }
            let run = project(&raw, w);
            if sent.get(&id).is_some_and(|(_, _, old)| old == &run) {
                sources.insert(id, raw);
                continue;
            }
            let (version, body) = if let Some((_, version, old)) = sent.get(&id) {
                let mut changes = vec![];
                diff(old, &run, &mut vec![], &mut changes);
                (
                    *version + 1,
                    json!({"kind":"run_patch","run_id":id,"workspace_id":w.id,"generation":generation,"base_version":version,"version":version+1,"changes":changes}),
                )
            } else {
                (
                    1,
                    json!({"kind":"run_snapshot","run_id":id,"workspace_id":w.id,"generation":generation,"version":1,"run":run}),
                )
            };
            request(
                client,
                config,
                reqwest::Method::POST,
                "/device/events",
                Some(&body),
            )
            .await?;
            sources.insert(id.clone(), raw);
            sent.insert(id, (w.id, version, run));
        }
        let removed: Vec<_> = sent
            .keys()
            .filter(|id| !current.contains(*id))
            .cloned()
            .collect();
        for id in removed {
            let (w, version, _) = sent[&id].clone();
            request(client,config,reqwest::Method::POST,"/device/events",Some(&json!({"kind":"run_deleted","run_id":id,"workspace_id":w,"generation":generation,"version":version+1}))).await?;
            sent.remove(&id);
            sources.remove(&id);
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

#[derive(Deserialize)]
struct Delivery {
    id: Uuid,
    workspace_id: Uuid,
    kind: String,
    payload: Value,
    expires_at: chrono::DateTime<chrono::Utc>,
}
#[derive(Deserialize, Serialize, Clone)]
struct Receipt {
    status: String,
    result: String,
}
async fn commands(
    client: &reqwest::Client,
    config: &Config,
    root: &Path,
    shared: &Shared,
    sender: &mpsc::Sender<Request>,
) -> Result<()> {
    let receipt_path = root.join(format!("remote-receipts-{}.json", config.device_id));
    let mut receipts: HashMap<Uuid, Receipt> = if receipt_path.exists() {
        serde_json::from_slice(&fs::read(&receipt_path)?)
            .context("Could not read command receipts; remote execution paused")?
    } else {
        HashMap::new()
    };
    loop {
        let response = request(
            client,
            config,
            reqwest::Method::GET,
            "/device/commands",
            None,
        )
        .await?;
        for raw in response["commands"].as_array().into_iter().flatten() {
            let delivery: Delivery = serde_json::from_value(raw.clone())?;
            let receipt = if let Some(old) = receipts.get(&delivery.id) {
                if old.status == "pending" {
                    Receipt {
                        status: "uncertain".into(),
                        result: "Engine delivery was interrupted. Check the chat before retrying."
                            .into(),
                    }
                } else {
                    old.clone()
                }
            } else if delivery.expires_at <= chrono::Utc::now() {
                Receipt {
                    status: "failed".into(),
                    result: "Command expired before delivery".into(),
                }
            } else {
                let snapshot = shared.lock().await;
                let translated = translate(config, &delivery, &snapshot);
                drop(snapshot);
                match translated {
                    Err(_) => Receipt{status:"failed".into(),result:"Command does not match a shared workspace, coworker, or pending request".into()},
                    Ok(mut command) => {
                        command["_remote_device"]=json!(config.device_id);
                        command["_remote_workspace"]=json!(delivery.workspace_id);
                        command["_remote_id"]=json!(delivery.id);
                        command["_remote_expires"]=json!(delivery.expires_at);
                        receipts.insert(delivery.id,Receipt{status:"pending".into(),result:String::new()});private_save(&receipt_path,&receipts)?;
                        let(tx,rx)=oneshot::channel();sender.send(Request{command,done:Some(tx)}).await?;
                        match tokio::time::timeout(Duration::from_secs(25), rx).await {Ok(Ok(Ok(())))=>Receipt{status:"delivered".into(),result:"Accepted by the local engine; see the conversation for its result".into()},Ok(Ok(Err(error)))=>Receipt{status:"failed".into(),result:crate::model::clip(&error.to_string(),450)},_=>Receipt{status:"uncertain".into(),result:"Engine acknowledgement was interrupted. Check the conversation before retrying.".into()}}
                    }
                }
            };
            receipts.insert(delivery.id, receipt.clone());
            // Keep receipts for the relay's retention horizon. Refuse execution rather than discard deduplication history.
            if receipts.len() > 20_000 {
                bail!("Remote receipt capacity reached; pair a new device")
            }
            private_save(&receipt_path, &receipts)?;
            request(
                client,
                config,
                reqwest::Method::POST,
                &format!("/device/commands/{}/ack", delivery.id),
                Some(&json!({"status":receipt.status,"result":receipt.result})),
            )
            .await?;
        }
    }
}
fn translate(
    config: &Config,
    delivery: &Delivery,
    snapshot: &crate::host::Snapshot,
) -> Result<Value> {
    let Some(workspace) = config
        .workspaces
        .iter()
        .find(|w| w.id == delivery.workspace_id)
    else {
        bail!("Unshared folder")
    };
    if workspace.path.canonicalize()? != workspace.path {
        bail!("Folder moved")
    }
    let state = snapshot.state.as_ref().context("Engine not initialized")?;
    let mut settings: Settings = serde_json::from_value(state["settings"].clone())?;
    settings.workspace = workspace.path.display().to_string();
    let p = &delivery.payload;
    if !p.is_object() {
        bail!("Invalid payload")
    }
    let snippets_supported = |provider: Provider| -> bool {
        state["protocol_version"] == json!(2)
            && serde_json::from_value::<crate::model::DeepSeekMode>(state["settings"]["deepseek_mode"].clone())
                .ok()
                .is_some_and(|mode| crate::runner::supports_snippets(provider, mode))
    };
    let require_snippets = |provider: Provider| -> Result<()> {
        if snippets_supported(provider) { Ok(()) }
        else { bail!("This engine does not support snippets-only access for {}. Update and restart the engine before disabling workspace reading.", provider.name()) }
    };
    let get_id = |key: &str| -> Result<Uuid> {
        Ok(Uuid::parse_str(p[key].as_str().context("Missing ID")?)?)
    };
    if delivery.kind == "chat" {
        let providers: Vec<Provider> = serde_json::from_value(p["providers"].clone())?;
        if providers.is_empty() || providers.len() > 6 {
            bail!("Choose one to six coworkers")
        }
        let model = p["model"].as_str().unwrap_or("");
        let access: HashMap<Provider, bool> = p.get("workspace_access").map(|v| serde_json::from_value(v.clone())).transpose()?.unwrap_or_default();
        let effort: Effort =
            serde_json::from_value(p.get("effort").cloned().unwrap_or(json!("default")))?;
        let mut workers = vec![];
        for (i, provider) in providers.into_iter().enumerate() {
            if !settings.agents.iter().any(|a| a.provider == provider)
                || !state["agents"].as_array().is_some_and(|agents| {
                    agents
                        .iter()
                        .any(|a| a["provider"] == json!(provider) && a["status"] == "ready")
                })
            {
                bail!("Connection unavailable")
            }
            if access.get(&provider) == Some(&false) {
                require_snippets(provider)?;
            }
            let name = ["Maya", "Alex", "Ivy", "Noah", "Eva", "Kai"][i];
            workers.push(team::Coworker {
                id: Uuid::new_v4(),
                provider,
                name: name.into(),
                mention: name.to_lowercase(),
                role: team::Role::General,
                model: model.into(),
                effort,
                can_read_workspace: access.get(&provider).copied().unwrap_or(true),
                access_changed_at: None,
                blocked_message_ids: vec![],
                attention: team::Attention::Idle,
                waiting_for: None,
                review_id: None,
            });
        }
        let prompt = p["prompt"].as_str().context("Missing message")?;
        if prompt.trim().is_empty() || prompt.len() > 64 * 1024 {
            bail!("Invalid message")
        }
        return Ok(
            json!({"type":"team_chat","run_id":null,"prompt":prompt,"lead_id":workers[0].id,"target_id":null,"settings":settings,"coworkers":workers,"discussion":false,"isolation":{"mode":"shared"}}),
        );
    }
    let id = get_id("run_id")?;
    let run = snapshot
        .runs
        .get(&id.to_string())
        .context("Unknown session")?;
    let path = run
        .pointer("/workspace_info/project")
        .and_then(Value::as_str)
        .or_else(|| run["workspace"].as_str())
        .unwrap_or("");
    if Path::new(path) != workspace.path {
        bail!("Session belongs to another workspace")
    }
    match delivery.kind.as_str() {
        "message" => {
            let prompt = p["prompt"].as_str().context("Missing message")?;
            if prompt.trim().is_empty() || prompt.len() > 64 * 1024 {
                bail!("Invalid message")
            };
            let workers = &run["conversation"]["coworkers"];
            let lead = run["conversation"]["lead_id"].clone();
            let target = p.get("target_id").cloned().unwrap_or(Value::Null);
            if !target.is_null()
                && !workers
                    .as_array()
                    .is_some_and(|ws| ws.iter().any(|w| w["id"] == target))
            {
                bail!("Unknown coworker")
            };
            Ok(
                json!({"type":"team_chat","run_id":id,"prompt":prompt,"lead_id":lead,"target_id":target,"settings":settings,"coworkers":workers,"discussion":false}),
            )
        }
        "cancel" => Ok(json!({"type":"cancel","run_id":id})),
        "continue" => Ok(json!({"type":"team_continue","run_id":id,"settings":settings})),
        "answer" | "approval" => {
            let message_id = get_id("message_id")?;
            let request_id = get_id("request_id")?;
            let msg = run["conversation"]["messages"]
                .as_array()
                .and_then(|ms| ms.iter().find(|m| m["id"] == json!(message_id)))
                .context("Unknown message")?;
            if delivery.kind == "answer" {
                let request: crate::questions::QuestionRequest =
                    serde_json::from_value(msg["question_request"].clone())?;
                if request.id != request_id {
                    bail!("Question changed")
                };
                let answers: Vec<crate::questions::QuestionAnswer> =
                    serde_json::from_value(p["answers"].clone())?;
                let answers = request.validate_answers(&answers)?;
                Ok(
                    json!({"type":"team_answer","run_id":id,"message_id":message_id,"request_id":request_id,"answers":answers,"settings":settings}),
                )
            } else {
                if msg["approval_request"]["id"] != json!(request_id)
                    || !msg["approval_request"]["decision"].is_null()
                {
                    bail!("Approval changed")
                };
                let approved = p["approved"]
                    .as_bool()
                    .context("Explicit decision required")?;
                Ok(
                    json!({"type":"team_approval","run_id":id,"message_id":message_id,"request_id":request_id,"approved":approved,"settings":settings}),
                )
            }
        }
        "coworker" => {
            let worker_id = get_id("coworker_id")?;
            let raw = run["conversation"]["coworkers"]
                .as_array()
                .and_then(|ws| ws.iter().find(|w| w["id"] == json!(worker_id)))
                .context("Unknown coworker")?;
            let mut worker: team::Coworker = serde_json::from_value(raw.clone())?;
            if let Some(model) = p.get("model") { worker.model = model.as_str().context("Invalid model")?.into(); }
            if let Some(effort) = p.get("effort") { worker.effort = serde_json::from_value(effort.clone())?; }
            if let Some(read) = p.get("can_read_workspace") {
                worker.can_read_workspace = read.as_bool().context("Invalid workspace access")?;
                if !worker.can_read_workspace { require_snippets(worker.provider)?; }
            }
            Ok(json!({"type":"update_coworker","run_id":id,"coworker":worker,"change_access":p.get("can_read_workspace").is_some()}))
        }
        _ => bail!("Remote command is not permitted"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn streaming_diff_is_small_and_preserves_unicode() {
        let old = json!({"messages":[{"text":"a".repeat(100_000)}]});
        let new = json!({"messages":[{"text":format!("{}🦀", "a".repeat(100_000))}]});
        let mut patches = vec![];
        diff(&old, &new, &mut vec![], &mut patches);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].op, "append");
        assert_eq!(patches[0].value, Some(json!("🦀")));
        assert!(serde_json::to_vec(&patches).unwrap().len() < 150);
    }
    #[test]
    fn settings_file_never_contains_device_secret() {
        let d = tempfile::tempdir().unwrap();
        let c = Config {
            backend_url: "https://conductor.example".into(),
            device_id: Uuid::new_v4(),
            email: "n@example.test".into(),
            workspaces: vec![],
            token: "secret-test-token".into(),
        };
        private_save(&d.path().join("remote.json"), &c).unwrap();
        assert!(
            !fs::read_to_string(d.path().join("remote.json"))
                .unwrap()
                .contains("secret-test-token")
        );
    }
    #[test]
    fn remote_projection_bounds_history_and_removes_local_session_data() {
        let workspace = Workspace {
            id: Uuid::new_v4(),
            label: "Project".into(),
            path: PathBuf::from("/private/project"),
        };
        let mut messages: Vec<Value> = (0..100).map(|id| json!({"id":id,"text":"Hello","logs":["private-log"],"reasoning":"private-reasoning","session_id":"private-session"})).collect();
        messages[0]["question_request"] = json!({"answers":null,"questions":[]});
        messages[99]["text"] = json!("🦀".repeat(40_000));
        let source = json!({"id":Uuid::new_v4(),"prompt":"Fixture","workspace":"/private/project","workspace_info":{"project":"/private/project","path":"/private/worktree","branch":"main"},"conversation":{"sessions":["private-session"],"pending_exchange":{"secret":"private-context"},"messages":messages,"mailbox":(0..100).map(|_|json!({"text":"a".repeat(10_000)})).collect::<Vec<_>>()},"stages":[{"logs":["private-log"],"reasoning":"private-reasoning","session_id":"private-session","output":"a".repeat(50_000)}],"changes":{"files":(0..30).map(|_|json!({"diff":"a".repeat(20_000)})).collect::<Vec<_>>(),"checks":(0..20).map(|_|json!({"output":"a".repeat(20_000)})).collect::<Vec<_>>()}});
        let projected = project(&source, &workspace);
        let serialized = serde_json::to_string(&projected).unwrap();
        for private in [
            "/private/project",
            "/private/worktree",
            "private-log",
            "private-reasoning",
            "private-session",
            "private-context",
        ] {
            assert!(!serialized.contains(private), "leaked {private}");
        }
        assert_eq!(projected["workspace"], json!(workspace.id));
        assert_eq!(
            projected["conversation"]["messages"]
                .as_array()
                .unwrap()
                .len(),
            33
        );
        assert_eq!(projected["conversation"]["messages"][0]["id"], 0);
        assert_eq!(projected["remote_omitted_messages"], 67);
        let last = projected["conversation"]["messages"]
            .as_array()
            .unwrap()
            .last()
            .unwrap();
        assert!(last["text"].as_str().unwrap().len() <= 96 * 1024 + 4);
        assert_eq!(last["remote_truncated"], true);
        assert_eq!(
            projected["conversation"]["mailbox"]
                .as_array()
                .unwrap()
                .len(),
            64
        );
        assert_eq!(projected["changes"]["files"].as_array().unwrap().len(), 20);
        assert_eq!(projected["changes"]["checks"].as_array().unwrap().len(), 16);
        assert!(serialized.len() < 3 * 1024 * 1024);
        assert_eq!(
            source["conversation"]["messages"].as_array().unwrap().len(),
            100
        );
    }
    #[test]
    fn remote_cannot_dispatch_into_another_folder() {
        let d = tempfile::tempdir().unwrap();
        let c = Config {
            backend_url: "https://conductor.example".into(),
            device_id: Uuid::new_v4(),
            email: "n@example.test".into(),
            workspaces: vec![Workspace {
                id: Uuid::new_v4(),
                label: "Project".into(),
                path: d.path().canonicalize().unwrap(),
            }],
            token: String::new(),
        };
        let request = Delivery {
            id: Uuid::new_v4(),
            workspace_id: Uuid::new_v4(),
            kind: "cancel".into(),
            payload: json!({"run_id":Uuid::new_v4()}),
            expires_at: chrono::Utc::now(),
        };
        assert!(translate(&c, &request, &crate::host::Snapshot::default()).is_err());
    }
}
