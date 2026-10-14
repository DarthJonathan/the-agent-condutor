//! Read Claude routing metadata without sending credentials to the UI or changing its files.
use crate::model::ClaudeBackend;
use anyhow::{Context, Result, bail};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
};

const ROUTING: &[&str] = &[
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
];
const AUTH: &[&str] = &[
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_CUSTOM_HEADERS",
];

#[derive(Clone, Serialize)]
pub struct Source {
    pub name: String,
    pub path: Option<String>,
    pub exists: bool,
    pub supplies: Vec<String>,
    pub error: Option<String>,
}

#[derive(Clone, Serialize)]
pub struct Snapshot {
    pub workspace: String,
    pub config_dir_override: String,
    pub config_dir: String,
    pub backend: String,
    pub endpoint: String,
    pub model: String,
    pub conductor_model: String,
    pub source: String,
    pub credential_configured: bool,
    pub managed_routing: bool,
    pub sources: Vec<Source>,
}

pub struct Inspection {
    pub snapshot: Snapshot,
    env: BTreeMap<String, String>,
    helper: bool,
}

// Not Debug or Serialize: the environment includes secrets used only by the child process.
pub struct Override {
    env: BTreeMap<String, String>,
    model: String,
    clear_helper: bool,
}

fn backend(env: &BTreeMap<String, String>) -> &'static str {
    for (variable, provider) in [
        ("CLAUDE_CODE_USE_BEDROCK", "Amazon Bedrock"),
        ("CLAUDE_CODE_USE_VERTEX", "Google Vertex"),
        ("CLAUDE_CODE_USE_FOUNDRY", "Microsoft Foundry"),
    ] {
        if env
            .get(variable)
            .is_some_and(|value| matches!(value.as_str(), "1" | "true"))
        {
            return provider;
        }
    }
    match env
        .get("ANTHROPIC_BASE_URL")
        .filter(|value| !value.is_empty())
    {
        None => "Claude (Anthropic)",
        Some(endpoint) => match reqwest::Url::parse(endpoint)
            .ok()
            .and_then(|url| url.host_str().map(str::to_owned))
            .as_deref()
        {
            Some("api.anthropic.com") => "Claude (Anthropic)",
            Some("api.deepseek.com") => "DeepSeek",
            _ => "Custom endpoint",
        },
    }
}

fn safe_endpoint(raw: &str) -> String {
    let Ok(mut url) = reqwest::Url::parse(raw) else {
        return "Invalid endpoint".into();
    };
    let _ = url.set_username("");
    let _ = url.set_password(None);
    url.set_query(None);
    url.set_fragment(None);
    url.to_string().trim_end_matches('/').to_owned()
}

fn nonempty(env: &BTreeMap<String, String>, name: &str) -> bool {
    env.get(name).is_some_and(|value| !value.is_empty())
}

pub fn config_directory(override_dir: &str) -> PathBuf {
    let selected = if override_dir.trim().is_empty() {
        std::env::var("CLAUDE_CONFIG_DIR").unwrap_or_default()
    } else {
        override_dir.to_owned()
    };
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    if selected.trim().is_empty() {
        home.join(".claude")
    } else if selected == "~" {
        home
    } else if let Some(path) = selected.strip_prefix("~/") {
        home.join(path)
    } else {
        let path = PathBuf::from(selected);
        if path.is_absolute() {
            path
        } else {
            std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(path)
        }
    }
}

pub fn inspect(workspace: &str, override_dir: &str) -> Inspection {
    let directory = config_directory(override_dir);
    let project = PathBuf::from(workspace);
    let mut files = vec![(
        "User settings".to_owned(),
        directory.join("settings.json"),
        false,
    )];
    if !workspace.is_empty() {
        files.push((
            "Project settings".into(),
            project.join(".claude/settings.json"),
            false,
        ));
        files.push((
            "Local project settings".into(),
            project.join(".claude/settings.local.json"),
            false,
        ));
        // Recent CLIs also read local settings at the repository/main-worktree root.
        if let Some(root) = local_root(&project)
            && root != project
        {
            files.push((
                "Repository local settings".into(),
                root.join(".claude/settings.local.json"),
                false,
            ));
        }
    }
    #[cfg(target_os = "macos")]
    let managed = PathBuf::from("/Library/Application Support/ClaudeCode");
    #[cfg(target_os = "windows")]
    let managed = PathBuf::from("C:/Program Files/ClaudeCode");
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let managed = PathBuf::from("/etc/claude-code");
    files.push((
        "Managed settings".into(),
        managed.join("managed-settings.json"),
        true,
    ));
    if let Ok(entries) = fs::read_dir(managed.join("managed-settings.d")) {
        let mut paths: Vec<_> = entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .is_some_and(|extension| extension == "json")
            })
            .collect();
        paths.sort();
        files.extend(
            paths
                .into_iter()
                .map(|path| ("Managed settings".into(), path, true)),
        );
    }
    inspect_sources(
        workspace,
        override_dir,
        &directory,
        std::env::vars()
            .filter(|(key, _)| ROUTING.contains(&key.as_str()) || AUTH.contains(&key.as_str()))
            .collect(),
        files,
    )
}

