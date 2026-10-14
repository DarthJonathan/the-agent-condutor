//! Snippets-only launches own disposable state and sandbox the entire CLI tree.
#[cfg(target_os = "macos")]
use crate::model::Provider;
#[cfg(target_os = "macos")]
use anyhow::{Context, Result};
#[cfg(target_os = "macos")]
use std::path::{Path, PathBuf};

/// Read only the non-secret default choices that remain meaningful after
/// `--ignore-user-config`.  Provider selection is intentionally never copied:
/// doing so could route the isolated invocation to an arbitrary endpoint.
#[cfg(target_os = "macos")]
pub fn codex_snippet_overrides() -> Result<Vec<String>> {
    let home = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|p| p.join(".codex")));
    let Some(home) = home else { return Ok(vec![]); };
    codex_config_overrides(&home.join("config.toml"))
}

#[cfg(target_os = "macos")]
fn codex_config_overrides(path: &Path) -> Result<Vec<String>> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(error) => return Err(error).with_context(|| format!("Read {}", path.display())),
    };
    if bytes.len() > 2 * 1024 * 1024 {
        anyhow::bail!("Codex configuration exceeds 2 MiB; snippets-only access will not load it.");
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| anyhow::anyhow!("Codex configuration is not valid TOML; snippets-only access will not load it."))?;
    let document = text.parse::<toml_edit::DocumentMut>().map_err(|_| {
        anyhow::anyhow!("Codex configuration is not valid TOML; snippets-only access will not load it.")
    })?;
    let root = document.as_table();
    let profile_item = root.get("profile");
    if profile_item.is_some() && profile_item.and_then(toml_edit::Item::as_str).is_none() {
        anyhow::bail!("Codex configuration has an invalid default profile; snippets-only access will not load it.");
    }
    let selected = if let Some(profile) = profile_item.and_then(toml_edit::Item::as_str) {
        root.get("profiles").and_then(|profiles| profiles.get(profile)).and_then(toml_edit::Item::as_table).ok_or_else(|| {
            anyhow::anyhow!("Codex configuration selects an unavailable default profile; snippets-only access will not load it.")
        })?
    } else {
        root
    };
    if root.get("model_providers").and_then(|providers| providers.get("openai")).is_some()
        || root.get("openai_base_url").is_some()
        || root.get("base_url").is_some()
        || selected.get("base_url").is_some()
    {
        anyhow::bail!("Snippets-only Codex access does not use overridden OpenAI routing. Select the standard OpenAI connection or give this coworker workspace access.");
    }
    let provider = selected.get("model_provider").and_then(toml_edit::Item::as_str)
        .or_else(|| root.get("model_provider").and_then(toml_edit::Item::as_str));
    if let Some(provider) = provider
        && provider != "openai"
    {
        anyhow::bail!(
            "Snippets-only Codex access does not support the configured model provider {provider:?}. Select an OpenAI connection or give this coworker workspace access."
        );
    }
    let mut overrides = Vec::new();
    for key in ["model", "model_reasoning_effort"] {
        let value = selected.get(key).and_then(toml_edit::Item::as_str)
            .or_else(|| root.get(key).and_then(toml_edit::Item::as_str));
        if let Some(value) = value {
            // TOML rendering retains safe quoting without ever copying other config,
            // including provider URLs, environment variables, or API-key helpers.
            overrides.push(format!("{key}={}", serde_json::to_string(value)?));
        }
    }
    Ok(overrides)
}

#[cfg(target_os = "macos")]
pub struct SnippetProcess {
    directory: tempfile::TempDir,
    profile: PathBuf,
    provider: Provider,
    claude_config: PathBuf,
}

