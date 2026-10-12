//! Local newline-delimited JSON transport for the SwiftUI frontend.
use crate::{
    claude_config::{self, Snapshot},
    conversation::{self, ChatInput},
    model::{
        AgentEffort, AgentIdentity, AgentModel, Availability, Effort, LogKind, MAX_OUTPUT_BYTES,
        MAX_REASONING_BYTES, Provider, Run, Settings, Status, clip, demo_runs,
    },
    model_catalog::{self, ModelCatalog},
    providers::Update,
    runner::{self, Emitter, Message, StageEvent},
    storage::Store,
    team, workspace,
};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::mpsc,
    task::JoinHandle,
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Command {
    #[serde(rename = "remote_command")]
    RemoteDispatch {
        request_id: Uuid,
        command: Box<Command>,
    },
    TeamChat {
        run_id: Option<Uuid>,
        prompt: String,
        lead_id: Uuid,
        target_id: Option<Uuid>,
        settings: Settings,
        #[serde(default)]
        coworkers: Vec<team::Coworker>,
        #[serde(default)]
        discussion: bool,
        #[serde(default)]
        isolation: workspace::Isolation,
    },
    TeamContinue {
        run_id: Uuid,
        settings: Settings,
    },
    TeamAnswer {
        run_id: Uuid,
        message_id: Uuid,
        request_id: Uuid,
        answers: Vec<crate::questions::QuestionAnswer>,
        settings: Settings,
    },
    DelegateQuestion {
        run_id: Uuid,
        message_id: Uuid,
        request_id: Uuid,
        coworker_id: Uuid,
        settings: Settings,
    },
    TeamApproval {
        run_id: Uuid,
        message_id: Uuid,
        request_id: Uuid,
        approved: bool,
        settings: Settings,
    },
    UpdateCoworker {
        run_id: Uuid,
        coworker: team::Coworker,
    },
    CancelMail {
        run_id: Uuid,
        mail_id: Uuid,
    },
    RefreshChanges {
        run_id: Uuid,
    },
    RunCheck {
        run_id: Uuid,
        argv: Vec<String>,
        owner_id: Option<Uuid>,
    },
    UpdateSettings {
        settings: Settings,
    },
    Discover,
    SessionKey {
        key: String,
        #[serde(default)]
        claude_key: String,
        #[serde(default)]
        kiro_key: String,
    },
    InspectClaude,
    Start {
        prompt: String,
        settings: Settings,
    },
    Chat {
        run_id: Option<Uuid>,
        prompt: String,
        lead: Provider,
        settings: Settings,
        #[serde(default)]
        names: Vec<AgentIdentity>,
        #[serde(default)]
        models: Vec<AgentModel>,
        #[serde(default)]
        efforts: Vec<AgentEffort>,
        #[serde(default)]
        team_discussion: bool,
    },
    RenameAgent {
        run_id: Uuid,
        provider: Provider,
        name: String,
        mention: String,
    },
    RenameTeam {
        run_id: Uuid,
        names: Vec<AgentIdentity>,
    },
    SetAgentModel {
        run_id: Uuid,
        provider: Provider,
        model: String,
    },
    SetAgentEffort {
        run_id: Uuid,
        provider: Provider,
        effort: Effort,
    },
    AnswerQuestion {
        run_id: Uuid,
        message_id: Uuid,
        request_id: Uuid,
        answers: Vec<crate::questions::QuestionAnswer>,
        settings: Settings,
    },
    Cancel {
        run_id: Uuid,
    },
    GetRun {
        run_id: Uuid,
    },
    DismissAttention {
        items: Vec<crate::inbox::Dismissal>,
    },
    DeleteRun {
        run_id: Uuid,
    },
    Export {
        run_id: Uuid,
    },
    Shutdown,
}

#[derive(Serialize)]
pub struct RunSummary {
    id: Uuid,
    title: String,
    workspace: String,
    workflow: crate::model::Workflow,
    created_at: chrono::DateTime<chrono::Utc>,
    status: Status,
    providers: Vec<Provider>,
    names: Vec<AgentIdentity>,
    total_tokens: u64,
    coworkers: Vec<team::Coworker>,
    attention: Vec<crate::inbox::Item>,
    execution_workspace: String,
}

impl From<&Run> for RunSummary {
    fn from(run: &Run) -> Self {
        Self {
            id: run.id,
            title: run.title(),
            workspace: run
                .workspace_info
                .as_ref()
                .map_or_else(|| run.workspace.clone(), |w| w.project.clone()),
            execution_workspace: run.workspace.clone(),
            coworkers: run
                .conversation
                .as_ref()
                .map_or_else(Vec::new, |c| c.coworkers.clone()),
            attention: crate::inbox::items(run),
            workflow: run.workflow,
            created_at: run.created_at,
            status: run.status,
            providers: run.conversation.as_ref().map_or_else(
                || run.stages.iter().map(|s| s.provider).collect(),
                |chat| chat.members.clone(),
            ),
            names: run
                .conversation
                .as_ref()
                .map_or_else(Vec::new, |chat| chat.names.clone()),
            total_tokens: if let Some(chat) = &run.conversation {
                chat.messages
                    .iter()
                    .map(|m| m.usage.input_tokens + m.usage.output_tokens)
                    .sum()
            } else {
                run.stages
                    .iter()
                    .map(|s| s.usage.input_tokens + s.usage.output_tokens)
                    .sum()
            },
        }
    }
}

#[derive(Serialize)]
struct AgentInfo {
    provider: Provider,
    status: &'static str,
    label: &'static str,
    detail: String,
}

fn agent_info(agents: &HashMap<Provider, Availability>) -> Vec<AgentInfo> {
    Provider::ALL
        .into_iter()
        .map(|provider| {
            let a = agents.get(&provider).unwrap_or(&Availability::Checking);
            AgentInfo {
                provider,
                status: match a {
                    Availability::Checking => "checking",
                    Availability::Ready { .. } => "ready",
                    Availability::Missing(_) => "missing",
                    Availability::Incompatible(_) => "incompatible",
                },
                label: a.label(),
                detail: a.detail().into(),
            }
        })
        .collect()
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Event<'a> {
    SettingsUpdated {
        settings: &'a Settings,
    },
    TeamQueued {
        run_id: Uuid,
    },
    State {
        protocol_version: u32,
        settings: &'a Settings,
        runs: Vec<RunSummary>,
        agents: Vec<AgentInfo>,
        demo: bool,
        persistence_blocked: bool,
        errors: Vec<String>,
        claude_config: Snapshot,
        model_catalogs: Vec<ModelCatalog>,
    },
    AgentsUpdated {
        agents: Vec<AgentInfo>,
    },
    ClaudeConfigUpdated {
        claude_config: Snapshot,
        model_catalogs: Vec<ModelCatalog>,
    },
    RunUpdated {
        run: &'a Run,
    },
    RunDetail {
        run: &'a Run,
    },
    AttentionDismissed {
        items: Vec<crate::inbox::Dismissal>,
    },
    RunDeleted {
        run_id: Uuid,
    },
    Notice {
        message: String,
        error: bool,
    },
}

