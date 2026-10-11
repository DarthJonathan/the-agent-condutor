use crate::model::{Run, Settings};
use anyhow::{Context, Result};
use serde::{Serialize, de::DeserializeOwned};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};
use uuid::Uuid;

pub struct Store {
    pub root: PathBuf,
}

impl Store {
    pub fn new(root: Option<PathBuf>) -> Self {
        Self {
            root: root.unwrap_or_else(|| {
                dirs::data_local_dir()
                    .unwrap_or_else(|| PathBuf::from("."))
                    .join("agent-conductor")
            }),
        }
    }

    pub fn load_settings(&self) -> Result<Settings> {
        let mut settings: Settings = self.read("settings.json")?.unwrap_or_default();
        settings.repair();
        Ok(settings)
    }

    pub fn load_runs(&self) -> Result<Vec<Run>> {
        let mut runs: Vec<Run> = self.read("runs.json")?.unwrap_or_default();
        runs.truncate(100);
        for run in &mut runs {
            if let Some(chat) = &mut run.conversation {
                crate::team::migrate(chat, run.id);
            }
            run.recover();
        }
        Ok(runs)
    }

    pub fn save(&self, settings: &Settings, runs: &[Run]) -> Result<()> {
        self.write("settings.json", settings)?;
        self.write("runs.json", &runs[..runs.len().min(100)])
    }

    pub fn export(&self, run: &Run) -> Result<PathBuf> {
        let path = self.root.join("exports").join(format!("{}.md", run.id));
        fs::create_dir_all(path.parent().unwrap())?;
        private_write(&path, run.markdown().as_bytes())?;
        Ok(path)
    }

    fn read<T: DeserializeOwned>(&self, name: &str) -> Result<Option<T>> {
        let path = self.root.join(name);
        match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .with_context(|| {
                    format!(
                        "Could not read {}. The original file has been preserved.",
                        path.display()
                    )
                })
                .map(Some),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(err).with_context(|| format!("Could not read {}", path.display())),
        }
    }

    fn write<T: Serialize + ?Sized>(&self, name: &str, value: &T) -> Result<()> {
        fs::create_dir_all(&self.root).context("Could not create the dashboard data directory")?;
        let bytes = serde_json::to_vec_pretty(value)?;
        let temp = self.root.join(format!(".{name}.{}.tmp", Uuid::new_v4()));
        let result = (|| {
            private_write(&temp, &bytes)?;
            fs::rename(&temp, self.root.join(name))
                .context("Could not replace saved dashboard state")
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp);
        }
        result
    }
}

fn private_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn history_roundtrips_and_corrupt_files_are_preserved() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(Some(dir.path().into()));
        let settings = Settings::default();
        let run = Run::new(&settings, "roundtrip".into());
        store.save(&settings, &[run]).unwrap();
        assert_eq!(store.load_runs().unwrap()[0].prompt, "roundtrip");
        store.save(&settings, &[]).unwrap();
        assert!(store.load_runs().unwrap().is_empty());
        fs::write(dir.path().join("runs.json"), "broken").unwrap();
        assert!(store.load_runs().is_err());
        assert_eq!(
            fs::read_to_string(dir.path().join("runs.json")).unwrap(),
            "broken"
        );
    }
}