fn local_root(project: &Path) -> Option<PathBuf> {
    for root in project.ancestors() {
        let git = root.join(".git");
        if git.is_dir() {
            return Some(root.to_owned());
        }
        if git.is_file() {
            let contents = fs::read_to_string(git).ok()?;
            let directory = root.join(contents.trim().strip_prefix("gitdir: ")?);
            let common = fs::read_to_string(directory.join("commondir")).ok()?;
            return directory
                .join(common.trim())
                .canonicalize()
                .ok()?
                .parent()
                .map(Path::to_owned);
        }
    }
    None
}

fn inspect_sources(
    workspace: &str,
    override_dir: &str,
    directory: &Path,
    mut env: BTreeMap<String, String>,
    files: Vec<(String, PathBuf, bool)>,
) -> Inspection {
    let mut sources = vec![Source {
        name: "App environment".into(),
        path: None,
        exists: true,
        supplies: env
            .keys()
            .filter(|key| ROUTING.contains(&key.as_str()))
            .cloned()
            .collect(),
        error: None,
    }];
    let mut origins: BTreeMap<String, String> = env
        .keys()
        .map(|key| (key.clone(), "App environment".into()))
        .collect();
    let mut helper = false;
    let mut managed_routing = false;
    let mut model = String::new();
    let mut model_source = String::new();
    for (name, path, managed) in files {
        let mut source = Source {
            name: name.clone(),
            path: Some(path.display().to_string()),
            exists: path.exists(),
            supplies: vec![],
            error: None,
        };
        let parsed = (|| -> Result<Option<Value>> {
            let size = match fs::metadata(&path) {
                Ok(metadata) if metadata.is_file() => metadata.len(),
                Ok(_) => bail!("Settings path must be a regular file"),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(error) => return Err(error.into()),
            };
            if size > 2 * 1024 * 1024 {
                bail!("Settings file exceeds 2 MiB");
            }
            let value: Value =
                serde_json::from_slice(&fs::read(&path)?).context("Invalid settings JSON")?;
            if !value.is_object() {
                bail!("Settings must be a JSON object");
            }
            if value.get("env").is_some_and(|value| !value.is_object()) {
                bail!("The env setting must be a JSON object");
            }
            for key in ROUTING.iter().chain(AUTH) {
                if value["env"]
                    .get(*key)
                    .is_some_and(|value| !value.is_string())
                {
                    bail!("The {key} environment setting must be a string");
                }
            }
            Ok(Some(value))
        })();
        match parsed {
            Ok(Some(value)) => {
                if let Some(value) = value["model"].as_str() {
                    model = value.to_owned();
                    model_source = name.clone();
                    source.supplies.push("model".into());
                    if managed {
                        managed_routing = true;
                    }
                }
                if let Some(value) = value["apiKeyHelper"].as_str() {
                    helper = !value.is_empty();
                    if managed && helper {
                        managed_routing = true;
                    }
                }
                for key in ROUTING.iter().chain(AUTH) {
                    if let Some(value) = value["env"][*key].as_str() {
                        env.insert((*key).into(), value.into());
                        origins.insert((*key).into(), name.clone());
                        if ROUTING.contains(key) {
                            source.supplies.push((*key).into());
                        }
                        if managed {
                            managed_routing = true;
                        }
                    }
                }
            }
            Ok(None) => {}
            Err(error) => {
                source.exists = true;
                source.error = Some(format!("{error:#}"));
            }
        }
        sources.push(source);
    }
    if let Some(value) = env.get("ANTHROPIC_MODEL").filter(|value| !value.is_empty()) {
        model = value.clone();
        model_source = origins["ANTHROPIC_MODEL"].clone();
    }
    if model.is_empty() {
        model = env
            .get("ANTHROPIC_DEFAULT_SONNET_MODEL")
            .filter(|value| !value.is_empty())
            .cloned()
            .unwrap_or_else(|| "CLI default".into());
    }
    let route = backend(&env);
    let endpoint = env
        .get("ANTHROPIC_BASE_URL")
        .filter(|value| !value.is_empty())
        .map(String::as_str)
        .unwrap_or("https://api.anthropic.com");
    let source = [
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        "ANTHROPIC_BASE_URL",
    ]
    .iter()
    .find_map(|key| {
        if (*key == "ANTHROPIC_BASE_URL" && nonempty(&env, key))
            || env
                .get(*key)
                .is_some_and(|value| matches!(value.as_str(), "1" | "true"))
        {
            origins.get(*key).cloned()
        } else {
            None
        }
    })
    .unwrap_or_else(|| {
        if model_source.is_empty() {
            "Claude Code default".into()
        } else {
            model_source
        }
    });
    let snapshot = Snapshot {
        workspace: workspace.into(),
        config_dir_override: override_dir.into(),
        config_dir: directory.display().to_string(),
        backend: route.into(),
        endpoint: safe_endpoint(endpoint),
        model,
        conductor_model: String::new(),
        source,
        credential_configured: AUTH.iter().any(|key| nonempty(&env, key)) || helper,
        managed_routing,
        sources,
    };
    let mut snapshot = snapshot;
    if route == "DeepSeek" {
        snapshot.conductor_model = deepseek_model(&snapshot.model).unwrap_or_else(|| {
            deepseek_model(
                env.get("ANTHROPIC_DEFAULT_SONNET_MODEL")
                    .map_or("", String::as_str),
            )
            .unwrap_or_else(|| "deepseek-flash".into())
        });
    } else {
        snapshot.conductor_model = snapshot.model.clone();
    }
    Inspection {
        snapshot,
        env,
        helper,
    }
}