struct Output {
    stream: tokio::io::Stdout,
    remote: Option<Uuid>,
}
async fn emit(output: &mut Output, event: Event<'_>) -> Result<()> {
    let receipt = match &event {
        Event::Notice { message, error } => Some((*error, message.clone())),
        Event::RunUpdated { .. } | Event::TeamQueued { .. } => {
            Some((false, "Accepted by the local engine".into()))
        }
        _ => None,
    };
    let mut bytes = serde_json::to_vec(&event)?;
    bytes.push(b'\n');
    output.stream.write_all(&bytes).await?;
    if let Some((error, message)) = receipt {
        acknowledge_remote(output, error, &message).await?;
    }
    output.stream.flush().await?;
    Ok(())
}

async fn acknowledge_remote(output: &mut Output, error: bool, message: &str) -> Result<()> {
    if let Some(id) = output.remote.take() {
        let mut bytes = serde_json::to_vec(
            &serde_json::json!({"type":"remote_result","request_id":id,"error":error,"message":message}),
        )?;
        bytes.push(b'\n');
        output.stream.write_all(&bytes).await?;
    }
    output.stream.flush().await?;
    Ok(())
}

fn scan(settings: &Settings, key: &str, claude_key: &str, generation: u64, emitter: &Emitter) {
    let settings = settings.clone();
    let has_key = !key.trim().is_empty();
    let claude_has_key = !claude_key.trim().is_empty();
    let emitter = emitter.clone();
    tokio::spawn(async move {
        let agents = runner::discover(settings, has_key, claude_has_key).await;
        emitter
            .send(Message::Discovery { generation, agents })
            .await;
    });
}

pub fn run(data_dir: Option<PathBuf>, demo: bool) -> Result<()> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()?
        .block_on(serve(data_dir, demo))
}