#[cfg(target_os = "macos")]
impl SnippetProcess {
    pub fn new(
        executable: &Path,
        provider: Provider,
        protected: &[PathBuf],
        claude_config: &Path,
        private_settings: Option<&Path>,
        codex_api_key_available: bool,
    ) -> Result<Self> {
        let directory = tempfile::Builder::new()
            .prefix("conductor-snippets-")
            .tempdir()?;
        let root = directory.path().canonicalize()?;
        for child in ["workspace", "state", "home"] {
            std::fs::create_dir(root.join(child))?;
        }
        if provider == Provider::Codex { require_codex_api_key(codex_api_key_available)?; }
        // Codex account auth can refresh auth.json. Never copy that state into a
        // disposable run: it would discard the refresh or race the desktop CLI.
        // API-key auth is process-scoped and needs no persisted credential file.
        let mut readable = vec![
            root.clone(),
            executable
                .canonicalize()
                .context("Resolve CLI executable")?,
        ];
        if provider != Provider::Codex {
            // Keep the original auth namespace for Keychain OAuth, with only
            // credential/account files readable. Safe mode disables custom context.
            readable.push(claude_config.join(".credentials.json"));
            readable.push(claude_config.join(".claude.json"));
            if let Some(home) = dirs::home_dir() {
                readable.push(home.join(".claude.json"));
            }
        }
        for path in [
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/Library",
            "/dev",
            "/private/etc",
            "/private/var/db",
            "/private/var/run",
            "/opt/homebrew",
            "/usr/local",
        ] {
            readable.push(PathBuf::from(path));
        }
        if let Some(path) = private_settings {
            readable.push(path.canonicalize()?);
        }
        if let Some(home) = dirs::home_dir() {
            let nvm = home.join(".nvm/versions/node");
            let actual = executable.canonicalize()?;
            if let Ok(tail) = actual.strip_prefix(&nvm)
                && let Some(version) = tail.components().next()
            {
                readable.push(nvm.join(version));
            }
        }
        let quoted = |p: &Path| serde_json::to_string(&p.to_string_lossy()).unwrap();
        let reads = readable
            .iter()
            .map(|p| format!("(subpath {})", quoted(p)))
            .collect::<Vec<_>>()
            .join(" ");
        let private_roots = [
            "/Users",
            "/Volumes",
            "/private/tmp",
            "/tmp",
            "/private/var/folders",
        ]
        .map(|p| format!("(subpath {})", quoted(Path::new(p))))
        .join(" ");
        let denies = protected
            .iter()
            .map(|p| p.canonicalize().context("Resolve protected workspace"))
            .collect::<Result<Vec<_>>>()?
            .iter()
            .map(|p| format!("(deny file-read* file-write* (subpath {}))\n", quoted(p)))
            .collect::<String>();
        // Don't deny anonymous dyld/kernel runtime reads: macOS aborts before main.
        // Deny personal volumes and temp data, with explicit repository denials
        // taking precedence even when a project lives under a runtime directory.
        let profile_text = format!(
            "(version 1)\n(allow default)\n(deny network-outbound (remote unix-socket (subpath \"/\")))\n(deny file-read-data (require-all (require-any {private_roots}) (require-not (require-any {reads}))))\n(deny file-write* (require-not (subpath {})))\n{denies}",
            quoted(&root)
        );
        let profile = root.join("sandbox.sb");
        std::fs::write(&profile, profile_text)?;
        Ok(Self {
            directory,
            profile,
            provider,
            claude_config: claude_config.into(),
        })
    }

    pub fn command(&self, executable: &Path) -> tokio::process::Command {
        let root = self.directory.path();
        let mut command = tokio::process::Command::new("/usr/bin/sandbox-exec");
        command.arg("-f").arg(&self.profile).arg(executable);
        command
            .current_dir(root.join("workspace"))
            .env("HOME", root.join("home"))
            .env("TMPDIR", root.join("workspace"))
            .env_remove("PWD")
            .env_remove("OLDPWD")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE");
        if self.provider == Provider::Codex {
            command.env("CODEX_HOME", root.join("state"));
        } else {
            command.env("CLAUDE_CONFIG_DIR", &self.claude_config);
            if let Some(home) = dirs::home_dir() {
                command.env("HOME", home);
            }
        }
        command
    }
}