impl Inspection {
    pub fn snippets_override(&self, model: &str) -> Result<Override> {
        if self.snapshot.sources.iter().any(|s| s.error.is_some()) {
            bail!("Fix unreadable Claude settings in Connections before using snippets-only access.");
        }
        if self.helper && !AUTH.iter().any(|key| nonempty(&self.env, key)) {
            bail!("Snippets-only access cannot execute apiKeyHelper. Supply a session API key or OAuth token in Connections.");
        }
        Ok(Override { env: self.env.clone(), model: if model.is_empty() { self.snapshot.conductor_model.clone() } else { model.into() }, clear_helper: true })
    }
    pub fn is_deepseek(&self) -> bool {
        self.snapshot.backend == "DeepSeek"
    }
    pub fn override_for(
        &self,
        mode: ClaudeBackend,
        base_url: &str,
        model: &str,
        session_key: &str,
    ) -> Result<Option<Override>> {
        if mode == ClaudeBackend::Inherit {
            if self.is_deepseek() {
                let chosen = if model.trim().is_empty() {
                    &self.snapshot.conductor_model
                } else {
                    model
                };
                let endpoint = self
                    .env
                    .get("ANTHROPIC_BASE_URL")
                    .context("DeepSeek endpoint missing")?;
                return self.override_for(ClaudeBackend::DeepSeek, endpoint, chosen, "");
            }
            return Ok(None);
        }
        if self.snapshot.managed_routing {
            bail!(
                "Claude provider routing is controlled by managed settings. Use the detected configuration."
            );
        }
        if self
            .snapshot
            .sources
            .iter()
            .any(|source| source.error.is_some())
        {
            bail!(
                "Fix the unreadable Claude settings file shown in Connections before overriding its provider."
            );
        }
        let (endpoint, default_model, target) = match mode {
            ClaudeBackend::Anthropic => (
                "https://api.anthropic.com".to_owned(),
                "sonnet",
                "Claude (Anthropic)",
            ),
            ClaudeBackend::DeepSeek => (deepseek_endpoint(base_url), "deepseek-flash", "DeepSeek"),
            ClaudeBackend::Custom => (
                base_url.trim_end_matches('/').to_owned(),
                "",
                "Custom endpoint",
            ),
            ClaudeBackend::Inherit => unreachable!(),
        };
        crate::runner::validate_api_url(&endpoint)?;
        let chosen_model = if model.trim().is_empty() {
            default_model
        } else {
            model.trim()
        };
        if chosen_model.is_empty() {
            bail!("Enter a model ID for the custom Claude endpoint.");
        }
        let normalized_model;
        let chosen_model = if mode == ClaudeBackend::DeepSeek {
            normalized_model = deepseek_model(chosen_model).context("DeepSeek requires deepseek-flash or deepseek-v4-pro. A Claude model name cannot be sent to this endpoint.")?;
            normalized_model.as_str()
        } else {
            chosen_model
        };
        let mut env: BTreeMap<_, _> = ROUTING
            .iter()
            .chain(AUTH)
            .map(|key| ((*key).to_owned(), String::new()))
            .collect();
        let matching = self.snapshot.backend == target
            && (mode == ClaudeBackend::Anthropic
                || self.snapshot.endpoint == safe_endpoint(&endpoint));
        if matching {
            for key in AUTH {
                if let Some(value) = self.env.get(*key) {
                    env.insert((*key).into(), value.clone());
                }
            }
        }
        if !session_key.trim().is_empty() {
            for key in AUTH {
                env.insert((*key).into(), String::new());
            }
            env.insert(
                if mode == ClaudeBackend::Anthropic {
                    "ANTHROPIC_API_KEY"
                } else {
                    "ANTHROPIC_AUTH_TOKEN"
                }
                .into(),
                session_key.trim().into(),
            );
        }
        if mode != ClaudeBackend::Anthropic
            && !AUTH.iter().any(|key| nonempty(&env, key))
            && !(matching && self.helper)
        {
            bail!(
                "Enter a session API key for the selected Claude backend, or use its detected configuration."
            );
        }
        env.insert("ANTHROPIC_BASE_URL".into(), endpoint);
        for key in [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "CLAUDE_CODE_SUBAGENT_MODEL",
        ] {
            env.insert(key.into(), chosen_model.into());
        }
        Ok(Some(Override {
            env,
            model: chosen_model.into(),
            clear_helper: !matching || !session_key.trim().is_empty(),
        }))
    }
}