async fn serve(data_dir: Option<PathBuf>, demo: bool) -> Result<()> {
    let store = Store::new(data_dir);
    let mut errors = vec![];
    let mut settings = if demo {
        Settings::default()
    } else {
        store.load_settings().unwrap_or_else(|e| {
            errors.push(format!("{e:#}"));
            Settings::default()
        })
    };
    if !demo
        && !store.root.join("settings.json").exists()
        && runner::existing_deepseek_cli_config(&settings)
    {
        settings.deepseek_use_cli_config = true;
        if let Some(config) = settings
            .agents
            .iter_mut()
            .find(|a| a.provider == Provider::DeepSeek)
        {
            config.model.clear();
        }
    }
    let mut runs = if demo {
        demo_runs(&settings)
    } else {
        store.load_runs().unwrap_or_else(|e| {
            errors.push(format!("{e:#}"));
            vec![]
        })
    };
    let persistence_blocked = !errors.is_empty();
    let mut agents = Provider::ALL
        .into_iter()
        .map(|p| (p, Availability::Checking))
        .collect::<HashMap<_, _>>();
    if demo {
        for p in Provider::ALL {
            agents.insert(
                p,
                Availability::Ready {
                    executable: None,
                    detail: "Sample connection — no agents are invoked in demo mode".into(),
                },
            );
        }
    }
    let (sender, mut receiver) = mpsc::channel(1024);
    let emitter = Emitter {
        turn: None,
        sender,
        wake: Arc::new(|| {}),
    };
    let mut generation = 1;
    let mut key = String::new();
    let mut claude_key = String::new();
    let mut kiro_key = String::new();
    let mut active: HashMap<Uuid, (CancellationToken, JoinHandle<()>)> = HashMap::new();
    let mut team_controls: HashMap<Uuid, team::Control> = HashMap::new();
    let mut changed = HashSet::new();
    let mut dirty = false;
    let mut last_save = tokio::time::Instant::now();
    let mut output = Output {
        stream: tokio::io::stdout(),
        remote: None,
    };
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut ticks = tokio::time::interval(Duration::from_millis(100));
    let snapshot =
        claude_config::inspect(&settings.workspace, &settings.claude_config_dir).snapshot;
    let model_catalogs = model_catalog::catalogs(&settings, &snapshot);
    emit(
        &mut output,
        Event::State {
            protocol_version: 1,
            settings: &settings,
            runs: runs.iter().map(RunSummary::from).collect(),
            agents: agent_info(&agents),
            demo,
            persistence_blocked,
            errors,
            claude_config: snapshot,
            model_catalogs,
        },
    )
    .await?;
    if !demo {
        scan(&settings, &key, &claude_key, generation, &emitter);
    }
    loop {
        output.remote = None;
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line.context("Could not read the frontend request")? else { break; };
                let command = if line.len() > 1024 * 1024 {
                    Err("Frontend request exceeds 1 MiB".into())
                } else { serde_json::from_str::<Command>(&line).map_err(|e| format!("Invalid frontend request: {e}")) };
                let command = match command {
                    Ok(command) => command,
                    Err(message) => { emit(&mut output, Event::Notice { message, error: true }).await?; continue; }
                };
                let command = match command {
                    Command::RemoteDispatch { request_id, command } => { output.remote = Some(request_id); *command },
                    command => command,
                };
                match command {
                    Command::RemoteDispatch { .. } => { emit(&mut output, Event::Notice { message: "Nested remote commands are not allowed".into(), error: true }).await?; },
                    Command::TeamChat { run_id, prompt, lead_id, target_id, settings: next, coworkers, discussion, isolation } => {
                        if demo { emit(&mut output, Event::Notice { message: "Demo mode cannot start agents".into(), error: true }).await?; continue; }
                        if let Some(id) = run_id && let Some(control) = team_controls.get(&id) && active.contains_key(&id) {
                            if let Some(run) = runs.iter_mut().find(|r| r.id == id) && let Some(chat) = &mut run.conversation {
                                match control.enqueue_to(chat, &prompt, lead_id, discussion, target_id) {
                                    Ok(message) => { chat.messages.push(message); let (workers, mail) = control.snapshot(); chat.coworkers = workers; chat.mailbox = mail; dirty = true; emit(&mut output, Event::RunUpdated { run }).await?; emit(&mut output, Event::TeamQueued { run_id: id }).await?; },
                                    Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                                }
                            }
                            continue;
                        }
                        if !active.is_empty() { emit(&mut output, Event::Notice { message: "Another task is working. Open its mailbox to queue a message or stop it first.".into(), error: true }).await?; continue; }
                        let existing = run_id.and_then(|id| runs.iter().find(|r| r.id == id));
                        if run_id.is_some() && existing.is_none() { emit(&mut output, Event::Notice { message: "This chat is no longer in history.".into(), error: true }).await?; continue; }
                        let new_id = Uuid::new_v4();
                        let info = if let Some(run) = existing { run.workspace_info.clone().unwrap_or_else(|| workspace::shared(&run.workspace)) }
                            else { match isolation {
                                workspace::Isolation::Shared => workspace::shared(&next.workspace),
                                workspace::Isolation::Worktree => match workspace::create_worktree(&next.workspace, &store.root, new_id) { Ok(info) => info, Err(error) => { emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?; continue; } },
                                workspace::Isolation::ShareTask { run_id: shared_id } => {
                                    let Some(info) = runs.iter().find(|r| r.id == shared_id).and_then(|r| r.workspace_info.as_ref()).filter(|w| w.project == next.workspace && std::path::Path::new(&w.path).is_dir()) else { emit(&mut output, Event::Notice { message: "Choose an existing task workspace in this project.".into(), error: true }).await?; continue; };
                                    info.clone()
                                }
                            } };
                        let mut proposed = next.clone(); proposed.workspace = info.path.clone(); proposed.repair();
                        match team::prepare(team::Input { existing, settings: &proposed, availability: &agents, coworkers, lead: lead_id, prompt: &prompt, discussion, target: target_id, resume_queue: false, new_run_id: Some(new_id), deepseek_key: &key, claude_key: &claude_key, kiro_key: &kiro_key }) {
                            Ok((mut run, mut plan)) => {
                                if info.isolated { let changes = run.changes.get_or_insert_with(Default::default); if changes.base_commit.is_empty() { changes.base_commit = info.base_commit.clone(); } }
                                run.workspace_info = Some(info); let changes = workspace::capture(&run.workspace, run.changes.as_ref(), None); plan.set_changes(changes.clone()); run.changes = Some(changes);
                                settings = next; settings.repair(); dirty = true;
                                let id = run.id; let token = CancellationToken::new(); team_controls.insert(id, plan.control.clone());
                                active.insert(id, (token.clone(), tokio::spawn(team::execute(plan, emitter.clone(), token))));
                                runs.retain(|r| r.id != id); runs.insert(0, run); runs.truncate(100); emit(&mut output, Event::RunUpdated { run: &runs[0] }).await?;
                            }, Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                        }
                    }
                    Command::TeamContinue { run_id, settings: next } => {
                        if demo || !active.is_empty() { emit(&mut output, Event::Notice { message: "Wait for the current exchange before continuing the queue.".into(), error: true }).await?; continue; }
                        let Some(run) = runs.iter().find(|r| r.id == run_id) else { continue; };
                        let lead = run.conversation.as_ref().and_then(|c| c.lead_id).unwrap_or_default();
                        match team::prepare(team::Input { existing: Some(run), settings: &next, availability: &agents, coworkers: vec![], lead, prompt: "", discussion: false, target: None, resume_queue: true, new_run_id: None, deepseek_key: &key, claude_key: &claude_key, kiro_key: &kiro_key }) {
                            Ok((run, plan)) => { settings = next; settings.repair(); let token = CancellationToken::new(); team_controls.insert(run_id, plan.control.clone()); active.insert(run_id, (token.clone(), tokio::spawn(team::execute(plan, emitter.clone(), token)))); runs.retain(|r| r.id != run_id); runs.insert(0, run); dirty = true; emit(&mut output, Event::RunUpdated { run: &runs[0] }).await?; },
                            Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                        }
                    }
                    Command::DelegateQuestion { run_id, message_id, request_id, coworker_id, settings: next } => {
                        if demo || !active.is_empty() { emit(&mut output, Event::Notice { message: "Wait for the current exchange before asking a teammate to answer.".into(), error: true }).await?; continue; }
                        let Some(existing) = runs.iter().find(|r| r.id == run_id) else { emit(&mut output, Event::Notice { message: "Open the saved chat before delegating its question.".into(), error: true }).await?; continue; };
                        let prepared = team::delegate_question(existing, message_id, request_id, coworker_id).and_then(|delegated| {
                            let lead = delegated.conversation.as_ref().and_then(|c| c.lead_id).unwrap_or_default();
                            team::prepare(team::Input { existing: Some(&delegated), settings: &next, availability: &agents, coworkers: vec![], lead, prompt: "", discussion: false, target: None, resume_queue: true, new_run_id: None, deepseek_key: &key, claude_key: &claude_key, kiro_key: &kiro_key })
                        });
                        match prepared {
                            Ok((run, plan)) => { settings = next; settings.repair(); let token = CancellationToken::new(); team_controls.insert(run_id, plan.control.clone()); active.insert(run_id, (token.clone(), tokio::spawn(team::execute(plan, emitter.clone(), token)))); runs.retain(|r| r.id != run_id); runs.insert(0, run); dirty = true; emit(&mut output, Event::RunUpdated { run: &runs[0] }).await?; },
                            Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                        }
                    }
                    Command::TeamAnswer { run_id, message_id, request_id, answers, settings: next } => {
                        if demo || !active.is_empty() { emit(&mut output, Event::Notice { message: "Wait for the current exchange before answering.".into(), error: true }).await?; continue; }
                        let Some(existing) = runs.iter().find(|r| r.id == run_id) else { continue; };
                        let prepared = team::answer(existing, message_id, request_id, &answers).and_then(|answered| {
                            let lead = answered.conversation.as_ref().and_then(|c| c.lead_id).unwrap_or_default();
                            team::prepare(team::Input { existing: Some(&answered), settings: &next, availability: &agents, coworkers: vec![], lead, prompt: "", discussion: false, target: None, resume_queue: true, new_run_id: None, deepseek_key: &key, claude_key: &claude_key, kiro_key: &kiro_key })
                        });
                        match prepared {
                            Ok((run, plan)) => { settings = next; settings.repair(); let token = CancellationToken::new(); team_controls.insert(run_id, plan.control.clone()); active.insert(run_id, (token.clone(), tokio::spawn(team::execute(plan, emitter.clone(), token)))); runs.retain(|r| r.id != run_id); runs.insert(0, run); dirty = true; emit(&mut output, Event::RunUpdated { run: &runs[0] }).await?; },
                            Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                        }
                    }
                    Command::UpdateCoworker { run_id, coworker } => {
                        if demo || active.contains_key(&run_id) { emit(&mut output, Event::Notice { message: "Wait for this chat's current exchange before editing a coworker.".into(), error: true }).await?; continue; }
                        if let Some(run) = runs.iter_mut().find(|r| r.id == run_id) && let Some(chat) = &mut run.conversation {
                            let mut proposed = chat.coworkers.clone();
                            let validation = (|| -> Result<()> {
                                let worker = proposed.iter_mut().find(|c| c.id == coworker.id).ok_or_else(|| anyhow::anyhow!("Choose a coworker in this chat."))?;
                                if worker.provider != coworker.provider { anyhow::bail!("A saved coworker's connection is fixed. Create a new chat to change it."); }
                                let attention = worker.attention; let waiting_for = worker.waiting_for; let review_id = worker.review_id; *worker = coworker; worker.attention = attention; worker.waiting_for = waiting_for; worker.review_id = review_id;
                                team::validate_roster(&mut proposed)?;
                                for c in &proposed {
                                    let model = if c.model.is_empty() { settings.agents.iter().find(|a| a.provider == c.provider).map_or("", |a| a.model.as_str()) } else { &c.model };
                                    model_catalog::validate_effort(&settings, &claude_config::inspect(&run.workspace, &settings.claude_config_dir).snapshot, c.provider, model, c.effort)?;
                                }
                                Ok(())
                            })();
                            match validation { Ok(()) => { chat.coworkers = proposed; dirty = true; emit(&mut output, Event::RunUpdated { run }).await?; }, Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await? }
                        }
                    }
                    Command::CancelMail { run_id, mail_id } => {
                        let result = if let Some(control) = team_controls.get(&run_id).filter(|_| active.contains_key(&run_id)) {
                            control.cancel_mail(mail_id).map(|()| { if let Some(chat) = runs.iter_mut().find(|r| r.id == run_id).and_then(|r| r.conversation.as_mut()) { let (coworkers, mailbox) = control.snapshot(); chat.coworkers = coworkers; chat.mailbox = mailbox; } })
                        } else if let Some(chat) = runs.iter_mut().find(|r| r.id == run_id).and_then(|r| r.conversation.as_mut()) {
                            team::cancel_saved(chat, mail_id)
                        } else { Err(anyhow::anyhow!("Choose a saved chat.")) };
                        match result { Ok(()) => { changed.insert(run_id); dirty = true; }, Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await? }
                    }
                    Command::RefreshChanges { run_id } => {
                        if active.contains_key(&run_id) { continue; }
                        if let Some(run) = runs.iter().find(|r| r.id == run_id) {
                            let path = run.workspace.clone(); let previous = run.changes.clone(); let emitter = emitter.clone();
                            tokio::spawn(async move { let changes = tokio::task::spawn_blocking(move || workspace::capture(&path, previous.as_ref(), None)).await.unwrap_or_default(); emitter.send(Message::Changes { run_id, changes }).await; });
                        }
                    }
                    Command::RunCheck { run_id, argv, owner_id } => {
                        if demo || !active.is_empty() { emit(&mut output, Event::Notice { message: "Wait for the current exchange before running checks.".into(), error: true }).await?; continue; }
                        if let Err(error) = workspace::validate_check(&argv) { emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?; continue; }
                        if let Some(run) = runs.iter_mut().find(|r| r.id == run_id) {
                            if owner_id.is_some_and(|id| run.conversation.as_ref().is_none_or(|c| !c.coworkers.iter().any(|w| w.id == id))) { continue; }
                            run.status = Status::Running; let path = run.workspace.clone(); let previous = run.changes.clone(); let token = CancellationToken::new(); let stop = token.clone(); let emitter = emitter.clone();
                            active.insert(run_id, (token, tokio::spawn(async move { let result = workspace::run_check(&path, argv, owner_id, &stop).await;
                                let changes = tokio::task::spawn_blocking(move || workspace::capture(&path, previous.as_ref(), owner_id)).await.unwrap_or_default(); emitter.send(Message::Changes { run_id, changes }).await; emitter.send(Message::CheckFinished { run_id, result }).await; })));
                            dirty = true; emit(&mut output, Event::RunUpdated { run }).await?;
                        }
                    }
                    Command::TeamApproval { run_id, message_id, request_id, approved, settings: next } => {
                        if demo || !active.is_empty() { emit(&mut output, Event::Notice { message: "Wait for the current exchange before deciding this approval.".into(), error: true }).await?; continue; }
                        if let Some(run) = runs.iter_mut().find(|r| r.id == run_id) && let Some(message) = run.conversation.as_mut().and_then(|c| c.messages.iter_mut().find(|m| m.id == message_id))
                            && let Some(approval) = message.approval_request.as_mut().filter(|a| a.id == request_id && a.decision.is_none()) {
                            approval.decision = Some(approved); let argv = approval.argv.clone(); let owner = message.author_id; let path = run.workspace.clone(); settings = next; settings.repair(); run.status = Status::Running;
                            let emitter = emitter.clone(); let token = CancellationToken::new(); let stop = token.clone();
                            active.insert(run_id, (token, tokio::spawn(async move { let result = if approved { Some(workspace::run_check(&path, argv, owner, &stop).await) } else { None }; emitter.send(Message::ApprovalResolved { run_id, message_id, request_id, approved, result }).await; })));
                            dirty = true; emit(&mut output, Event::RunUpdated { run }).await?;
                        } else { emit(&mut output, Event::Notice { message: "Open the latest pending approval.".into(), error: true }).await?; }
                    }
                    Command::UpdateSettings { settings: next } => {
                        settings = next;
                        settings.repair();
                        dirty = true;
                        emit(&mut output, Event::SettingsUpdated { settings: &settings }).await?;
                        let snapshot = claude_config::inspect(&settings.workspace, &settings.claude_config_dir).snapshot;
                        let model_catalogs = model_catalog::catalogs(&settings, &snapshot);
                        emit(&mut output, Event::ClaudeConfigUpdated { claude_config: snapshot, model_catalogs }).await?;
                    }
                    Command::Discover if !demo => {
                        generation += 1;
                        agents.values_mut().for_each(|a| *a = Availability::Checking);
                        emit(&mut output, Event::AgentsUpdated { agents: agent_info(&agents) }).await?;
                        scan(&settings, &key, &claude_key, generation, &emitter);
                    }
                    Command::InspectClaude => {
                        let snapshot = claude_config::inspect(&settings.workspace, &settings.claude_config_dir).snapshot;
                        let model_catalogs = model_catalog::catalogs(&settings, &snapshot);
                        emit(&mut output, Event::ClaudeConfigUpdated { claude_config: snapshot, model_catalogs }).await?;
                    }
                    Command::SessionKey { key: next, claude_key: next_claude, kiro_key: next_kiro } => {
                        key = next.chars().take(4096).collect();
                        claude_key = next_claude.chars().take(4096).collect();
                        kiro_key = next_kiro.chars().take(4096).collect();
                    }
                    Command::Start { prompt, settings: next } => {
                        settings = next;
                        settings.repair();
                        dirty = true;
                        if demo || !active.is_empty() {
                            emit(&mut output, Event::Notice { message: if demo { "Demo mode cannot start agents" } else { "A task is already running" }.into(), error: true }).await?;
                            continue;
                        }
                        match runner::prepare_with_keys(&settings, &agents, &prompt, &key, &claude_key) {
                            Ok((run, mut plan)) => {
                                plan.kiro_key = kiro_key.clone();
                                let token = CancellationToken::new();
                                active.insert(run.id, (token.clone(), tokio::spawn(runner::execute(plan, emitter.clone(), token))));
                                runs.insert(0, run);
                                runs.truncate(100);
                                emit(&mut output, Event::RunUpdated { run: &runs[0] }).await?;
                            }
                            Err(e) => emit(&mut output, Event::Notice { message: format!("{e:#}"), error: true }).await?,
                        }
                    }
                    Command::Chat { run_id, prompt, lead, settings: next, names, models, efforts, team_discussion } => {
                        settings = next;
                        settings.repair();
                        dirty = true;
                        if demo || !active.is_empty() {
                            emit(&mut output, Event::Notice { message: if demo { "Demo mode cannot start agents" } else { "Wait for the current reply or cancel it before sending another message" }.into(), error: true }).await?;
                            continue;
                        }
                        let existing = run_id.and_then(|id| runs.iter().find(|r| r.id == id));
                        if run_id.is_some() && existing.is_none() { emit(&mut output, Event::Notice { message: "This task is no longer in history".into(), error: true }).await?; continue; }
                        let other_coworkers: Vec<_> = runs.iter().filter_map(|r| r.conversation.as_ref()).flat_map(|chat| chat.names.iter().cloned()).collect();
                        match conversation::prepare(ChatInput { existing, settings: &settings, availability: &agents, prompt: &prompt, lead, names: &names, other_coworkers: &other_coworkers, models: &models, efforts: &efforts, team_discussion, deepseek_key: &key, claude_key: &claude_key, kiro_key: &kiro_key }) {
                            Ok((run, plan)) => {
                                let id = run.id;
                                let token = CancellationToken::new();
                                active.insert(id, (token.clone(), tokio::spawn(conversation::execute(plan, emitter.clone(), token))));
                                runs.retain(|r| r.id != id);
                                runs.insert(0, run);
                                runs.truncate(100);
                                emit(&mut output, Event::RunUpdated { run: &runs[0] }).await?;
                            }
                            Err(error) => emit(&mut output, Event::Notice { message: format!("{error:#}"), error: true }).await?,
                        }
                    }
                    Command::AnswerQuestion { run_id, message_id, request_id, answers, settings: next } => {
                        if demo || !active.is_empty() {
                            emit(&mut output, Event::Notice { message: "Wait for the current reply before answering a question".into(), error: true }).await?;
                            continue;
                        }
                        let Some(existing) = runs.iter().find(|r| r.id == run_id) else {
                            emit(&mut output, Event::Notice { message: "This question's chat is no longer in history".into(), error: true }).await?;
                            continue;
                        };
                        let mut proposed = next;
                        proposed.repair();
                        match conversation::prepare_answer(conversation::AnswerInput { existing, message_id, request_id, answers: &answers,
                            settings: &proposed, availability: &agents, deepseek_key: &key, claude_key: &claude_key, kiro_key: &kiro_key }) {
                            Ok((run, plan)) => {
                                settings = proposed;
                                dirty = true;
                                let token = CancellationToken::new();
                                active.insert(run.id, (token.clone(), tokio::spawn(conversation::execute(plan, emitter.clone(), token))));
                                runs.retain(|r| r.id != run_id);
                                runs.insert(0, run);
                                emit(&mut output, Event::RunUpdated { run: &runs[0] }).await?;
                            }
                            Err(error) => emit(&mut output, Event::Notice { message: format!("{error:#}"), error: true }).await?,
                        }
                    }
                    Command::RenameAgent { run_id, provider, name, mention } => {
                        if demo || active.contains_key(&run_id) {
                            emit(&mut output, Event::Notice { message: "Wait for the current reply before renaming an agent".into(), error: true }).await?;
                            continue;
                        }
                        if let Some(run) = runs.iter_mut().find(|r| r.id == run_id)
                            && let Some(chat) = &mut run.conversation {
                            match chat.rename(AgentIdentity { provider, name, mention }) {
                                Ok(()) => { dirty = true; emit(&mut output, Event::RunUpdated { run }).await?; }
                                Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                            }
                        } else {
                            emit(&mut output, Event::Notice { message: "Choose a saved Chat task to rename its agents".into(), error: true }).await?;
                        }
                    }
                    Command::RenameTeam { run_id, names } => {
                        if demo || active.contains_key(&run_id) {
                            emit(&mut output, Event::Notice { message: "Wait for the current reply before editing its team".into(), error: true }).await?;
                            continue;
                        }
                        if let Some(run) = runs.iter_mut().find(|r| r.id == run_id)
                            && let Some(chat) = &mut run.conversation {
                            match chat.rename_team(names) {
                                Ok(()) => { dirty = true; emit(&mut output, Event::RunUpdated { run }).await?; }
                                Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                            }
                        } else {
                            emit(&mut output, Event::Notice { message: "Choose a saved Chat task to edit its team".into(), error: true }).await?;
                        }
                    }
                    Command::SetAgentModel { run_id, provider, model } => {
                        if demo || active.contains_key(&run_id) {
                            emit(&mut output, Event::Notice { message: "Wait for the current reply before changing its model".into(), error: true }).await?;
                            continue;
                        }
                        if let Some(run) = runs.iter_mut().find(|r| r.id == run_id)
                            && let Some(chat) = &mut run.conversation {
                            match chat.set_model(provider, &model) {
                                Ok(()) => { dirty = true; emit(&mut output, Event::RunUpdated { run }).await?; }
                                Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                            }
                        } else {
                            emit(&mut output, Event::Notice { message: "Choose a saved Chat task to change its models".into(), error: true }).await?;
                        }
                    }
                    Command::SetAgentEffort { run_id, provider, effort } => {
                        if demo || active.contains_key(&run_id) {
                            emit(&mut output, Event::Notice { message: "Wait for the current reply before changing its effort".into(), error: true }).await?;
                            continue;
                        }
                        if let Some(run) = runs.iter_mut().find(|r| r.id == run_id)
                            && let Some(chat) = &mut run.conversation {
                            let model = chat.models.iter().find(|m| m.provider == provider).map(|m| m.model.as_str())
                                .or_else(|| settings.agents.iter().find(|a| a.provider == provider).map(|a| a.model.as_str())).unwrap_or("");
                            let snapshot = claude_config::inspect(&run.workspace, &settings.claude_config_dir).snapshot;
                            match model_catalog::validate_effort(&settings, &snapshot, provider, model, effort).and_then(|_| chat.set_effort(provider, effort)) {
                                Ok(()) => { dirty = true; emit(&mut output, Event::RunUpdated { run }).await?; }
                                Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                            }
                        } else {
                            emit(&mut output, Event::Notice { message: "Choose a saved Chat task to change its effort".into(), error: true }).await?;
                        }
                    }
                    Command::Cancel { run_id } => {
                        if let Some((token, _)) = active.get(&run_id) {
                            token.cancel();
                            acknowledge_remote(&mut output, false, "Cancellation requested").await?;
                        } else {
                            let exists = runs.iter().any(|run| run.id == run_id);
                            acknowledge_remote(&mut output, !exists, if exists { "Task is already idle" } else { "This chat is no longer in history" }).await?;
                        }
                    }
                    Command::DismissAttention { items } => {
                        if demo || persistence_blocked { emit(&mut output, Event::Notice { message: "Inbox changes cannot be saved right now.".into(), error: true }).await?; continue; }
                        let previous = runs.iter().map(|r| r.dismissed_attention.clone()).collect::<Vec<_>>();
                        let accepted = crate::inbox::dismiss(&mut runs, &items);
                        match store.save(&settings, &runs) {
                            Ok(()) => { dirty = false; last_save = tokio::time::Instant::now(); emit(&mut output, Event::AttentionDismissed { items: accepted }).await?; },
                            Err(error) => {
                                for (run, keys) in runs.iter_mut().zip(previous) { run.dismissed_attention = keys; }
                                emit(&mut output, Event::Notice { message: format!("Could not clear inbox: {error:#}"), error: true }).await?;
                            }
                        }
                    }
                    Command::DeleteRun { run_id } => {
                        if demo || persistence_blocked { emit(&mut output, Event::Notice { message: "Chats cannot be deleted while saved state is unavailable.".into(), error: true }).await?; continue; }
                        match delete_saved_run(&store, &settings, &mut runs, run_id, active.contains_key(&run_id)) {
                            Ok(()) => {
                                changed.remove(&run_id); team_controls.remove(&run_id);
                                dirty = false; last_save = tokio::time::Instant::now();
                                emit(&mut output, Event::RunDeleted { run_id }).await?;
                            },
                            Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                        }
                    }
                    Command::GetRun { run_id } => {
                        if let Some(run) = runs.iter().find(|r| r.id == run_id) {
                            emit(&mut output, Event::RunDetail { run }).await?;
                        }
                    }
                    Command::Export { run_id } => {
                        if demo { emit(&mut output, Event::Notice { message: "Exports are disabled for sample data".into(), error: true }).await?; }
                        else if let Some(run) = runs.iter().find(|r| r.id == run_id) {
                            let (message, error) = match store.export(run) {
                                Ok(path) => (format!("Saved {}", path.display()), false),
                                Err(e) => (format!("Export failed: {e:#}"), true),
                            };
                            emit(&mut output, Event::Notice { message, error }).await?;
                        }
                    }
                    Command::Shutdown => break,
                    Command::Discover => {}
                }
            }
            message = receiver.recv() => {
                match message {
                    Some(Message::Discovery { generation: found, agents: found_agents }) if found == generation => {
                        agents = found_agents;
                        emit(&mut output, Event::AgentsUpdated { agents: agent_info(&agents) }).await?;
                    }
                    Some(Message::Stage { run_id, provider, event }) => {
                        if let Some(run) = runs.iter_mut().find(|r| r.id == run_id) {
                            apply_stage(run, provider, event);
                            if run.status.terminal() { active.remove(&run_id); }
                            changed.insert(run_id);
                            dirty = true;
                        }
                    }
                    Some(Message::ApprovalResolved { run_id, message_id, request_id, approved, result }) => {
                        let cancelled = active.remove(&run_id).is_some_and(|(token, _)| token.is_cancelled());
                        let resolved = (|| -> Result<Run> {
                            let mut run = runs.iter().find(|r| r.id == run_id).cloned().ok_or_else(|| anyhow::anyhow!("Approval chat is missing."))?;
                            let chat = run.conversation.as_mut().unwrap();
                            let message = chat.messages.iter_mut().find(|m| m.id == message_id).ok_or_else(|| anyhow::anyhow!("Approval message is missing."))?;
                            let owner = message.author_id.ok_or_else(|| anyhow::anyhow!("Approval owner is missing."))?;
                            let approval = message.approval_request.as_mut().filter(|r| r.id == request_id).ok_or_else(|| anyhow::anyhow!("Approval changed."))?;
                            approval.decision = Some(approved); approval.result = result.clone(); message.status = Status::Completed;
                            if let Some(result) = &result { let checks = &mut run.changes.get_or_insert_with(Default::default).checks; checks.push(result.clone()); if checks.len() > 24 { checks.remove(0); } }
                            if cancelled {
                                run.status = Status::Cancelled;
                                for mail in &mut chat.mailbox { if matches!(mail.state, team::MailState::WaitingForUser | team::MailState::Queued | team::MailState::Delivered) { mail.state = team::MailState::Cancelled; } }
                                for worker in &mut chat.coworkers { worker.attention = team::Attention::Cancelled; worker.waiting_for = None; }
                            } else {
                                let response = result.as_ref().map_or("The human declined this command. It was not executed. Continue without doing it; ask for a different approach if necessary.".into(), |r| format!("The human approved this command once. Actual result: {:?}, exit code {:?}.\n{}\nContinue using this result. The approval grants no other commands.", r.status, r.exit_code, clip(&r.output, 16 * 1024)));
                                team::resume_waiting(chat, message_id, owner, response)?;
                            }
                            Ok(run)
                        })();
                        match resolved {
                            Ok(run) if cancelled => { runs.retain(|r| r.id != run_id); runs.insert(0, run); dirty = true; changed.insert(run_id); },
                            Ok(mut run) => {
                                run.changes = Some(workspace::capture(&run.workspace, run.changes.as_ref(), result.as_ref().and_then(|r| r.owner_id)));
                                let lead = run.conversation.as_ref().and_then(|c| c.lead_id).unwrap_or_default();
                                match team::prepare(team::Input { existing: Some(&run), settings: &settings, availability: &agents, coworkers: vec![], lead, prompt: "", discussion: false, target: None, resume_queue: true, new_run_id: None, deepseek_key: &key, claude_key: &claude_key, kiro_key: &kiro_key }) {
                                    Ok((run, plan)) => { let token = CancellationToken::new(); team_controls.insert(run_id, plan.control.clone()); active.insert(run_id, (token.clone(), tokio::spawn(team::execute(plan, emitter.clone(), token)))); runs.retain(|r| r.id != run_id); runs.insert(0, run); dirty = true; changed.insert(run_id); },
                                    Err(error) => { run.status = Status::Interrupted; runs.retain(|r| r.id != run_id); runs.insert(0, run); changed.insert(run_id); dirty = true; emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?; }
                                }
                            },
                            Err(error) => emit(&mut output, Event::Notice { message: error.to_string(), error: true }).await?,
                        }
                    }
                    Some(message) => {
                        if let Some(id) = apply_chat(&mut runs, message) {
                            if runs.iter().any(|r| r.id == id && r.status.terminal()) { active.remove(&id); team_controls.remove(&id); }
                            changed.insert(id);
                            dirty = true;
                        }
                    }
                    _ => {}
                }
            }
            _ = ticks.tick() => {
                // Coalesce token events so the main UI receives at most ten updates per second.
                for id in changed.drain() {
                    if let Some(run) = runs.iter().find(|r| r.id == id) { emit(&mut output, Event::RunUpdated { run }).await?; }
                }
                if dirty && last_save.elapsed() >= Duration::from_secs(2) && !demo && !persistence_blocked {
                    if let Err(e) = store.save(&settings, &runs) {
                        emit(&mut output, Event::Notice { message: format!("Could not save state: {e:#}"), error: true }).await?;
                    } else { dirty = false; }
                    last_save = tokio::time::Instant::now();
                }
            }
        }
    }
    for (token, _) in active.values() {
        token.cancel();
    }
    for (_, (_, handle)) in active.drain() {
        let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;
    }
    while let Ok(message) = receiver.try_recv() {
        match message {
            Message::Stage {
                run_id,
                provider,
                event,
            } => {
                if let Some(run) = runs.iter_mut().find(|r| r.id == run_id) {
                    apply_stage(run, provider, event);
                }
            }
            other => {
                apply_chat(&mut runs, other);
            }
        }
    }
    for run in &mut runs {
        run.recover();
    }
    if !demo && !persistence_blocked {
        store.save(&settings, &runs)?;
    }
    Ok(())
}

