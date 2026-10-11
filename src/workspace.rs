//! Task-owned worktrees, read-only diff inspection, and explicit local checks.
use crate::model::{Status, clip};
use anyhow::{Context, Result, bail};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command as AsyncCommand};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkspaceInfo {
    pub project: String,
    pub path: String,
    pub branch: String,
    pub isolated: bool,
    pub base_commit: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum Isolation {
    #[default]
    Shared,
    Worktree,
    ShareTask {
        run_id: Uuid,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChangedFile {
    pub path: String,
    pub status: String,
    pub diff: String,
    pub fingerprint: String,
    pub owner_id: Option<Uuid>,
    pub truncated: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CheckResult {
    pub id: Uuid,
    pub at: DateTime<Utc>,
    pub owner_id: Option<Uuid>,
    pub argv: Vec<String>,
    pub status: Status,
    pub exit_code: Option<i32>,
    pub output: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ChangeSet {
    pub branch: String,
    #[serde(default)]
    pub base_commit: String,
    pub files: Vec<ChangedFile>,
    pub checks: Vec<CheckResult>,
    pub error: Option<String>,
    pub truncated: bool,
}

fn git(path: &Path, args: &[&str]) -> Result<String> {
    let mut child = Command::new("git")
        .args(args)
        .current_dir(path)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("Git is unavailable")?;
    let mut bytes = vec![];
    let mut chunk = [0; 8192];
    let mut pipe = child.stdout.take().unwrap();
    loop {
        let n = pipe.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        let keep = n.min((1024 * 1024usize).saturating_sub(bytes.len()));
        bytes.extend_from_slice(&chunk[..keep]);
    }
    if !child.wait()?.success() {
        bail!("Git could not inspect this workspace.");
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

pub fn shared(path: &str) -> WorkspaceInfo {
    let root = Path::new(path);
    WorkspaceInfo {
        project: path.into(),
        path: path.into(),
        isolated: false,
        branch: git(root, &["branch", "--show-current"])
            .unwrap_or_default()
            .trim()
            .into(),
        base_commit: git(root, &["rev-parse", "HEAD"])
            .unwrap_or_default()
            .trim()
            .into(),
    }
}

pub fn create_worktree(project: &str, state_root: &Path, run_id: Uuid) -> Result<WorkspaceInfo> {
    let source = Path::new(project)
        .canonicalize()
        .context("Choose an existing project folder.")?;
    let prefix = git(&source, &["rev-parse", "--show-prefix"])?
        .trim()
        .to_owned();
    let base_commit = git(&source, &["rev-parse", "HEAD"])
        .context("Isolation needs a Git repository with at least one commit.")?
        .trim()
        .to_owned();
    let branch = format!("codex/team-{}", &run_id.simple().to_string()[..12]);
    let target = state_root.join("worktrees").join(run_id.to_string());
    std::fs::create_dir_all(target.parent().unwrap())?;
    if target.exists() {
        bail!("This task's worktree already exists; it has been preserved.");
    }
    let result = Command::new("git")
        .args(["worktree", "add", "-b", &branch, "--"])
        .arg(&target)
        .arg(&base_commit)
        .current_dir(&source)
        .output()?;
    if !result.status.success() {
        bail!(
            "Could not create the isolated worktree: {}",
            clip(&String::from_utf8_lossy(&result.stderr), 2048)
        );
    }
    let task_folder = target.join(prefix);
    if !task_folder.is_dir() {
        bail!(
            "The selected project folder is absent from HEAD. The new worktree has been preserved at {}.",
            target.display()
        );
    }
    Ok(WorkspaceInfo {
        project: source.display().to_string(),
        path: task_folder.display().to_string(),
        branch,
        isolated: true,
        base_commit,
    })
}

pub fn capture(path: &str, previous: Option<&ChangeSet>, author: Option<Uuid>) -> ChangeSet {
    let mut changes = ChangeSet {
        checks: previous.map_or_else(Vec::new, |p| p.checks.clone()),
        base_commit: previous.map_or_else(String::new, |p| p.base_commit.clone()),
        ..Default::default()
    };
    let root = Path::new(path);
    let result = (|| -> Result<()> {
        changes.branch = git(root, &["branch", "--show-current"])?.trim().into();
        let prefix = git(root, &["rev-parse", "--show-prefix"])?;
        let prefix = prefix.trim();
        let mut status = git(
            root,
            &[
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
                "--",
                ".",
            ],
        )?;
        let base = if [40, 64].contains(&changes.base_commit.len())
            && changes.base_commit.bytes().all(|b| b.is_ascii_hexdigit())
        {
            changes.base_commit.as_str()
        } else {
            "HEAD"
        };
        // Include committed task edits as well as uncommitted files in isolated branches.
        if base != "HEAD" {
            let committed = git(
                root,
                &[
                    "diff",
                    "--name-status",
                    "-z",
                    "--no-renames",
                    "--no-ext-diff",
                    "--no-textconv",
                    base,
                    "--",
                    ".",
                ],
            )?;
            let mut entries = committed.split('\0');
            while let (Some(code), Some(file)) = (entries.next(), entries.next()) {
                if !code.is_empty() {
                    status.push_str(&format!("{code}  {file}\0"));
                }
            }
        }
        let old: HashMap<_, _> = previous
            .into_iter()
            .flat_map(|p| &p.files)
            .map(|f| (f.path.as_str(), f))
            .collect();
        let mut entries = status.split('\0').filter(|s| !s.is_empty());
        let mut seen = std::collections::HashSet::new();
        while let Some(entry) = entries.next() {
            if entry.len() < 4 {
                continue;
            }
            let code = &entry[..2];
            let file = &entry[3..];
            if code.contains('R') || code.contains('C') {
                entries.next();
            }
            let file = file.strip_prefix(prefix).unwrap_or(file);
            if !seen.insert(file.to_owned()) {
                continue;
            }
            let relative = Path::new(file);
            if relative.is_absolute()
                || relative
                    .components()
                    .any(|c| matches!(c, std::path::Component::ParentDir))
            {
                continue;
            }
            if changes.files.len() >= 80 {
                changes.truncated = true;
                break;
            }
            let full = root.join(relative);
            let metadata = std::fs::symlink_metadata(&full).ok();
            let raw = if code == "??" {
                if metadata
                    .as_ref()
                    .is_some_and(|m| m.is_file() && m.len() <= 256 * 1024)
                {
                    let bytes = std::fs::read(&full).unwrap_or_default();
                    if bytes.contains(&0) {
                        "Binary file added".into()
                    } else {
                        format!(
                            "--- /dev/null\n+++ b/{file}\n{}",
                            String::from_utf8_lossy(&bytes)
                                .lines()
                                .map(|l| format!("+{l}\n"))
                                .collect::<String>()
                        )
                    }
                } else {
                    "New file (binary, symlink, directory, or too large to preview)".into()
                }
            } else {
                git(
                    root,
                    &[
                        "diff",
                        "--no-ext-diff",
                        "--no-textconv",
                        base,
                        "--",
                        &format!(":(literal){file}"),
                    ],
                )
                .unwrap_or_else(|_| "Diff is unavailable for this file.".into())
            };
            // Stable content hash for attribution; the stored preview can be shorter than the diff.
            let fingerprint = format!(
                "{:016x}",
                raw.bytes()
                    .fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64)
                        .wrapping_mul(0x100000001b3))
            );
            let owner_id = old
                .get(file)
                .filter(|f| f.fingerprint == fingerprint)
                .and_then(|f| f.owner_id)
                .or_else(|| {
                    if old.get(file).is_none_or(|f| f.fingerprint != fingerprint) {
                        author
                    } else {
                        None
                    }
                });
            changes.files.push(ChangedFile {
                path: file.into(),
                status: code.trim().into(),
                diff: clip(&raw, 16 * 1024),
                fingerprint,
                owner_id,
                truncated: raw.len() > 16 * 1024,
            });
        }
        Ok(())
    })();
    if let Err(error) = result {
        changes.error = Some(format!("{error:#}"));
    }
    changes
}

pub fn validate_check(argv: &[String]) -> Result<()> {
    if argv.is_empty()
        || argv.len() > 64
        || argv[0].is_empty()
        || argv.iter().map(String::len).sum::<usize>() > 32 * 1024
        || argv.iter().any(|s| s.contains('\0'))
    {
        bail!("Choose a command with 1–64 arguments below 32 KiB.");
    }
    Ok(())
}

async fn read_output(mut pipe: impl tokio::io::AsyncRead + Unpin) -> String {
    let mut bytes = vec![];
    let mut truncated = false;
    let mut chunk = [0; 8192];
    while let Ok(n) = pipe.read(&mut chunk).await {
        if n == 0 {
            break;
        }
        let keep = n.min((32 * 1024usize).saturating_sub(bytes.len()));
        truncated |= keep < n;
        bytes.extend_from_slice(&chunk[..keep]);
    }
    let mut text = String::from_utf8_lossy(&bytes).into_owned();
    if truncated {
        text.push_str("\n[Command output truncated after 32 KiB]\n");
    }
    text
}

struct CheckChild {
    child: tokio::process::Child,
    pid: Option<u32>,
}
impl Drop for CheckChild {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(id) = self.pid {
            unsafe {
                libc::kill(-(id as i32), libc::SIGKILL);
            }
        }
        let _ = self.child.start_kill();
    }
}

pub async fn run_check(
    path: &str,
    argv: Vec<String>,
    owner_id: Option<Uuid>,
    cancel: &CancellationToken,
) -> CheckResult {
    let mut result = CheckResult {
        id: Uuid::new_v4(),
        at: Utc::now(),
        owner_id,
        argv: argv.clone(),
        status: Status::Failed,
        exit_code: None,
        output: String::new(),
    };
    if let Err(error) = validate_check(&argv) {
        result.output = error.to_string();
        return result;
    }
    let mut command = AsyncCommand::new(&argv[0]);
    command
        .args(&argv[1..])
        .current_dir(PathBuf::from(path))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    command.env("PATH", crate::runner::executable_search_path());
    #[cfg(unix)]
    command.process_group(0);
    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            result.output = format!("Could not start the command: {error}");
            return result;
        }
    };
    let pid = child.id();
    let mut child = CheckChild { child, pid };
    let out = tokio::spawn(read_output(child.child.stdout.take().unwrap()));
    let err = tokio::spawn(read_output(child.child.stderr.take().unwrap()));
    tokio::select! {
        exit = child.child.wait() => if let Ok(exit) = exit { result.exit_code = exit.code(); result.status = if exit.success() { Status::Completed } else { Status::Failed }; },
        _ = cancel.cancelled() => { result.status = Status::Cancelled; result.output = "Command cancelled.\n".into(); },
        _ = tokio::time::sleep(Duration::from_secs(300)) => { result.output = "Command timed out after five minutes.\n".into(); }
    }
    // Kill remaining descendants even if the direct process has already exited.
    drop(child);
    for handle in [out, err] {
        match tokio::time::timeout(Duration::from_secs(2), handle).await {
            Ok(Ok(text)) => result.output.push_str(&text),
            _ => result
                .output
                .push_str("Output stream closed before draining.\n"),
        }
    }
    result.output = clip(&result.output, 256 * 1024);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn repo() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for args in [
            vec!["init"],
            vec!["config", "user.email", "test@example.invalid"],
            vec!["config", "user.name", "Fixture"],
        ] {
            assert!(
                Command::new("git")
                    .args(args)
                    .current_dir(dir.path())
                    .output()
                    .unwrap()
                    .status
                    .success()
            );
        }
        std::fs::write(dir.path().join("a.txt"), "before\n").unwrap();
        for args in [vec!["add", "."], vec!["commit", "-m", "base"]] {
            assert!(
                Command::new("git")
                    .args(args)
                    .current_dir(dir.path())
                    .output()
                    .unwrap()
                    .status
                    .success()
            );
        }
        dir
    }
    #[test]
    fn worktree_isolation_and_attribution_preserve_the_source() {
        let repo = repo();
        let state = tempfile::tempdir().unwrap();
        std::fs::write(repo.path().join("a.txt"), "source dirty\n").unwrap();
        let info =
            create_worktree(repo.path().to_str().unwrap(), state.path(), Uuid::new_v4()).unwrap();
        assert_eq!(
            std::fs::read_to_string(Path::new(&info.path).join("a.txt")).unwrap(),
            "before\n"
        );
        let baseline = capture(
            &info.path,
            Some(&ChangeSet {
                base_commit: info.base_commit.clone(),
                ..Default::default()
            }),
            None,
        );
        assert!(baseline.files.is_empty());
        let author = Uuid::new_v4();
        std::fs::write(Path::new(&info.path).join("a.txt"), "after\n").unwrap();
        let changes = capture(&info.path, Some(&baseline), Some(author));
        assert_eq!(changes.files[0].owner_id, Some(author));
        assert!(changes.files[0].diff.contains("+after"));
        let refreshed = capture(&info.path, Some(&changes), None);
        assert_eq!(refreshed.files[0].owner_id, Some(author));
        assert!(
            Command::new("git")
                .args(["add", "a.txt"])
                .current_dir(&info.path)
                .status()
                .unwrap()
                .success()
        );
        assert!(
            Command::new("git")
                .args(["commit", "-qm", "task changes"])
                .current_dir(&info.path)
                .status()
                .unwrap()
                .success()
        );
        let committed = capture(&info.path, Some(&refreshed), None);
        assert_eq!(committed.files.len(), 1);
        assert!(committed.files[0].diff.contains("+after"));
        assert_eq!(committed.files[0].owner_id, Some(author));
        assert_eq!(
            std::fs::read_to_string(repo.path().join("a.txt")).unwrap(),
            "source dirty\n"
        );
    }
    #[tokio::test]
    async fn checks_record_real_exit_codes_and_literal_arguments() {
        let dir = tempfile::tempdir().unwrap();
        let cancel = CancellationToken::new();
        let result = run_check(
            dir.path().to_str().unwrap(),
            vec![
                "/usr/bin/printf".into(),
                "%s".into(),
                "$(touch injected)".into(),
            ],
            None,
            &cancel,
        )
        .await;
        assert_eq!(result.status, Status::Completed);
        assert!(result.output.contains("$(touch injected)"));
        assert!(!dir.path().join("injected").exists());
        let failed = run_check(
            dir.path().to_str().unwrap(),
            vec!["/usr/bin/false".into()],
            None,
            &cancel,
        )
        .await;
        assert_eq!(failed.status, Status::Failed);
        assert_eq!(failed.exit_code, Some(1));
    }
}