fn deepseek_model(model: &str) -> Option<String> {
    let model = model.trim().strip_suffix("[1m]").unwrap_or(model.trim());
    match model {
        "deepseek-flash" | "deepseek-v4-pro" => Some(model.into()),
        "deepseek-v4-flash" => Some("deepseek-flash".into()),
        _ => None,
    }
}

pub fn deepseek_endpoint(base_url: &str) -> String {
    let base = base_url.trim_end_matches('/');
    if base.ends_with("/anthropic") {
        base.into()
    } else {
        format!("{base}/anthropic")
    }
}

impl Override {
    pub fn set_effort(&mut self, effort: &str) {
        self.env
            .insert("CLAUDE_CODE_EFFORT_LEVEL".into(), effort.into());
    }

    pub fn model(&self) -> &str {
        &self.model
    }
    pub fn endpoint(&self) -> &str {
        self.env
            .get("ANTHROPIC_BASE_URL")
            .map_or("", String::as_str)
    }
    pub fn apply(&self, command: &mut tokio::process::Command) -> Result<tempfile::NamedTempFile> {
        // A private temporary settings file keeps keys out of argv and overrides settings.env too.
        let mut file = tempfile::Builder::new()
            .prefix("conductor-claude-")
            .suffix(".json")
            .tempfile()?;
        let mut value = json!({ "env": self.env, "model": self.model });
        if self.clear_helper {
            value["apiKeyHelper"] = "".into();
        }
        file.write_all(&serde_json::to_vec(&value)?)?;
        file.flush()?;
        command.envs(&self.env).args([
            "--settings",
            file.path()
                .to_str()
                .context("Claude override path is not UTF-8")?,
        ]);
        Ok(file)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(dir: &Path, name: &str, value: Value) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        path
    }

    fn deepseek() -> Inspection {
        inspect_sources(
            "/project",
            "",
            Path::new("/claude"),
            BTreeMap::from([
                (
                    "ANTHROPIC_BASE_URL".into(),
                    "https://api.deepseek.com/anthropic".into(),
                ),
                (
                    "ANTHROPIC_AUTH_TOKEN".into(),
                    "fixture-secret-deepseek".into(),
                ),
                ("ANTHROPIC_MODEL".into(), "deepseek-flash".into()),
            ]),
            vec![],
        )
    }

