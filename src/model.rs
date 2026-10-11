use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use uuid::Uuid;

pub const MAX_OUTPUT_BYTES: usize = 256 * 1024;
pub const MAX_LOGS: usize = 1500;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Claude,
    Codex,
    Antigravity,
    Qoder,
    DeepSeek,
    Kiro,
}

impl Provider {
    pub const ALL: [Self; 6] = [
        Self::Claude,
        Self::Codex,
        Self::Antigravity,
        Self::Qoder,
        Self::DeepSeek,
        Self::Kiro,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Self::Claude => "Claude",
            Self::Codex => "Codex",
            Self::Antigravity => "Antigravity",
            Self::Qoder => "Qoder",
            Self::DeepSeek => "DeepSeek",
            Self::Kiro => "Kiro",
        }
    }

    pub fn mention(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Antigravity => "antigravity",
            Self::Qoder => "qoder",
            Self::DeepSeek => "deepseek",
            Self::Kiro => "kiro",
        }
    }

    pub fn teammate_name(self) -> &'static str {
        match self {
            Self::Claude => "Maya",
            Self::Codex => "Alex",
            Self::Antigravity => "Avery",
            Self::Qoder => "Quinn",
            Self::DeepSeek => "Sage",
            Self::Kiro => "Kai",
        }
    }

    pub fn tagline(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code · local CLI",
            Self::Codex => "OpenAI Codex · local CLI",
            Self::Antigravity => "Google Antigravity · local CLI",
            Self::Qoder => "Qoder · local CLI",
            Self::DeepSeek => "DeepSeek · Claude Code or API",
            Self::Kiro => "Kiro · local CLI",
        }
    }

    pub fn executable_names(self) -> &'static [&'static str] {
        match self {
            Self::Claude => &["claude"],
            Self::Codex => &["codex"],
            Self::Antigravity => &["agy"],
            Self::Qoder => &["qoder", "qodercli"],
            Self::DeepSeek => &["claude"],
            Self::Kiro => &["kiro-cli"],
        }
    }

    pub fn docs_url(self) -> &'static str {
        match self {
            Self::Claude => "https://code.claude.com/docs/en/headless",
            Self::Codex => "https://developers.openai.com/codex/noninteractive/",
            Self::Antigravity => "https://www.antigravity.google/docs/cli/headless/",
            Self::Qoder => "https://docs.qoder.com/cli/run-in-scripts",
            Self::DeepSeek => {
                "https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/"
            }
            Self::Kiro => "https://kiro.dev/docs/cli/headless/",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentConfig {
    pub provider: Provider,
    pub selected: bool,
    pub executable: String,
    pub model: String,
    #[serde(default)]
    pub effort: Effort,
    /// JSON argv, never a shell command. Credentials must come from the CLI or environment.
    pub extra_args: String,
    #[serde(default)]
    pub allow_edits: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Effort {
    #[default]
    Default,
    None,
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
    Ultra,
}

impl Effort {
    pub fn value(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::None => "none",
            Self::Minimal => "minimal",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Xhigh => "xhigh",
            Self::Max => "max",
            Self::Ultra => "ultra",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum Workflow {
    #[default]
    Independent,
    Collaborate,
    Conversation,
}

impl Workflow {
    pub fn name(self) -> &'static str {
        match self {
            Self::Independent => "Independent",
            Self::Collaborate => "Collaborate",
            Self::Conversation => "Conversation",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub workspace: String,
    #[serde(default)]
    pub workspace_folders: Vec<String>,
    pub agents: Vec<AgentConfig>,
    pub workflow: Workflow,
    pub timeout_seconds: u64,
    pub deepseek_base_url: String,
    pub deepseek_mode: DeepSeekMode,
    pub deepseek_use_cli_config: bool,
    pub claude_backend: ClaudeBackend,
    pub claude_base_url: String,
    pub claude_config_dir: String,
    pub chat_introduced: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClaudeBackend {
    #[default]
    Inherit,
    Anthropic,
    DeepSeek,
    Custom,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeepSeekMode {
    #[default]
    ClaudeCode,
    DirectApi,
}

impl Default for Settings {
    fn default() -> Self {
        let workspace = std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .display()
            .to_string();
        Self {
            workspace_folders: vec![workspace.clone()],
            workspace,
            agents: Provider::ALL
                .into_iter()
                .map(|provider| AgentConfig {
                    provider,
                    selected: matches!(provider, Provider::Claude | Provider::Codex),
                    executable: String::new(),
                    model: if provider == Provider::DeepSeek {
                        "deepseek-flash".into()
                    } else {
                        String::new()
                    },
                    effort: Effort::Default,
                    extra_args: "[]".into(),
                    allow_edits: false,
                })
                .collect(),
            workflow: Workflow::Independent,
            timeout_seconds: 900,
            deepseek_base_url: "https://api.deepseek.com".into(),
            deepseek_mode: DeepSeekMode::ClaudeCode,
            deepseek_use_cli_config: false,
            claude_backend: ClaudeBackend::Inherit,
            claude_base_url: String::new(),
            claude_config_dir: String::new(),
            chat_introduced: false,
        }
    }
}

impl Settings {
    pub fn repair(&mut self) {
        let mut folders = std::collections::HashSet::new();
        self.workspace_folders
            .retain(|path| !path.is_empty() && folders.insert(path.clone()));
        if self.workspace.is_empty() {
            if let Some(path) = self.workspace_folders.first() {
                self.workspace = path.clone();
            }
        } else if !folders.contains(&self.workspace) {
            self.workspace_folders.insert(0, self.workspace.clone());
        }
        // Preserve the user's collaboration order and append any newly introduced providers.
        let mut seen = std::collections::HashSet::new();
        self.agents.retain(|agent| seen.insert(agent.provider));
        for agent in Self::default().agents {
            if seen.insert(agent.provider) {
                self.agents.push(agent);
            }
        }
        self.timeout_seconds = self.timeout_seconds.clamp(10, 7200);
    }
}

#[derive(Clone, Debug)]
pub enum Availability {
    Checking,
    Ready {
        executable: Option<PathBuf>,
        detail: String,
    },
    Missing(String),
    Incompatible(String),
}

impl Availability {
    pub fn ready(&self) -> bool {
        matches!(self, Self::Ready { .. })
    }
    pub fn detail(&self) -> &str {
        match self {
            Self::Checking => "Checking local installation…",
            Self::Ready { detail, .. } => detail,
            Self::Missing(detail) | Self::Incompatible(detail) => detail,
        }
    }
    pub fn label(&self) -> &'static str {
        match self {
            Self::Checking => "Checking",
            Self::Ready { .. } => "Detected",
            Self::Missing(_) => "Set up",
            Self::Incompatible(_) => "Needs CLI",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Status {
    Queued,
    Running,
    WaitingForUser,
    Completed,
    Failed,
    Cancelled,
    Interrupted,
}

impl Status {
    pub fn name(self) -> &'static str {
        match self {
            Self::Queued => "Queued",
            Self::Running => "Running",
            Self::WaitingForUser => "Waiting for you",
            Self::Completed => "Completed",
            Self::Failed => "Failed",
            Self::Cancelled => "Cancelled",
            Self::Interrupted => "Interrupted",
        }
    }
    pub fn terminal(self) -> bool {
        !matches!(self, Self::Queued | Self::Running)
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cost_usd: Option<f64>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum LogKind {
    Info,
    Tool,
    Warning,
    Error,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LogEntry {
    pub at: DateTime<Utc>,
    pub kind: LogKind,
    pub text: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Stage {
    pub provider: Provider,
    pub model: String,
    pub status: Status,
    pub session_id: Option<String>,
    pub output: String,
    pub logs: Vec<LogEntry>,
    pub usage: Usage,
    pub error: Option<String>,
}

impl Stage {
    pub fn log(&mut self, kind: LogKind, text: String) {
        if self.logs.len() >= MAX_LOGS {
            self.logs.remove(0);
        }
        self.logs.push(LogEntry {
            at: Utc::now(),
            kind,
            text: clip(&text, 8192),
        });
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Run {
    pub id: Uuid,
    pub prompt: String,
    pub workspace: String,
    pub workflow: Workflow,
    pub created_at: DateTime<Utc>,
    pub finished_at: Option<DateTime<Utc>>,
    pub status: Status,
    pub stages: Vec<Stage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<Conversation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_info: Option<crate::workspace::WorkspaceInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changes: Option<crate::workspace::ChangeSet>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Conversation {
    pub members: Vec<Provider>,
    pub lead: Provider,
    pub messages: Vec<ChatMessage>,
    pub sessions: Vec<AgentSession>,
    #[serde(default)]
    pub names: Vec<AgentIdentity>,
    #[serde(default)]
    pub models: Vec<AgentModel>,
    #[serde(default)]
    pub efforts: Vec<AgentEffort>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_exchange: Option<crate::conversation::SuspendedExchange>,
    #[serde(default)]
    pub coworkers: Vec<crate::team::Coworker>,
    #[serde(default)]
    pub lead_id: Option<Uuid>,
    #[serde(default)]
    pub mailbox: Vec<crate::team::Mail>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentEffort {
    pub provider: Provider,
    pub effort: Effort,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentModel {
    pub provider: Provider,
    pub model: String,
}

pub fn validate_model_id(model: &str) -> anyhow::Result<()> {
    if model.len() > 512
        || model.starts_with('-')
        || model.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        anyhow::bail!(
            "Use a model ID below 512 bytes, without spaces, line breaks or a leading hyphen."
        );
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentIdentity {
    pub provider: Provider,
    pub name: String,
    pub mention: String,
}

// Providers are connections. A chat's roster represents the coworkers using them.
const COWORKER_NAMES: &[&str] = &[
    "Maya", "Alex", "Avery", "Quinn", "Sage", "Kai", "Noah", "Emma", "Liam", "Olivia", "Ethan",
    "Isla", "Lucas", "Amelia", "Aria", "Leo", "Zoe", "Owen", "Ivy", "Finn", "Eva", "Theo", "Ruby",
    "Milo", "Elena", "Eli", "Nora", "Jude", "Clara", "Hugo", "Esme", "Max", "Lena", "Oscar",
    "Vera", "Luca", "Stella", "Ezra", "Iris", "Adam", "Mira", "Leah", "Ben", "Lucy", "Dylan",
    "Ada", "Rory", "Jade", "Wren", "Elise", "Nico", "Freya", "River", "Tessa", "Omar", "Anya",
];

pub fn canonical_mention(value: &str) -> Option<Provider> {
    let normalized = value.to_ascii_lowercase().replace(['_', '-'], "");
    Provider::ALL
        .into_iter()
        .find(|p| p.mention() == normalized)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentSession {
    pub provider: Provider,
    pub session_id: String,
    pub scope: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coworker_id: Option<Uuid>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatMessage {
    pub id: Uuid,
    pub at: DateTime<Utc>,
    pub kind: String,
    pub author: Option<Provider>,
    pub to: Vec<Provider>,
    pub text: String,
    pub status: Status,
    pub model: String,
    #[serde(default)]
    pub effort: Effort,
    pub session_id: Option<String>,
    pub logs: Vec<LogEntry>,
    pub usage: Usage,
    pub error: Option<String>,
    #[serde(default)]
    pub team_discussion: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub question_request: Option<crate::questions::QuestionRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_id: Option<Uuid>,
    #[serde(default)]
    pub recipient_ids: Vec<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_request: Option<crate::team::ApprovalRequest>,
}

impl ChatMessage {
    pub fn new(kind: &str, author: Option<Provider>, to: Vec<Provider>, text: String) -> Self {
        Self {
            id: Uuid::new_v4(),
            at: Utc::now(),
            kind: kind.into(),
            author,
            to,
            text,
            status: Status::Completed,
            model: String::new(),
            effort: Effort::Default,
            session_id: None,
            logs: vec![],
            usage: Usage::default(),
            error: None,
            team_discussion: false,
            question_request: None,
            author_id: None,
            recipient_ids: vec![],
            approval_request: None,
        }
    }
}

impl Conversation {
    pub fn fill_suggested_names(
        &mut self,
        other_coworkers: &[AgentIdentity],
    ) -> anyhow::Result<()> {
        for provider in self.members.clone() {
            if self.names.iter().any(|n| n.provider == provider) {
                continue;
            }
            let mut cycle = 1;
            let (name, mention) = 'available: loop {
                for base in
                    std::iter::once(provider.teammate_name()).chain(COWORKER_NAMES.iter().copied())
                {
                    let name = if cycle == 1 {
                        base.into()
                    } else {
                        format!("{base} {cycle}")
                    };
                    let mention = if cycle == 1 {
                        base.to_ascii_lowercase()
                    } else {
                        format!("{}{cycle}", base.to_ascii_lowercase())
                    };
                    if !self.names.iter().chain(other_coworkers).any(|n| {
                        n.name.eq_ignore_ascii_case(&name)
                            || n.mention.eq_ignore_ascii_case(&mention)
                    }) {
                        break 'available (name, mention);
                    }
                }
                cycle += 1;
            };
            self.rename(AgentIdentity {
                provider,
                name,
                mention,
            })?;
        }
        Ok(())
    }

    pub fn rename_team(&mut self, names: Vec<AgentIdentity>) -> anyhow::Result<()> {
        let providers: std::collections::HashSet<_> = names.iter().map(|n| n.provider).collect();
        if names.len() != self.members.len()
            || providers.len() != names.len()
            || self.members.iter().any(|p| !providers.contains(p))
        {
            anyhow::bail!("Name each teammate in this task exactly once.");
        }
        let mut proposed = Self {
            members: self.members.clone(),
            lead: self.lead,
            messages: vec![],
            sessions: vec![],
            names: vec![],
            models: vec![],
            efforts: vec![],
            pending_exchange: None,
            coworkers: vec![],
            lead_id: None,
            mailbox: vec![],
        };
        for identity in names {
            proposed.rename(identity)?;
        }
        self.names = proposed.names;
        Ok(())
    }

    pub fn set_model(&mut self, provider: Provider, model: &str) -> anyhow::Result<()> {
        if !self.members.contains(&provider) {
            anyhow::bail!("Choose an agent in this task's team.");
        }
        let model = model.trim();
        validate_model_id(model)?;
        self.models.retain(|m| m.provider != provider);
        if !model.is_empty() {
            self.models.push(AgentModel {
                provider,
                model: model.into(),
            });
        }
        Ok(())
    }

    pub fn set_effort(&mut self, provider: Provider, effort: Effort) -> anyhow::Result<()> {
        if !self.members.contains(&provider) {
            anyhow::bail!("Choose an agent in this task's team.");
        }
        self.efforts.retain(|e| e.provider != provider);
        if effort != Effort::Default {
            self.efforts.push(AgentEffort { provider, effort });
        }
        Ok(())
    }
    pub fn display_name(&self, provider: Provider) -> &str {
        self.names
            .iter()
            .find(|n| n.provider == provider)
            .map_or(provider.name(), |n| n.name.as_str())
    }

    pub fn handle(&self, provider: Provider) -> &str {
        self.names
            .iter()
            .find(|n| n.provider == provider)
            .map_or(provider.mention(), |n| n.mention.as_str())
    }

    pub fn resolve(&self, handle: &str) -> Option<Provider> {
        self.names
            .iter()
            .find(|n| n.mention.eq_ignore_ascii_case(handle))
            .map(|n| n.provider)
            .or_else(|| canonical_mention(handle))
    }

    pub fn rename(&mut self, mut identity: AgentIdentity) -> anyhow::Result<()> {
        use anyhow::bail;
        if !self.members.contains(&identity.provider) {
            bail!("Choose an agent in this task's team.");
        }
        identity.name = identity.name.trim().into();
        identity.mention = identity
            .mention
            .trim()
            .trim_start_matches('@')
            .to_ascii_lowercase();
        if identity.name.is_empty()
            || identity.name.chars().count() > 64
            || identity.name.chars().any(char::is_control)
        {
            bail!("Use a name with 1–64 characters and no line breaks.");
        }
        if identity.mention.is_empty()
            || identity.mention.len() > 32
            || !identity.mention.as_bytes()[0].is_ascii_lowercase()
            || !identity
                .mention
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_' || c == b'-')
        {
            bail!(
                "Use a handle with 1–32 letters, digits, underscores or hyphens, starting with a letter."
            );
        }
        if canonical_mention(&identity.mention).is_some_and(|p| p != identity.provider) {
            bail!("That handle is reserved for another provider.");
        }
        if self.names.iter().any(|n| {
            n.provider != identity.provider && n.mention.eq_ignore_ascii_case(&identity.mention)
        }) {
            bail!("Another agent in this task already uses that handle.");
        }
        if self.names.iter().any(|n| {
            n.provider != identity.provider && n.name.to_lowercase() == identity.name.to_lowercase()
        }) {
            bail!("Another teammate in this task already uses that name.");
        }
        self.names.retain(|n| n.provider != identity.provider);
        self.names.push(identity);
        Ok(())
    }

    pub fn bound(&mut self) {
        // Keep the original task and recent exchanges within the frontend's transport limit.
        let mut sizes: Vec<usize> = self
            .messages
            .iter()
            .map(|m| serde_json::to_vec(m).map_or(0, |v| v.len()))
            .collect();
        let mut total: usize = sizes.iter().sum();
        while self.messages.len() > 128 || (total > 4 * 1024 * 1024 && self.messages.len() > 2) {
            self.messages.remove(1);
            total -= sizes.remove(1);
        }
    }
}

impl Run {
    pub fn new(settings: &Settings, prompt: String) -> Self {
        Self {
            id: Uuid::new_v4(),
            prompt,
            workspace: settings.workspace.clone(),
            workflow: settings.workflow,
            created_at: Utc::now(),
            finished_at: None,
            status: Status::Queued,
            conversation: None,
            workspace_info: None,
            changes: None,
            stages: settings
                .agents
                .iter()
                .filter(|a| a.selected)
                .map(|a| Stage {
                    provider: a.provider,
                    model: a.model.clone(),
                    status: Status::Queued,
                    session_id: None,
                    output: String::new(),
                    logs: vec![],
                    usage: Usage::default(),
                    error: None,
                })
                .collect(),
        }
    }

    pub fn refresh_status(&mut self) {
        if self.stages.iter().any(|s| !s.status.terminal()) {
            self.status = if self
                .stages
                .iter()
                .any(|s| s.status == Status::Running || s.status.terminal())
            {
                Status::Running
            } else {
                Status::Queued
            };
        } else {
            self.status = if self.stages.iter().any(|s| s.status == Status::Failed) {
                Status::Failed
            } else if self.stages.iter().any(|s| s.status == Status::Interrupted) {
                Status::Interrupted
            } else if self.stages.iter().any(|s| s.status == Status::Cancelled) {
                Status::Cancelled
            } else {
                Status::Completed
            };
            if self.finished_at.is_none() {
                self.finished_at = Some(Utc::now());
            }
        }
    }

    pub fn title(&self) -> String {
        clip(self.prompt.lines().next().unwrap_or("Untitled task"), 58)
    }

    pub fn elapsed_seconds(&self) -> i64 {
        (self.finished_at.unwrap_or_else(Utc::now) - self.created_at)
            .num_seconds()
            .max(0)
    }

    pub fn recover(&mut self) {
        if let Some(chat) = &mut self.conversation {
            for mail in &mut chat.mailbox {
                if mail.state == crate::team::MailState::Delivered {
                    mail.state = crate::team::MailState::Paused;
                }
            }
            for worker in &mut chat.coworkers {
                if worker.attention == crate::team::Attention::Working {
                    worker.attention = crate::team::Attention::Queued;
                }
            }
            for message in &mut chat.messages {
                if let Some(approval) = &mut message.approval_request
                    && approval.decision == Some(true)
                    && approval.result.is_none()
                {
                    approval.result = Some(crate::workspace::CheckResult { id: Uuid::new_v4(), at: Utc::now(), owner_id: message.author_id, argv: approval.argv.clone(), status: Status::Interrupted, exit_code: None, output: "The app closed during this command. Its final result is unknown. Inspect the workspace before requesting another execution.".into() });
                    message.status = Status::Interrupted;
                    for mail in &mut chat.mailbox {
                        if mail.response_id == Some(message.id) {
                            mail.state = crate::team::MailState::Paused;
                            mail.text.push_str("\nThe previously approved command was interrupted. Its outcome is unknown. Inspect the workspace and request fresh approval before rerunning it.");
                        }
                    }
                }
                if !message.status.terminal() {
                    message.status = Status::Interrupted;
                }
            }
            if !self.status.terminal() {
                self.status = Status::Interrupted;
                self.finished_at = Some(Utc::now());
            }
            if chat.messages.iter().any(|m| {
                m.question_request
                    .as_ref()
                    .is_some_and(|q| q.answers.is_none())
                    || m.approval_request
                        .as_ref()
                        .is_some_and(|q| q.decision.is_none())
            }) {
                self.status = Status::WaitingForUser;
            }
            return;
        }
        if !self.status.terminal() {
            for stage in &mut self.stages {
                if !stage.status.terminal() {
                    stage.status = Status::Interrupted;
                    stage.log(LogKind::Warning, "The dashboard closed before this stage finished. Start a new run to retry.".into());
                }
            }
            self.refresh_status();
        }
    }

    pub fn markdown(&self) -> String {
        let mut text = format!(
            "# {}\n\n{} · {}\n\nWorkspace: {}\n\n## Task\n\n{}\n",
            self.title(),
            self.workflow.name(),
            self.status.name(),
            self.workspace,
            self.prompt
        );
        if let Some(chat) = &self.conversation {
            if !chat.coworkers.is_empty() {
                text.push_str("\n## Coworkers\n\n");
                for worker in &chat.coworkers {
                    text.push_str(&format!(
                        "- {} (@{}): {:?} · {} · model `{}` · effort `{}`\n",
                        worker.name,
                        worker.mention,
                        worker.role,
                        worker.provider.name(),
                        if worker.model.is_empty() {
                            "Default"
                        } else {
                            &worker.model
                        },
                        worker.effort.value()
                    ));
                }
            }
            if !chat.efforts.is_empty() {
                text.push_str("\n## Selected effort\n\n");
                for choice in &chat.efforts {
                    text.push_str(&format!(
                        "- {}: `{}`\n",
                        chat.display_name(choice.provider),
                        choice.effort.value()
                    ));
                }
            }
            if !chat.models.is_empty() {
                text.push_str("\n## Selected models\n\n");
                for model in &chat.models {
                    text.push_str(&format!(
                        "- {}: `{}`\n",
                        chat.display_name(model.provider),
                        model.model
                    ));
                }
            }
            for message in &chat.messages {
                let author = message
                    .author_id
                    .and_then(|id| chat.coworkers.iter().find(|c| c.id == id))
                    .map(|c| c.name.as_str())
                    .unwrap_or_else(|| {
                        message.author.map_or(
                            if message.kind == "system" {
                                "Conductor"
                            } else {
                                "You"
                            },
                            |p| chat.display_name(p),
                        )
                    });
                let to = if !message.recipient_ids.is_empty() {
                    message
                        .recipient_ids
                        .iter()
                        .filter_map(|id| {
                            chat.coworkers
                                .iter()
                                .find(|c| c.id == *id)
                                .map(|c| c.name.as_str())
                        })
                        .collect::<Vec<_>>()
                        .join(", ")
                } else {
                    message
                        .to
                        .iter()
                        .map(|p| chat.display_name(*p))
                        .collect::<Vec<_>>()
                        .join(", ")
                };
                text.push_str(&format!(
                    "\n## {author}{}\n\n{}\n",
                    if to.is_empty() {
                        String::new()
                    } else {
                        format!(" → {to}")
                    },
                    message.text
                ));
                if let Some(approval) = &message.approval_request {
                    text.push_str(&format!(
                        "\nApproval: {}\n\nArguments: `{}`\n\nDecision: {:?}\n",
                        approval.summary,
                        serde_json::to_string(&approval.argv).unwrap_or_default(),
                        approval.decision
                    ));
                    if let Some(result) = &approval.result {
                        text.push_str(&format!(
                            "\nActual result: {:?}, exit {:?}\n\n```text\n{}\n```\n",
                            result.status, result.exit_code, result.output
                        ));
                    }
                }
                if message.team_discussion {
                    text.push_str("\n*Team discussion*\n");
                }
                if let Some(request) = &message.question_request {
                    text.push_str(&request.markdown());
                }
                if let Some(error) = &message.error {
                    text.push_str(&format!("\nError: {error}\n"));
                }
            }
            return text;
        }
        for stage in &self.stages {
            text.push_str(&format!(
                "\n## {} — {}\n\n{}\n",
                stage.provider.name(),
                stage.status.name(),
                stage.output
            ));
            if let Some(error) = &stage.error {
                text.push_str(&format!("\nError: {error}\n"));
            }
        }
        text
    }
}

pub fn clip(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_owned();
    }
    if max_bytes < 3 {
        return String::new();
    }
    let mut end = max_bytes - 3;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &value[..end])
}

pub fn demo_runs(settings: &Settings) -> Vec<Run> {
    let mut demo_settings = settings.clone();
    demo_settings.workflow = Workflow::Collaborate;
    for config in &mut demo_settings.agents {
        config.selected = matches!(
            config.provider,
            Provider::Claude | Provider::Codex | Provider::Qoder
        );
    }
    let mut run = Run::new(
        &demo_settings,
        "Review the authentication flow and propose a focused fix".into(),
    );
    run.created_at = Utc::now() - chrono::Duration::minutes(8);
    run.finished_at = Some(run.created_at + chrono::Duration::seconds(42));
    run.status = Status::Completed;
    let samples = [
        "## A concrete path forward\n\nThe token refresh boundary is the right place to focus the review.\n\n- Check concurrent refresh requests for duplicate work.\n- Keep authentication failures separate from transient network errors.\n- Add coverage for expired sessions and cancelled requests.\n\nThe next agent can use these findings to develop the fix.\n\nThis is sample data for the dashboard preview.",
        "## Proposed implementation\n\nShare a single in-flight refresh future and release it when the request finishes.\n\n```rust\nlet session = refresh_once().await?;\nretry_with_session(session).await\n```\n\nThis is a sample response. No workspace files were modified.",
        "## Review complete\n\nThe proposed change addresses the concurrent refresh boundary. Validate cancellation and failed refresh cleanup before merging.\n\nThis is a sample response. No tests or agents were run.",
    ];
    for (index, stage) in run.stages.iter_mut().enumerate() {
        stage.status = Status::Completed;
        stage.output = samples[index].into();
        stage.session_id = Some(format!("sample-session-{index}"));
        stage.usage.input_tokens = 4200 + index as u64 * 1700;
        stage.usage.output_tokens = 280 + index as u64 * 90;
        stage.log(LogKind::Info, "Sample handoff received".into());
        stage.log(LogKind::Tool, "Sample workspace inspection".into());
        stage.log(LogKind::Info, "Sample stage completed".into());
    }
    vec![run]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_settings_keep_the_selected_workspace_as_the_only_folder() {
        let mut value = serde_json::to_value(Settings::default()).unwrap();
        value["workspace"] = "/saved/project".into();
        value.as_object_mut().unwrap().remove("workspace_folders");
        let mut settings: Settings = serde_json::from_value(value).unwrap();
        settings.repair();
        assert_eq!(settings.workspace, "/saved/project");
        assert_eq!(settings.workspace_folders, ["/saved/project"]);
    }

    #[test]
    fn folder_repair_preserves_order_and_an_intentionally_empty_workspace() {
        let mut settings = Settings {
            workspace: "/second".into(),
            workspace_folders: vec![
                "/first".into(),
                "".into(),
                "/second".into(),
                "/first".into(),
            ],
            ..Settings::default()
        };
        settings.repair();
        assert_eq!(settings.workspace_folders, ["/first", "/second"]);
        settings.workspace.clear();
        settings.repair();
        assert_eq!(settings.workspace, "/first");
        settings.workspace.clear();
        settings.workspace_folders.clear();
        settings.repair();
        assert!(settings.workspace.is_empty());
        assert!(settings.workspace_folders.is_empty());
    }

    #[test]
    fn settings_repair_preserves_collaboration_order() {
        let mut settings = Settings::default();
        settings.agents.swap(0, 1);
        settings.agents.truncate(2);
        settings.repair();
        assert_eq!(settings.agents[0].provider, Provider::Codex);
        assert_eq!(settings.agents[1].provider, Provider::Claude);
        assert_eq!(settings.agents.len(), Provider::ALL.len());
    }

    #[test]
    fn interrupted_runs_recover_without_losing_completed_stages() {
        let mut run = Run::new(&Settings::default(), "task".into());
        run.status = Status::Running;
        run.stages[0].status = Status::Completed;
        run.stages[0].output = "keep me".into();
        run.recover();
        assert_eq!(run.status, Status::Interrupted);
        assert_eq!(run.stages[0].status, Status::Completed);
        assert_eq!(run.stages[0].output, "keep me");
        assert_eq!(run.stages[1].status, Status::Interrupted);
    }

    #[test]
    fn chat_recovery_and_retention_keep_the_task_and_agent_sessions() {
        let mut run = Run::new(&Settings::default(), "Original task".into());
        run.workflow = Workflow::Conversation;
        run.status = Status::Running;
        let original = ChatMessage::new("user", None, vec![Provider::Claude], run.prompt.clone());
        let original_id = original.id;
        let mut active = ChatMessage::new(
            "assistant",
            Some(Provider::Claude),
            vec![],
            "Partial reply".into(),
        );
        active.status = Status::Running;
        let session = AgentSession {
            provider: Provider::Claude,
            session_id: "specific-session".into(),
            scope: "specific-profile".into(),
            coworker_id: None,
        };
        run.conversation = Some(Conversation {
            members: vec![Provider::Claude],
            lead: Provider::Claude,
            messages: vec![original, active],
            sessions: vec![session],
            names: vec![],
            models: vec![],
            efforts: vec![],
            pending_exchange: None,
            coworkers: vec![],
            lead_id: None,
            mailbox: vec![],
        });
        run.recover();
        assert_eq!(run.status, Status::Interrupted);
        let chat = run.conversation.as_mut().unwrap();
        assert_eq!(chat.messages[1].status, Status::Interrupted);
        assert_eq!(chat.messages[1].text, "Partial reply");
        for _ in 0..150 {
            chat.messages.push(ChatMessage::new(
                "assistant",
                Some(Provider::Claude),
                vec![],
                "界".repeat(30000),
            ));
        }
        chat.bound();
        assert!(chat.messages.len() <= 128);
        assert!(serde_json::to_vec(&chat.messages).unwrap().len() <= 4 * 1024 * 1024);
        assert_eq!(chat.messages[0].id, original_id);
        let restored: Run = serde_json::from_slice(&serde_json::to_vec(&run).unwrap()).unwrap();
        assert_eq!(
            restored.conversation.unwrap().sessions[0].session_id,
            "specific-session"
        );
    }

    #[test]
    fn clipping_preserves_utf8_and_obeys_budget() {
        let clipped = clip("hello 世界世界世界", 13);
        assert!(clipped.len() <= 13);
        assert!(clipped.ends_with('…'));
    }

    #[test]
    fn agent_names_are_task_scoped_and_do_not_change_native_sessions() {
        let mut chat = Conversation {
            members: vec![Provider::Claude, Provider::Codex],
            lead: Provider::Claude,
            messages: vec![],
            sessions: vec![AgentSession {
                provider: Provider::Claude,
                session_id: "original-session".into(),
                scope: "original-profile".into(),
                coworker_id: None,
            }],
            names: vec![],
            models: vec![],
            efforts: vec![],
            pending_exchange: None,
            coworkers: vec![],
            lead_id: None,
            mailbox: vec![],
        };
        chat.rename(AgentIdentity {
            provider: Provider::Claude,
            name: " Atlas ".into(),
            mention: "@ATLAS".into(),
        })
        .unwrap();
        assert_eq!(chat.display_name(Provider::Claude), "Atlas");
        assert_eq!(chat.resolve("ATLAS"), Some(Provider::Claude));
        assert_eq!(chat.resolve("claude"), Some(Provider::Claude));
        assert_eq!(chat.sessions[0].session_id, "original-session");
        assert_eq!(chat.sessions[0].scope, "original-profile");
        for (provider, name, mention) in [
            (Provider::Codex, "Nova", "atlas"),
            (Provider::Claude, "Atlas", "codex"),
            (Provider::Claude, "Atlas", "deep_seek"),
            (Provider::Claude, "Atlas", "9bad"),
            (Provider::Claude, "Atlas\nBad", "atlas"),
            (Provider::Qoder, "Sage", "sage"),
        ] {
            assert!(
                chat.rename(AgentIdentity {
                    provider,
                    name: name.into(),
                    mention: mention.into()
                })
                .is_err()
            );
        }
        let restored: Conversation =
            serde_json::from_value(serde_json::to_value(&chat).unwrap()).unwrap();
        assert_eq!(restored.handle(Provider::Claude), "atlas");
        let mut legacy = serde_json::to_value(chat).unwrap();
        legacy.as_object_mut().unwrap().remove("names");
        let legacy: Conversation = serde_json::from_value(legacy).unwrap();
        assert_eq!(legacy.display_name(Provider::Claude), "Claude");
        assert_eq!(legacy.resolve("atlas"), None);
    }

    #[test]
    fn employee_rosters_preserve_custom_names_and_avoid_collisions() {
        let mut chat = Conversation {
            members: Provider::ALL.to_vec(),
            lead: Provider::Claude,
            messages: vec![],
            sessions: vec![],
            names: vec![AgentIdentity {
                provider: Provider::Claude,
                name: "Alex".into(),
                mention: "alex".into(),
            }],
            models: vec![],
            efforts: vec![],
            pending_exchange: None,
            coworkers: vec![],
            lead_id: None,
            mailbox: vec![],
        };
        chat.fill_suggested_names(&[]).unwrap();
        assert_eq!(chat.names.len(), 6);
        assert_eq!(chat.display_name(Provider::Claude), "Alex");
        assert_eq!(chat.display_name(Provider::Codex), "Maya");
        assert_eq!(chat.handle(Provider::Codex), "maya");
        assert_eq!(chat.resolve("alex"), Some(Provider::Claude));
        assert_eq!(chat.resolve("maya"), Some(Provider::Codex));
        assert_eq!(chat.resolve("codex"), Some(Provider::Codex));
        let before = chat.names.clone();
        chat.fill_suggested_names(&[]).unwrap();
        assert_eq!(chat.names, before);
        let restored: Conversation =
            serde_json::from_value(serde_json::to_value(chat).unwrap()).unwrap();
        assert_eq!(restored.names, before);
    }

    #[test]
    fn new_chat_coworkers_avoid_other_chats_and_remain_stable_when_names_run_out() {
        let mut other_coworkers = vec![AgentIdentity {
            provider: Provider::Claude,
            name: "A custom coworker".into(),
            mention: "MAYA".into(),
        }];
        for _ in 0..12 {
            let mut chat = Conversation {
                members: Provider::ALL.to_vec(),
                lead: Provider::Claude,
                messages: vec![],
                sessions: vec![],
                names: vec![],
                models: vec![],
                efforts: vec![],
                pending_exchange: None,
                coworkers: vec![],
                lead_id: None,
                mailbox: vec![],
            };
            chat.fill_suggested_names(&other_coworkers).unwrap();
            for identity in &chat.names {
                assert!(!other_coworkers.iter().any(|old| {
                    old.name.eq_ignore_ascii_case(&identity.name)
                        || old.mention.eq_ignore_ascii_case(&identity.mention)
                }));
                assert_eq!(chat.resolve(&identity.mention), Some(identity.provider));
                assert_eq!(
                    chat.resolve(identity.provider.mention()),
                    Some(identity.provider)
                );
            }
            let roster = chat.names.clone();
            other_coworkers.extend(roster.clone());
            chat.fill_suggested_names(&other_coworkers).unwrap();
            assert_eq!(chat.names, roster);
            let restored: Conversation =
                serde_json::from_value(serde_json::to_value(chat).unwrap()).unwrap();
            assert_eq!(restored.names, roster);
        }
        assert!(
            other_coworkers
                .iter()
                .any(|identity| identity.mention.ends_with('2'))
        );
    }

    #[test]
    fn team_rename_is_atomic_and_preserves_sessions_models_and_messages() {
        let mut chat = Conversation {
            members: vec![Provider::Claude, Provider::Codex],
            lead: Provider::Claude,
            messages: vec![ChatMessage::new(
                "assistant",
                Some(Provider::Claude),
                vec![],
                "Saved response".into(),
            )],
            sessions: vec![AgentSession {
                provider: Provider::Claude,
                session_id: "same-session".into(),
                scope: "same-model".into(),
                coworker_id: None,
            }],
            names: vec![],
            models: vec![AgentModel {
                provider: Provider::Claude,
                model: "sonnet".into(),
            }],
            efforts: vec![AgentEffort {
                provider: Provider::Claude,
                effort: Effort::High,
            }],
            pending_exchange: None,
            coworkers: vec![],
            lead_id: None,
            mailbox: vec![],
        };
        chat.fill_suggested_names(&[]).unwrap();
        let mut swapped = chat.names.clone();
        swapped[0].name = "Alex".into();
        swapped[0].mention = "alex".into();
        swapped[1].name = "Maya".into();
        swapped[1].mention = "maya".into();
        chat.rename_team(swapped).unwrap();
        assert_eq!(chat.resolve("alex"), Some(Provider::Claude));
        assert_eq!(chat.resolve("maya"), Some(Provider::Codex));
        assert_eq!(chat.sessions[0].session_id, "same-session");
        assert_eq!(chat.models[0].model, "sonnet");
        assert_eq!(chat.efforts[0].effort, Effort::High);
        assert_eq!(chat.messages[0].text, "Saved response");
        let snapshot = serde_json::to_value(&chat).unwrap();
        for invalid in [
            vec![chat.names[0].clone()],
            vec![chat.names[0].clone(), chat.names[0].clone()],
            vec![
                chat.names[0].clone(),
                AgentIdentity {
                    provider: Provider::Codex,
                    name: "Other".into(),
                    mention: "alex".into(),
                },
            ],
            vec![
                chat.names[0].clone(),
                AgentIdentity {
                    provider: Provider::Codex,
                    name: "aLEX".into(),
                    mention: "other".into(),
                },
            ],
            vec![
                chat.names[0].clone(),
                AgentIdentity {
                    provider: Provider::Codex,
                    name: "Other".into(),
                    mention: "claude".into(),
                },
            ],
        ] {
            assert!(chat.rename_team(invalid).is_err());
            assert_eq!(serde_json::to_value(&chat).unwrap(), snapshot);
        }
    }

    #[test]
    fn chat_effort_choices_migrate_persist_and_clear_without_losing_sessions() {
        let mut value = serde_json::to_value(Settings::default()).unwrap();
        for agent in value["agents"].as_array_mut().unwrap() {
            agent.as_object_mut().unwrap().remove("effort");
        }
        let settings: Settings = serde_json::from_value(value).unwrap();
        assert!(settings.agents.iter().all(|a| a.effort == Effort::Default));
        let mut chat: Conversation = serde_json::from_value(serde_json::json!({
            "members": ["claude", "codex"], "lead":"claude", "messages":[], "sessions": [{"provider":"codex", "session_id":"owned", "scope":"original"}]
        })).unwrap();
        assert!(chat.efforts.is_empty());
        chat.set_effort(Provider::Codex, Effort::High).unwrap();
        chat.set_effort(Provider::Codex, Effort::Max).unwrap();
        let mut restored: Conversation =
            serde_json::from_value(serde_json::to_value(&chat).unwrap()).unwrap();
        assert_eq!(
            restored.efforts,
            vec![AgentEffort {
                provider: Provider::Codex,
                effort: Effort::Max
            }]
        );
        assert!(restored.set_effort(Provider::Kiro, Effort::Low).is_err());
        restored
            .set_effort(Provider::Codex, Effort::Default)
            .unwrap();
        assert!(restored.efforts.is_empty());
        assert_eq!(restored.sessions[0].session_id, "owned");
        assert!(serde_json::from_str::<Effort>("\"unlimited\"").is_err());
    }

    #[test]
    fn chat_model_choices_survive_restart_and_default_clear_preserves_session_metadata() {
        let mut chat = Conversation {
            members: vec![Provider::Claude, Provider::Codex],
            lead: Provider::Claude,
            messages: vec![],
            names: vec![],
            models: vec![],
            efforts: vec![],
            pending_exchange: None,
            coworkers: vec![],
            lead_id: None,
            mailbox: vec![],
            sessions: vec![AgentSession {
                provider: Provider::Codex,
                session_id: "owned-session".into(),
                scope: "old-model".into(),
                coworker_id: None,
            }],
        };
        chat.set_model(Provider::Codex, "  codex-model-a  ")
            .unwrap();
        chat.set_model(Provider::Codex, "codex-model-b").unwrap();
        assert_eq!(
            chat.models,
            [AgentModel {
                provider: Provider::Codex,
                model: "codex-model-b".into()
            }]
        );
        let restored: Conversation =
            serde_json::from_slice(&serde_json::to_vec(&chat).unwrap()).unwrap();
        assert_eq!(restored.models, chat.models);
        assert_eq!(restored.sessions[0].session_id, "owned-session");
        assert!(chat.set_model(Provider::Kiro, "auto").is_err());
        for invalid in ["--model=x", "two models", "model\0suffix", "model\nsecond"] {
            assert!(chat.set_model(Provider::Codex, invalid).is_err());
        }
        assert_eq!(chat.models.len(), 1);
        chat.set_model(Provider::Codex, "").unwrap();
        assert!(chat.models.is_empty());
        let mut legacy = serde_json::to_value(&chat).unwrap();
        legacy.as_object_mut().unwrap().remove("models");
        let legacy: Conversation = serde_json::from_value(legacy).unwrap();
        assert!(legacy.models.is_empty());
    }

    #[test]
    fn failure_takes_priority_over_cancelled_relay_stages() {
        let mut run = Run::new(&Settings::default(), "task".into());
        run.stages[0].status = Status::Failed;
        run.stages[1].status = Status::Cancelled;
        run.refresh_status();
        assert_eq!(run.status, Status::Failed);
        assert!(run.finished_at.is_some());
    }
}
