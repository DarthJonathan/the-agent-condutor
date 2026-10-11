# Agent Conductor

Run **coding agents** in a shared workspace. Talk to one first, then bring in a teammate.

## Supported agents

| Agent | Runs via | Status |
| :--- | :--- | :---: |
| **Claude** | Claude Code CLI (`claude --print`, headless) | Ready |
| Codex | OpenAI Codex CLI (`codex exec`) | Ready |
| Antigravity | Antigravity CLI (`agy`) | Setup |
| Qoder | Qoder CLI | Ready |
| DeepSeek | Claude Code harness or direct `/chat/completions` API | Ready |
| Kiro | `kiro-cli chat` | Setup |

## Plan

1. Inspect the workspace.
   - Read the project documentation.
   - Review the entry points and **important modules**.
2. Ask a teammate to review the findings.

- [x] Preserve the conversation.
- [ ] Apply the agreed changes.

> Each agent keeps its own session.
>
> Use `@mentions` to invite teammates into the task.

---

### Example

```rust
fn main() {
    println!("Hello from Conductor");
}
```

Read the [project documentation](https://example.com/docs). This paragraph includes *emphasis*, **bold text**, ~~old wording~~, and `inline code`.