    #[test]
    fn local_settings_override_user_and_inherited_environment_without_serializing_secrets() {
        let dir = tempfile::tempdir().unwrap();
        let user = settings(
            dir.path(),
            "user.json",
            json!({"env": {"ANTHROPIC_BASE_URL": "https://api.anthropic.com", "ANTHROPIC_AUTH_TOKEN": "fixture-user-secret"}}),
        );
        let local = settings(
            dir.path(),
            "local.json",
            json!({"model":"custom-model", "env": {"ANTHROPIC_BASE_URL": "https://user:password@gateway.example/anthropic?token=fixture-url-secret", "ANTHROPIC_AUTH_TOKEN":"fixture-local-secret"}}),
        );
        let detected = inspect_sources(
            "/project",
            "",
            dir.path(),
            deepseek().env,
            vec![("User".into(), user, false), ("Local".into(), local, false)],
        );
        assert_eq!(detected.snapshot.backend, "Custom endpoint");
        assert_eq!(detected.snapshot.source, "Local");
        // ANTHROPIC_MODEL remains a per-key override of the model setting.
        assert_eq!(detected.snapshot.model, "deepseek-flash");
        assert_eq!(
            detected.snapshot.endpoint,
            "https://gateway.example/anthropic"
        );
        assert!(detected.snapshot.credential_configured);
        let wire = serde_json::to_string(&detected.snapshot).unwrap();
        for secret in [
            "fixture-user-secret",
            "fixture-local-secret",
            "fixture-url-secret",
            "password",
        ] {
            assert!(!wire.contains(secret));
        }
    }

    #[test]
    fn endpoint_identity_determines_provider_instead_of_model_substrings() {
        let mut inspection = deepseek();
        inspection.env.remove("ANTHROPIC_BASE_URL");
        assert_eq!(backend(&inspection.env), "Claude (Anthropic)");
        inspection.env.insert(
            "ANTHROPIC_BASE_URL".into(),
            "https://api.deepseek.com.evil.example/anthropic".into(),
        );
        assert_eq!(backend(&inspection.env), "Custom endpoint");
    }

