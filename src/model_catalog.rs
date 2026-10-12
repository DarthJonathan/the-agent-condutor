//! Provider model choices and the Codex CLI's local catalogue; no inference calls or credentials.
use crate::{
    claude_config::Snapshot,
    model::{ClaudeBackend, DeepSeekMode, Effort, Provider, Settings, validate_model_id},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Serialize)]
pub struct ModelOption {
    pub id: String,
    pub label: String,
    pub effort_levels: Option<Vec<Effort>>,
    pub default_effort: Option<Effort>,
}

#[derive(Serialize)]
pub struct ModelCatalog {
    pub provider: Provider,
    source: String,
    options: Vec<ModelOption>,
    effort_levels: Vec<Effort>,
    effort_note: String,
}

fn options(values: &[(&str, &str)]) -> Vec<ModelOption> {
    values
        .iter()
        .map(|(id, label)| ModelOption {
            id: (*id).into(),
            label: (*label).into(),
            effort_levels: None,
            default_effort: None,
        })
        .collect()
}

pub fn catalogs(settings: &Settings, snapshot: &Snapshot) -> Vec<ModelCatalog> {
    let codex_home = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".codex"));
    let deepseek = options(&[
        ("deepseek-flash", "DeepSeek Flash"),
        ("deepseek-v4-pro", "DeepSeek V4 Pro"),
    ]);
    let claude_deepseek = settings.claude_backend == ClaudeBackend::DeepSeek
        || (settings.claude_backend == ClaudeBackend::Inherit && snapshot.backend == "DeepSeek");
    let claude_anthropic = settings.claude_backend == ClaudeBackend::Anthropic
        || (settings.claude_backend == ClaudeBackend::Inherit
            && snapshot.backend == "Claude (Anthropic)");
    Provider::ALL
        .into_iter()
        .map(|provider| {
            let (source, mut choices) = match provider {
                Provider::Claude if claude_deepseek => {
                    ("DeepSeek models through Claude Code", deepseek.clone())
                }
                Provider::Claude if claude_anthropic => (
                    "Claude Code model aliases",
                    options(&[("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")]),
                ),
                Provider::Claude => ("Model IDs from your configured provider", vec![]),
                Provider::Codex => (
                    "Codex CLI's local model catalogue",
                    codex_models(&codex_home.join("models_cache.json")),
                ),
                Provider::DeepSeek => ("DeepSeek API model IDs", deepseek.clone()),
                Provider::Qoder => (
                    "Qoder CLI model tiers",
                    options(&[
                        ("auto", "Auto"),
                        ("ultimate", "Ultimate"),
                        ("performance", "Performance"),
                        ("efficient", "Efficient"),
                    ]),
                ),
                Provider::Kiro => (
                    "Kiro CLI; custom IDs from its model picker",
                    options(&[("auto", "Auto")]),
                ),
                Provider::Antigravity => ("Model IDs from your headless CLI", vec![]),
            };
            let effort_levels = match provider {
                Provider::Claude if claude_deepseek => vec![Effort::Low, Effort::High, Effort::Max],
                Provider::DeepSeek => {
                    let mut levels = vec![Effort::Low, Effort::High, Effort::Max];
                    if settings.deepseek_mode == DeepSeekMode::DirectApi { levels.insert(0, Effort::None); }
                    levels
                }
                Provider::Codex => vec![Effort::Low, Effort::Medium, Effort::High, Effort::Xhigh, Effort::Max],
                Provider::Antigravity => vec![Effort::Low, Effort::Medium, Effort::High],
                _ => vec![Effort::Low, Effort::Medium, Effort::High, Effort::Xhigh, Effort::Max],
            };
            if provider != Provider::Codex {
                for choice in &mut choices {
                    choice.effort_levels = Some(effort_levels.clone());
                }
            }
            let effort_note = match provider {
                Provider::Claude if claude_deepseek => "DeepSeek supports Low, High, and Max through Claude Code.",
                Provider::DeepSeek if settings.deepseek_mode == DeepSeekMode::DirectApi => "Off disables thinking; Low, High, and Max enable it.",
                Provider::DeepSeek => "DeepSeek supports Low, High, and Max through Claude Code.",
                Provider::Codex => "Explicit models use their local Codex capability metadata. Default and custom models offer levels through Max; Codex checks model and account limits. Select a model to see its full range.",
                Provider::Antigravity => "Antigravity headless supports Low, Medium, and High.",
                Provider::Qoder => "Available levels depend on the model; Qoder applies its model limits.",
                Provider::Kiro => "Kiro applies the selected model's supported levels. Requires a CLI with --effort support.",
                _ => "Available levels depend on the model; Claude Code applies model and organization limits.",
            };
            ModelCatalog {
                provider,
                source: source.into(),
                options: choices,
                effort_levels,
                effort_note: effort_note.into(),
            }
        })
        .collect()
}