fn delete_saved_run(
    store: &Store,
    settings: &Settings,
    runs: &mut Vec<Run>,
    id: Uuid,
    active: bool,
) -> Result<()> {
    let Some(index) = runs.iter().position(|r| r.id == id) else {
        // A duplicate request still acknowledges the current persisted state.
        return store
            .save(settings, runs)
            .context("Could not save chat deletion");
    };
    if active || !runs[index].status.terminal() {
        anyhow::bail!("Stop this chat and wait for its agents to finish before deleting it.");
    }
    let removed = runs.remove(index);
    if let Err(error) = store.save(settings, runs) {
        runs.insert(index, removed);
        return Err(error.context("Could not delete the saved chat"));
    }
    // Deleting dashboard history never removes a project, worktree or provider session.
    Ok(())
}

pub fn apply_stage(run: &mut Run, provider: Provider, event: StageEvent) {
    let Some(stage) = run.stages.iter_mut().find(|s| s.provider == provider) else {
        return;
    };
    update_stage(stage, event);
    run.refresh_status();
}

fn update_stage(stage: &mut crate::model::Stage, event: StageEvent) {
    match event {
        StageEvent::Started => {
            stage.status = Status::Running;
            stage.log(LogKind::Info, "Headless run started".into());
        }
        StageEvent::Update(update) => match update {
            Update::TextDelta(text) => {
                if stage.output.len() < MAX_OUTPUT_BYTES {
                    stage.output.push_str(&text);
                    if stage.output.len() > MAX_OUTPUT_BYTES {
                        stage.output = clip(&stage.output, MAX_OUTPUT_BYTES);
                        stage.log(
                            LogKind::Warning,
                            "Response display capped at 256 KiB.".into(),
                        );
                    }
                }
            }
            Update::Output(text) => stage.output = clip(&text, MAX_OUTPUT_BYTES),
            Update::Reasoning(text) => stage.reasoning = clip(&text, MAX_REASONING_BYTES),
            Update::Log(kind, text) => stage.log(kind, text),
            Update::Session(id) => stage.session_id = Some(id),
            Update::Usage(usage) => stage.usage = usage,
            Update::Error(error) => {
                stage.error = Some(error.clone());
                stage.log(LogKind::Error, error);
            }
        },
        StageEvent::Finished { status, error } => {
            stage.status = status;
            if let Some(error) = error {
                stage.error = Some(error.clone());
                stage.log(LogKind::Error, error);
            }
            stage.log(LogKind::Info, status.name().into());
        }
    }
}