    #[test]
    fn switching_to_anthropic_clears_foreign_auth_and_preserves_the_original_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = settings(
            dir.path(),
            "settings.json",
            json!({"permissions":{"deny":["Read(.env)"]},"env":{"ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic","ANTHROPIC_AUTH_TOKEN":"fixture-file-secret"}}),
        );
        let before = fs::read(&path).unwrap();
        let inspected = inspect_sources(
            "/project",
            "",
            dir.path(),
            BTreeMap::new(),
            vec![("User".into(), path.clone(), false)],
        );
        let route = inspected
            .override_for(ClaudeBackend::Anthropic, "", "", "")
            .unwrap()
            .unwrap();
        let mut command = tokio::process::Command::new("claude");
        let file = route.apply(&mut command).unwrap();
        let temporary_path = file.path().to_owned();
        let value: Value = serde_json::from_slice(&fs::read(file.path()).unwrap()).unwrap();
        assert_eq!(
            value["env"]["ANTHROPIC_BASE_URL"],
            "https://api.anthropic.com"
        );
        assert_eq!(value["model"], "sonnet");
        assert_eq!(value["env"]["ANTHROPIC_AUTH_TOKEN"], "");
        assert_eq!(value["apiKeyHelper"], "");
        assert!(value.get("permissions").is_none());
        assert_eq!(fs::read(&path).unwrap(), before);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(file.path()).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        drop(file);
        assert!(!temporary_path.exists());
    }

    #[test]
    fn auto_repairs_mixed_claude_and_deepseek_models_only_in_the_child() {
        let dir = tempfile::tempdir().unwrap();
        let path = settings(
            dir.path(),
            "settings.json",
            json!({
                "model":"sonnet-4-5-20250929[1m]",
                "permissions":{"deny":["Read(.env)"]},
                "env": {
                    "ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic",
                    "ANTHROPIC_AUTH_TOKEN":"fixture-secret-deepseek",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL":"deepseek-v4-pro[1m]",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL":"deepseek-v4-pro[1m]",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL":"deepseek-v4-flash"
                }
            }),
        );
        let before = fs::read(&path).unwrap();
        let inspection = inspect_sources(
            "/project",
            "",
            dir.path(),
            BTreeMap::new(),
            vec![("User".into(), path.clone(), false)],
        );
        assert_eq!(inspection.snapshot.model, "sonnet-4-5-20250929[1m]");
        assert_eq!(inspection.snapshot.conductor_model, "deepseek-v4-pro");
        let route = inspection
            .override_for(ClaudeBackend::Inherit, "", "", "")
            .unwrap()
            .unwrap();
        let mut command = tokio::process::Command::new("claude");
        let file = route.apply(&mut command).unwrap();
        let value: Value = serde_json::from_slice(&fs::read(file.path()).unwrap()).unwrap();
        assert_eq!(value["model"], "deepseek-v4-pro");
        for key in [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "CLAUDE_CODE_SUBAGENT_MODEL",
        ] {
            assert_eq!(value["env"][key], "deepseek-v4-pro");
        }
        assert!(value.get("permissions").is_none());
        assert_eq!(fs::read(path).unwrap(), before);
        assert!(
            inspection
                .override_for(ClaudeBackend::Inherit, "", "sonnet-4-5-20250929", "")
                .is_err()
        );
        assert_eq!(
            inspection
                .override_for(ClaudeBackend::Inherit, "", "deepseek-v4-flash[1m]", "")
                .unwrap()
                .unwrap()
                .model(),
            "deepseek-flash"
        );
    }

    #[test]
    fn only_matching_endpoints_reuse_credentials_and_explicit_keys_do_not_enter_argv() {
        let detected = deepseek();
        let route = detected
            .override_for(ClaudeBackend::DeepSeek, "https://api.deepseek.com", "", "")
            .unwrap()
            .unwrap();
        assert_eq!(route.env["ANTHROPIC_AUTH_TOKEN"], "fixture-secret-deepseek");
        assert!(
            detected
                .override_for(
                    ClaudeBackend::Custom,
                    "https://other.example/anthropic",
                    "model",
                    ""
                )
                .is_err()
        );
        let custom = detected
            .override_for(
                ClaudeBackend::Custom,
                "https://other.example/anthropic",
                "model",
                "fixture-custom-key",
            )
            .unwrap()
            .unwrap();
        assert_eq!(custom.env["ANTHROPIC_AUTH_TOKEN"], "fixture-custom-key");
        let mut command = tokio::process::Command::new("claude");
        let _file = custom.apply(&mut command).unwrap();
        assert!(
            !command
                .as_std()
                .get_args()
                .any(|arg| arg.to_string_lossy().contains("fixture-custom-key"))
        );
        assert!(
            detected
                .override_for(
                    ClaudeBackend::Custom,
                    "http://remote.example",
                    "model",
                    "key"
                )
                .is_err()
        );
    }

    #[test]
    fn malformed_and_managed_provider_settings_are_reported_without_overriding_them() {
        let dir = tempfile::tempdir().unwrap();
        let malformed = dir.path().join("malformed.json");
        fs::write(&malformed, "{ broken").unwrap();
        let bad = inspect_sources(
            "/project",
            "",
            dir.path(),
            BTreeMap::new(),
            vec![("User".into(), malformed, false)],
        );
        assert!(bad.snapshot.sources.last().unwrap().error.is_some());
        assert!(
            bad.override_for(ClaudeBackend::Anthropic, "", "", "")
                .is_err()
        );
        let managed = settings(
            dir.path(),
            "managed.json",
            json!({"env":{"ANTHROPIC_BASE_URL":"https://gateway.example"}}),
        );
        let policy = inspect_sources(
            "/project",
            "",
            dir.path(),
            BTreeMap::new(),
            vec![("Managed".into(), managed, true)],
        );
        assert!(policy.snapshot.managed_routing);
        assert!(
            policy
                .override_for(ClaudeBackend::Anthropic, "", "", "")
                .is_err()
        );
        assert!(
            policy
                .override_for(ClaudeBackend::Inherit, "", "", "")
                .unwrap()
                .is_none()
        );
        let managed_model = settings(
            dir.path(),
            "managed-model.json",
            json!({"model":"fixed-model"}),
        );
        let fixed = inspect_sources(
            "/project",
            "",
            dir.path(),
            BTreeMap::new(),
            vec![("Managed".into(), managed_model, true)],
        );
        assert!(fixed.snapshot.managed_routing);
        let directory = inspect_sources(
            "/project",
            "",
            dir.path(),
            BTreeMap::new(),
            vec![("User".into(), dir.path().to_owned(), false)],
        );
        assert!(
            directory
                .snapshot
                .sources
                .last()
                .unwrap()
                .error
                .as_deref()
                .unwrap()
                .contains("regular file")
        );
    }
}