#[cfg(target_os = "macos")]
fn require_codex_api_key(available: bool) -> Result<()> {
    if available { return Ok(()); }
    anyhow::bail!("Snippets-only Codex access requires CODEX_API_KEY. ChatGPT-managed Codex credentials refresh auth.json and cannot safely run from disposable state.")
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn preserves_only_standard_codex_defaults_and_rejects_custom_provider() {
        let fixture = tempfile::tempdir().unwrap();
        let config = fixture.path().join("config.toml");
        std::fs::write(
            &config,
            "model = \"gpt-6.1-codex\"\nmodel_reasoning_effort = \"high\"\nmodel_provider = \"openai\"\n[model_providers.private]\nbase_url = \"https://example.invalid\"\n",
        )
        .unwrap();
        assert_eq!(
            codex_config_overrides(&config).unwrap(),
            vec!["model=\"gpt-6.1-codex\"", "model_reasoning_effort=\"high\""]
        );
        std::fs::write(&config, "model_provider = \"private\"\n").unwrap();
        assert!(codex_config_overrides(&config).unwrap_err().to_string().contains("does not support"));
        std::fs::write(&config, "profile = \"private\"\n[profiles.private]\nmodel_provider = \"private\"\n").unwrap();
        assert!(codex_config_overrides(&config).is_err());
        std::fs::write(&config, "model_provider = \"private\"\nprofile = \"defaults\"\n[profiles.defaults]\nmodel = \"gpt-6.1-codex\"\n").unwrap();
        assert!(codex_config_overrides(&config).is_err());
        std::fs::write(&config, "[model_providers.openai]\nbase_url = \"https://example.invalid\"\n").unwrap();
        assert!(codex_config_overrides(&config).unwrap_err().to_string().contains("overridden OpenAI routing"));
        std::fs::write(&config, "\"model_provider\" = \"private\"\n").unwrap();
        assert!(codex_config_overrides(&config).is_err());
        std::fs::write(&config, "model_providers = { \"openai\" = { base_url = \"https://example.invalid\" } }\n").unwrap();
        assert!(codex_config_overrides(&config).is_err());
        std::fs::write(&config, "model = \"safe\"\ncredential = \"SENTINEL_SECRET\n").unwrap();
        let error = codex_config_overrides(&config).unwrap_err().to_string();
        assert!(!error.contains("SENTINEL_SECRET"));
        assert!(error.contains("not valid TOML"));
    }

    #[test]
    fn codex_snippets_require_process_scoped_api_auth() {
        let error = require_codex_api_key(false).unwrap_err().to_string();
        assert!(error.contains("CODEX_API_KEY"));
        assert!(!error.contains("fixture-secret"));
        require_codex_api_key(true).unwrap();
    }

    #[test]
    fn codex_disposable_state_never_copies_refreshable_auth() {
        let fixture = tempfile::tempdir().unwrap();
        let executable = fixture.path().join("headless");
        std::fs::write(&executable, "#!/bin/sh\nexit 0\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let sandbox = SnippetProcess::new(&executable, Provider::Codex, &[], fixture.path(), None, true).unwrap();
        assert!(!sandbox.directory.path().join("state/auth.json").exists());
    }

    #[tokio::test]
    async fn sandbox_blocks_absolute_symlink_and_child_reads_and_cleans_state() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let fixture = tempfile::tempdir().unwrap();
        let repo = fixture.path().join("repo");
        std::fs::create_dir(&repo).unwrap();
        let secret = repo.join("code.txt");
        std::fs::write(&secret, "PRIVATE_REPOSITORY_CONTENT").unwrap();
        let other = fixture.path().join("other-code.txt");
        std::fs::write(&other, "OTHER_PRIVATE_CONTENT").unwrap();
        let executable = fixture.path().join("headless");
        std::fs::write(&executable, "#!/bin/sh\ncat \"$1\" && exit 11\ncat link && exit 12\n/bin/sh -c 'cat \"$1\"' sh \"$1\" && exit 13\ncat \"$2\" && exit 14\nprintf supplied-snippet > reply.txt\ncat reply.txt\n").unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let sandbox = SnippetProcess::new(
            &executable,
            Provider::Claude,
            std::slice::from_ref(&repo),
            &fixture.path().join("auth"),
            None,
            true,
        )
        .unwrap();
        let root = sandbox.directory.path().to_path_buf();
        symlink(&secret, root.join("workspace/link")).unwrap();
        let output = sandbox
            .command(&executable)
            .arg(&secret)
            .arg(&other)
            .output()
            .await
            .unwrap();
        assert!(
            output.status.success(),
            "status={:?}, stdout={}, stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(String::from_utf8_lossy(&output.stdout), "supplied-snippet");
        assert_eq!(
            std::fs::read_to_string(&secret).unwrap(),
            "PRIVATE_REPOSITORY_CONTENT"
        );
        drop(sandbox);
        assert!(!root.exists());
    }

    #[tokio::test]
    async fn sandbox_blocks_unix_socket_connections() {
        use std::os::unix::fs::PermissionsExt;
        let fixture = tempfile::tempdir().unwrap();
        let executable = fixture.path().join("headless");
        std::fs::write(
            &executable,
            "#!/bin/sh\nif /usr/bin/nc -U \"$1\" </dev/null; then exit 31; fi\nprintf safe\n",
        )
        .unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = fixture.path().join("engine.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let sandbox = SnippetProcess::new(
            &executable,
            Provider::Claude,
            &[],
            &fixture.path().join("auth"),
            None,
            true,
        )
        .unwrap();
        let output = sandbox.command(&executable).arg(&socket).output().await.unwrap();
        assert!(output.status.success(), "socket probe was not blocked: {}", String::from_utf8_lossy(&output.stderr));
        assert!(tokio::time::timeout(std::time::Duration::from_millis(200), listener.accept()).await.is_err());
    }
}