impl ModelCatalog {
    pub fn levels(&self, model: &str) -> Vec<Effort> {
        if let Some(levels) = self
            .options
            .iter()
            .find(|m| m.id == model)
            .and_then(|m| m.effort_levels.as_ref())
        {
            return levels.clone();
        }
        // Older pinned Claude models do not implement adaptive effort. Unknown custom
        // models keep the CLI's controls, with provider-side capability validation.
        if matches!(self.provider, Provider::Claude | Provider::Kiro) && model.contains("claude-") {
            if ["4-5", "4-1", "3-5", "3-7", "-4-2025"]
                .iter()
                .any(|v| model.contains(v))
            {
                return vec![];
            }
            if model.contains("4-6") {
                return self
                    .effort_levels
                    .iter()
                    .copied()
                    .filter(|e| *e != Effort::Xhigh)
                    .collect();
            }
        }
        self.effort_levels.clone()
    }
}

pub fn validate_effort(
    settings: &Settings,
    snapshot: &Snapshot,
    provider: Provider,
    model: &str,
    effort: Effort,
) -> anyhow::Result<()> {
    if effort == Effort::Default {
        return Ok(());
    }
    let model = if model.is_empty() && provider == Provider::Claude {
        snapshot.conductor_model.as_str()
    } else {
        model
    };
    if !catalogs(settings, snapshot)
        .iter()
        .find(|c| c.provider == provider)
        .is_some_and(|c| c.levels(model).contains(&effort))
    {
        anyhow::bail!(
            "{} does not support {} effort for this model or connection. Choose Default or a supported effort level.",
            provider.name(),
            effort.value()
        );
    }
    Ok(())
}

#[derive(Deserialize)]
struct CodexCache {
    models: Vec<CodexModel>,
}

#[derive(Deserialize)]
struct CodexModel {
    slug: String,
    #[serde(default)]
    display_name: String,
    #[serde(default)]
    visibility: String,
    #[serde(default)]
    priority: u32,
    #[serde(default)]
    supported_reasoning_levels: Option<Vec<CodexEffort>>,
    #[serde(default)]
    default_reasoning_level: Option<String>,
}

#[derive(Deserialize)]
struct CodexEffort {
    effort: String,
}

fn cached_effort(value: &str) -> Option<Effort> {
    serde_json::from_value::<Effort>(serde_json::Value::String(value.into()))
        .ok()
        .filter(|e| *e != Effort::Default)
}