fn apply_chat(runs: &mut [Run], event: Message) -> Option<Uuid> {
    use crate::model::Stage;
    let id = match &event {
        Message::ChatAppend { run_id, .. }
        | Message::ChatStage { run_id, .. }
        | Message::ChatSession { run_id, .. }
        | Message::ChatSuspended { run_id, .. }
        | Message::ChatFinished { run_id, .. } => *run_id,
        Message::TeamMailbox { run_id, .. }
        | Message::TeamQuestion { run_id, .. }
        | Message::Changes { run_id, .. }
        | Message::CheckFinished { run_id, .. } => *run_id,
        _ => return None,
    };
    let run = runs.iter_mut().find(|r| r.id == id)?;
    if let Message::Changes { changes, .. } = event {
        if let Some(chat) = &mut run.conversation {
            for worker in &mut chat.coworkers {
                if worker.attention == team::Attention::ReadyForReview
                    && !changes.files.iter().any(|f| f.owner_id == Some(worker.id))
                {
                    worker.attention = team::Attention::Idle;
                }
            }
        }
        run.changes = Some(changes);
        return Some(id);
    }
    if let Message::CheckFinished { result, .. } = event {
        run.status = if run.conversation.as_ref().is_some_and(team::pending) {
            Status::WaitingForUser
        } else {
            result.status
        };
        run.finished_at = Some(chrono::Utc::now());
        let changes = run.changes.get_or_insert_with(Default::default);
        changes.checks.push(result);
        if changes.checks.len() > 24 {
            changes.checks.remove(0);
        }
        return Some(id);
    }
    let chat = run.conversation.as_mut()?;
    // Bound at message/turn boundaries instead of serializing the transcript for every token.
    let bound = !matches!(
        &event,
        Message::ChatStage {
            event: StageEvent::Started | StageEvent::Update(_),
            ..
        }
    );
    match event {
        Message::ChatAppend { message, .. } => chat.messages.push(*message),
        Message::ChatStage {
            message_id,
            provider,
            event,
            ..
        } => {
            let message = chat.messages.iter_mut().find(|m| m.id == message_id)?;
            if matches!(event, StageEvent::Started) {
                run.status = Status::Running;
            }
            let mut stage = Stage {
                provider,
                model: std::mem::take(&mut message.model),
                status: message.status,
                session_id: message.session_id.take(),
                output: std::mem::take(&mut message.text),
                reasoning: std::mem::take(&mut message.reasoning),
                logs: std::mem::take(&mut message.logs),
                usage: std::mem::take(&mut message.usage),
                error: message.error.take(),
            };
            update_stage(&mut stage, event);
            stage.logs = stage
                .logs
                .into_iter()
                .rev()
                .take(64)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            for log in &mut stage.logs {
                log.text = clip(&log.text, 2048);
            }
            message.model = stage.model;
            message.status = stage.status;
            message.session_id = stage.session_id;
            message.text = stage.output;
            message.reasoning = stage.reasoning;
            message.logs = stage.logs;
            message.usage = stage.usage;
            message.error = stage.error;
        }
        Message::ChatSession { session, .. } => {
            chat.sessions.retain(|s| {
                if let Some(id) = session.coworker_id {
                    s.coworker_id != Some(id)
                } else {
                    s.provider != session.provider
                }
            });
            chat.sessions.push(session);
        }
        Message::TeamMailbox {
            coworkers, mailbox, ..
        } => {
            chat.coworkers = coworkers;
            chat.mailbox = mailbox;
        }
        Message::TeamQuestion {
            message_id,
            question,
            approval,
            ..
        } => {
            let message = chat.messages.iter_mut().find(|m| m.id == message_id)?;
            message.status =
                if question.as_ref().is_some_and(|q| q.answers.is_some()) && approval.is_none() {
                    Status::Completed
                } else {
                    Status::WaitingForUser
                };
            message.question_request = question;
            message.approval_request = approval;
        }
        Message::ChatSuspended {
            message_id,
            request,
            exchange,
            ..
        } => {
            let message = chat.messages.iter_mut().find(|m| m.id == message_id)?;
            message.status = Status::WaitingForUser;
            message.question_request = Some(request);
            chat.pending_exchange = Some(exchange);
        }
        Message::ChatFinished { status, .. } => {
            run.status = status;
            run.finished_at = Some(chrono::Utc::now());
        }
        _ => {}
    }
    if bound {
        chat.bound();
    }
    Some(id)
}