fn codex_models(path: &Path) -> Vec<ModelOption> {
    let load = || -> Option<CodexCache> {
        if fs::metadata(path).ok()?.len() > 2 * 1024 * 1024 {
            return None;
        }
        serde_json::from_slice(&fs::read(path).ok()?).ok()
    };
    let Some(mut cache) = load() else {
        return vec![];
    };
    cache.models.sort_by_key(|m| m.priority);
    let mut seen = HashSet::new();
    cache
        .models
        .into_iter()
        .filter(|m| {
            (m.visibility.is_empty() || m.visibility == "list")
                && !m.slug.is_empty()
                && validate_model_id(&m.slug).is_ok()
                && seen.insert(m.slug.clone())
        })
        .take(64)
        .map(|m| ModelOption {
            label: if m.display_name.is_empty() {
                m.slug.clone()
            } else {
                m.display_name
                    .chars()
                    .filter(|c| !c.is_control())
                    .take(96)
                    .collect()
            },
            id: m.slug,
            effort_levels: m.supported_reasoning_levels.map(|values| {
                let mut seen = HashSet::new();
                values
                    .into_iter()
                    .filter_map(|v| cached_effort(&v.effort))
                    .filter(|e| seen.insert(*e))
                    .take(8)
                    .collect()
            }),
            default_effort: m.default_reasoning_level.as_deref().and_then(cached_effort),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_effort_levels_are_model_specific_and_filter_unknown_values() {
        let file = tempfile::NamedTempFile::new().unwrap();
        fs::write(file.path(), r#"{"models":[{"slug":"full","supported_reasoning_levels":[{"effort":"low"},{"effort":"max"},{"effort":"ultra"},{"effort":"low"},{"effort":"invalid"}],"default_reasoning_level":"max"},{"slug":"plain","supported_reasoning_levels":[]},{"slug":"older"},{"slug":"limited","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}"#).unwrap();
        let options = codex_models(file.path());
        assert_eq!(
            options[0].effort_levels,
            Some(vec![Effort::Low, Effort::Max, Effort::Ultra])
        );
        assert_eq!(options[0].default_effort, Some(Effort::Max));
        assert_eq!(options[1].effort_levels, Some(vec![]));
        assert_eq!(options[2].effort_levels, None);
        let catalog = ModelCatalog {
            provider: Provider::Codex,
            source: String::new(),
            options,
            effort_levels: vec![Effort::Low, Effort::High, Effort::Max],
            effort_note: String::new(),
        };
        assert_eq!(
            catalog.levels("full"),
            [Effort::Low, Effort::Max, Effort::Ultra]
        );
        assert!(catalog.levels("plain").is_empty());
        assert_eq!(catalog.levels("limited"), [Effort::Low, Effort::High]);
        assert_eq!(
            catalog.levels("custom"),
            [Effort::Low, Effort::High, Effort::Max]
        );
    }

    #[test]
    fn provider_routes_limit_effort_and_older_models_offer_default_only() {
        let settings = Settings {
            claude_backend: ClaudeBackend::DeepSeek,
            deepseek_mode: DeepSeekMode::DirectApi,
            ..Settings::default()
        };
        let snapshot = crate::claude_config::inspect("", "/nonexistent-conductor-fixture").snapshot;
        let catalogs = catalogs(&settings, &snapshot);
        let for_provider = |provider| catalogs.iter().find(|c| c.provider == provider).unwrap();
        assert!(
            for_provider(Provider::Codex)
                .levels("")
                .contains(&Effort::Max)
        );
        assert!(validate_effort(&settings, &snapshot, Provider::Codex, "", Effort::Max).is_ok());
        assert_eq!(
            for_provider(Provider::Claude).levels("deepseek-flash"),
            [Effort::Low, Effort::High, Effort::Max]
        );
        assert_eq!(
            for_provider(Provider::DeepSeek).levels("deepseek-v4-pro"),
            [Effort::None, Effort::Low, Effort::High, Effort::Max]
        );
        assert_eq!(
            for_provider(Provider::Antigravity).levels("custom"),
            [Effort::Low, Effort::Medium, Effort::High]
        );
        assert!(
            for_provider(Provider::Kiro)
                .levels("claude-sonnet-4-5")
                .is_empty()
        );
        assert!(
            !for_provider(Provider::Kiro)
                .levels("claude-opus-4-6")
                .contains(&Effort::Xhigh)
        );
        assert!(
            validate_effort(
                &settings,
                &snapshot,
                Provider::Claude,
                "deepseek-flash",
                Effort::Medium
            )
            .is_err()
        );
        assert!(
            validate_effort(
                &settings,
                &snapshot,
                Provider::Claude,
                "deepseek-flash",
                Effort::Max
            )
            .is_ok()
        );
    }

    #[test]
    fn codex_cache_exposes_visible_models_without_account_metadata() {
        let file = tempfile::NamedTempFile::new().unwrap();
        fs::write(file.path(), r#"{"identity":"private-account","models":[{"slug":"second","display_name":"Second","visibility":"list","priority":2},{"slug":"hidden","visibility":"hide"},{"slug":"first","display_name":"First","visibility":"list","priority":1},{"slug":"first","priority":3},{"slug":"--bad"}]}"#).unwrap();
        let choices = codex_models(file.path());
        assert_eq!(
            choices.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            ["first", "second"]
        );
        assert!(
            !serde_json::to_string(&choices)
                .unwrap()
                .contains("private-account")
        );
        fs::write(file.path(), "not json").unwrap();
        assert!(codex_models(file.path()).is_empty());
    }
}