#[cfg(test)]
mod history_tests {
    use super::*;

    #[test]
    fn deletion_persists_keeps_workspace_and_ignores_late_updates() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(Some(dir.path().join("state")));
        let settings = Settings::default();
        let mut runs = demo_runs(&settings);
        let id = runs[0].id;
        let workspace_file = dir.path().join("source.rs");
        let mut other = runs[0].clone();
        other.id = Uuid::new_v4();
        runs.push(other);
        std::fs::write(&workspace_file, "keep me").unwrap();
        runs[0].workspace = dir.path().to_string_lossy().into();
        store.save(&settings, &runs).unwrap();
        let count = runs.len();
        delete_saved_run(&store, &settings, &mut runs, id, false).unwrap();
        assert_eq!(runs.len(), count - 1);
        assert!(store.load_runs().unwrap().iter().all(|r| r.id != id));
        assert_eq!(std::fs::read_to_string(workspace_file).unwrap(), "keep me");
        assert!(
            apply_chat(
                &mut runs,
                Message::Changes {
                    run_id: id,
                    changes: Default::default()
                }
            )
            .is_none()
        );
        runs[0].prompt = "Other chat progress".into();
        delete_saved_run(&store, &settings, &mut runs, id, false).unwrap();
        assert_eq!(runs.len(), count - 1);
        assert_eq!(store.load_runs().unwrap()[0].prompt, "Other chat progress");
    }

    #[test]
    fn deletion_rejects_live_work_and_restores_history_on_save_failure() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(Some(dir.path().join("state")));
        let settings = Settings::default();
        let mut runs = demo_runs(&settings);
        let id = runs[0].id;
        assert!(delete_saved_run(&store, &settings, &mut runs, id, true).is_err());
        let status = runs[0].status;
        runs[0].status = Status::Running;
        assert!(delete_saved_run(&store, &settings, &mut runs, id, false).is_err());
        runs[0].status = status;
        std::fs::write(&store.root, "not a directory").unwrap();
        let order = runs.iter().map(|r| r.id).collect::<Vec<_>>();
        assert!(delete_saved_run(&store, &settings, &mut runs, id, false).is_err());
        assert_eq!(runs.iter().map(|r| r.id).collect::<Vec<_>>(), order);
    }
}
