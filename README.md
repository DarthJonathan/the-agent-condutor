# Agent Conductor

A macOS agent workspace for Claude Code, Codex, Antigravity, Qoder, DeepSeek, and Kiro. The primary interface is native SwiftUI; a Rust/Tokio engine supervises headless processes and streamed API requests. A background host connects the native app through private local IPC, with decoding and response formatting off the UI thread. The desktop works independently; the optional web companion adds authenticated remote access.

## Run

The SwiftUI app requires macOS 14 or later, Rust 1.88 or newer, and the Xcode command-line tools (`xcrun swiftc`). Build and open the locally signed application bundle:

```sh
bash scripts/bundle-macos.sh
open "dist/Agent Conductor.app"
```

Use `bash scripts/bundle-macos.sh --debug` for a faster development build. The bundle contains the SwiftUI application and a separate `conductor-engine` helper. This is a local ad-hoc signature; the bundle is not notarized for distribution.

The build generates a full macOS icon set from `macos/Assets/AppIcon.png` and embeds it in the bundle. The original image generation prompt is saved beside the artwork. Install the finished app with `ditto "dist/Agent Conductor.app" "/Applications/Agent Conductor.app"`, then open it from Applications.

Title-bar double-clicks follow the native macOS **Fill/Zoom** behavior configured in **System Settings → Desktop & Dock**. The **Fill** action expands the window within the available desktop. The green window button and **Control+Command+F** enter or leave full screen; title bar buttons and workspace controls retain their normal click actions.

Preview sample runs without invoking providers or writing settings/history:

```sh
"dist/Agent Conductor.app/Contents/MacOS/agent-conductor" --demo
```

Use `--data-dir PATH` for a separate development state directory, or `--view history` / `--view connections` to open a specific screen.

The earlier Rust egui interface remains available as a portable development fallback:

```sh
cargo run --locked
cargo run --locked -- --demo
```

Start with the **Architect / Builder / Reviewer** role team in **Your coworkers**, choose a person in **Talk to**, and click **Send** or press **Cmd+Enter**. Only that person responds to an unaddressed message. Invoke other coworkers with their personal handles, such as `@alex implement this` or `@noah review this`. Each person owns a stable ID and a separate native CLI session, including when two coworkers both use Codex or another connection. **New chat** creates new people and sessions; reopening a saved chat restores its original team.

Suggested names and @handles avoid coworkers in saved chats and open drafts; they stay stable while you compose, add people, or switch folders. **Add coworker** can add another person on any connection, including a connection already used in this chat, up to six people. **Role team** replaces an unstarted draft with Architect, Builder and Reviewer templates; their role instructions guide planning, implementation and independent review. Roles are instructions, not permission sandboxes. **Use task again** copies roles, connections, models and efforts into a new chat with new identities.

Use a coworker's pencil to edit their name, @handle, role, model and reasoning effort. A changed name suggests a matching handle while preserving one you set manually. A draft coworker's connection can change before the chat starts; a saved coworker's connection and ID remain fixed. Renaming preserves their session and messages. History searches names, handles, roles and connections. Handles start with a letter and contain up to 32 ASCII letters, digits, hyphens or underscores. A connection alias such as `@codex` works when exactly one person uses it; with two Codex coworkers, choose a personal handle from autocomplete.

In the macOS sidebar, click **Add folders…** (or press **Cmd+O**) to add one or several project folders. Added folders and the selected workspace survive a restart. Click a folder to switch projects, or use the folder menu in the toolbar. Recent tasks appear under the selected folder, and each folder keeps its draft while the app is open. A running task continues in its original directory when you switch folders. Right-click a folder and choose **Remove from sidebar** to remove the entry; files and saved history remain available. Open **Connections** to set executable paths, models, file edit approvals, and additional CLI arguments. Click **Save & check** after changing an executable. The Rust fallback offers Parallel/Handoff workflows and supports **Ctrl+Enter** on other platforms.

Click **New chat** (or press **Cmd+N**) to open the conversation area with a message composer pinned at the bottom. Choose the first recipient with **Talk to**, then use **Send** or **Cmd+Enter**. Saved chats in the folder sidebar and **Run history** open directly into their dialogue and reply box. History has a full-width search field; older Parallel/Handoff results offer **Start chat**, which prepares their prompt and team for a new conversation without sending automatically.

Type **@** in the composer to autocomplete a teammate. The menu lists this chat's names, engines, and @handles; typing filters by any of them, so `@cod` can suggest this chat's Codex coworker. Use **↑ / ↓**, then **Tab** or **Return**, or click a row to insert the handle. **Esc** dismisses the menu. Completion works at the cursor in a longer message and preserves the rest of the text. Email addresses and fenced or inline code examples do not open the menu. Choosing a completion only edits the message; **Send** or **Cmd+Enter** invokes the addressed teammates.

Turn on **Team discussion** below the composer to have agents talk to each other. Choose a lead with **Led by**, write what they should discuss, and click **Discuss**. The lead gives an initial answer, Conductor sends it to each teammate for a review, and the lead resumes with everyone's feedback to answer you. Requests and replies show who is talking to whom. This works in an existing chat using each agent's saved session and custom name. With four members, one discussion produces five replies; with two, it produces three. Every member must be ready before it starts. **Stop** cancels the current reply and the remaining exchanges. Turn the option off to return to direct messages and @mentions; new chats start with it off.

Use the **model menu** beneath each person in **Your coworkers** to choose the model for their next invocation. The composer also shows a model menu for the person chosen in **Talk to / Led by**. Selections are saved with that chat and restored when it is reopened. **Default** uses the connection's model, or its detected CLI/provider default. **Custom model…** accepts an explicit model ID. New chats use Connection defaults; reusing a chat carries its model selections into the new draft. Each workspace keeps its own model draft while the app is open.

The choices follow the configured provider: [Claude Code aliases](https://code.claude.com/docs/en/model-config) for Anthropic, DeepSeek Flash and V4 Pro for a DeepSeek-backed Claude connection, [Qoder tiers](https://docs.qoder.com/cli/model), and Kiro Auto plus custom IDs. Codex choices come from its local `models_cache.json` under `CODEX_HOME` or `~/.codex`; hidden entries are excluded. If that catalogue is unavailable, Default and Custom still work. Antigravity uses Default and a custom model ID from its installed headless CLI. Model choices are suggestions rather than an account-access check; the CLI/API validates access when invoked.

Changing a chat model leaves Connection defaults and terminal CLI settings intact. The next invocation starts a fresh native session for that agent with shared chat context; other agents keep their sessions. A team discussion uses each member's selected model for both initial and follow-up replies. Model changes are disabled during an active reply, and conflicting additional `--model` / `-m` arguments or Codex `-c model=…` overrides are rejected. Exports include the selected models.

## Provider connections

| Provider | Interface | Setup |
| --- | --- | --- |
| Claude | `claude --print --output-format stream-json --verbose --include-partial-messages` | Install Claude Code and authenticate with its CLI. [Official headless docs](https://code.claude.com/docs/en/headless). |
| Codex | `codex exec --json`, with the prompt on stdin | Install Codex CLI and authenticate with its CLI. [Official noninteractive docs](https://developers.openai.com/codex/noninteractive/). |
| Antigravity | Headless `agy --print --output-format stream-json` | Requires the **separate Antigravity CLI**. The editor's `agy` / `antigravity` launcher is detected as incompatible and is never used to run a task. [Official headless docs](https://www.antigravity.google/docs/cli/headless/). |
| Qoder | `qoder` or `qodercli --print --output-format stream-json` | Install Qoder CLI and sign in. Both executable names are searched. [Official script docs](https://docs.qoder.com/cli/run-in-scripts). |
| DeepSeek | Headless `claude --print` using DeepSeek, or streaming HTTPS `/chat/completions` | Choose **Claude Code · agent** or **Direct API · text**. Supply a DeepSeek key, or reuse an existing DeepSeek configuration in Claude Code. [Official Claude Code integration](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/), [API docs](https://api-docs.deepseek.com/). |
| Kiro | `kiro-cli chat --v3 --no-interactive --output-format stream-json`, with the prompt on stdin | Install a current Kiro CLI exposing the V3 JSON and `--resume-id` flags. Set `KIRO_API_KEY` for the app or enter a session key in Connections. [Official headless docs](https://kiro.dev/docs/cli/headless/). |

Detection checks the installed executable's help flags; it does **not** verify authentication, subscription access, quota, or a model's availability. Those failures appear in the run's response and timeline. The app searches `PATH`, common Homebrew locations, `~/.local/bin`, `~/.cargo/bin`, Bun, and installed NVM Node directories. An explicit path takes precedence. CLI subprocesses receive this expanded `PATH`, which also supports launching the dashboard outside a terminal.

In **Connections → Claude Code configuration**, the detector shows the backend, model, endpoint, and settings source for the selected workspace. It reads the app's environment, the Claude configuration folder, project/local overrides, and local managed settings. Expand **Configuration folder and sources** to see paths or choose a different folder for Conductor. Automatic folder selection follows `CLAUDE_CONFIG_DIR`, then `~/.claude`.

Choose **Auto**, **Claude · Anthropic**, **DeepSeek**, or a **Custom Anthropic-compatible API** for the Claude agent. Auto follows the detected provider. For DeepSeek, it corrects a conflicting top-level Claude model using the configured DeepSeek Sonnet alias, or `deepseek-flash` as a fallback. The correction applies to **Conductor runs only**, including the main model and subagent aliases; the original file is unchanged. Supported DeepSeek harness models are `deepseek-flash` and `deepseek-v4-pro`. Legacy `deepseek-v4-flash` is normalized to `deepseek-flash`, and `[1m]` suffixes are removed for the API model name. An explicitly entered incompatible Claude model is rejected before launching the agent.

Explicit provider choices set the endpoint, model, and authentication together for **Conductor runs only**; they never rewrite your user/project Claude settings or change terminal sessions. Claude can use its existing CLI sign-in; third-party endpoints need a session key or a detected credential for the same endpoint. Switching providers clears the previous session key and model. A custom endpoint requires its model ID. Click **Save & check** after editing a key, endpoint, or model. These controls apply to the Claude team member; the separate DeepSeek team member keeps its own transport options.

Overrides use child-process environment variables and a private `0600` temporary `--settings` file, removed after completion or cancellation. Credentials stay out of command arguments, saved preferences, and history. Inherited permission rules and hooks remain in effect. Local managed routing prevents provider overrides; authentication, account access, and server/MDM policies remain the CLI's responsibility. See [Claude Code settings and session overrides](https://code.claude.com/docs/en/settings).

DeepSeek defaults to a **Claude Code headless harness**, which supplies the coding agent loop and workspace tools. On first launch, a detected DeepSeek endpoint enables **Use Claude Code's existing DeepSeek provider configuration**. This reuses the CLI's authentication without storing its credentials in Conductor. Leave Model blank to use the detected DeepSeek model with the correction described above. Changing the workspace or configuration folder refreshes detection; an endpoint configured for another provider cannot be used as the DeepSeek agent.

To connect an explicit DeepSeek key, uncheck that option and set `DEEPSEEK_API_KEY` or enter a session key. The runner sets `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and model aliases through the same per-run overrides. The API base URL defaults to `https://api.deepseek.com`, and the harness adds `/anthropic`. The chosen Claude configuration folder also applies to this harness.

The alternative **Direct API · text** mode is a reasoning API, **not a coding agent**: it receives the prompt and earlier handoff notes, has no workspace file/shell tools, and is instructed not to claim local execution. Its default model is `deepseek-flash`; model and base URL are configurable. Click **Save & check** after changing transport, authentication, or executable settings.

## Workflows

- **Chat (Conversation):** Choose coworkers and a lead. Unaddressed messages go to the lead; personal @handles invoke the addressed people. Connection aliases require a single matching coworker. Mentions in fenced code, inline code or email addresses are ignored. Each reply has its own streamed response and activity. Unavailable idle members do not block a ready lead. The team is fixed for that task; start a new chat to change its membership.
- **Parallel (Independent):** Run the same prompt in separate sessions with all selected agents concurrently. Their responses and activity are displayed separately.
- **Handoff (Collaborate):** Run selected agents sequentially. The first agent investigates/plans; later agents receive the original task and bounded findings from earlier agents. The final agent completes or reviews the task and gives a final answer. Reorder the team with the arrows in Connections. Failure, timeout, or cancellation stops the handoff and cancels remaining stages.

Chat saves native session IDs per task and agent. Claude/DeepSeek and Qoder use `--resume <id>`, Codex uses `exec … resume <id>`, Antigravity uses `--conversation <id>`, and Kiro uses `--resume-id <id>`. Resumption always uses the exact saved ID. Changed model, explicit effort, executable, arguments, permissions, configuration folder, or provider endpoint starts a fresh session with shared context. Other teammates keep their sessions. Session IDs require the CLI's own local session history to remain available. Direct API mode receives shared text context and has no native CLI session. Old batch tasks remain readable; use a new Chat task for persistent messaging.

Each teammate has an **Effort** menu below their model in **Your coworkers**. The choice is saved for that person in the chat and applies to their next direct reply, mention, teammate request or discussion turn. **Default** inherits the connection's **Default reasoning effort**, or leaves its CLI/provider default in charge. Connections defaults also apply to Parallel and Handoff runs. Old settings and conversations keep Default without changing their saved session scopes. Replies show the requested explicit effort; provider or organization limits can still cap the actual level.

Effort uses each provider's native control: [Claude Code](https://code.claude.com/docs/en/model-config#adjust-effort-level), [Kiro V3](https://kiro.dev/docs/models/), and [Antigravity](https://www.antigravity.google/docs/cli/headless/#select-a-model-effort-or-agent) use `--effort`; [Qoder](https://docs.qoder.com/cli/model) uses `--reasoning-effort`; [Codex](https://learn.chatgpt.com/docs/agent-configuration/subagents#reasoning-effort-model_reasoning_effort) uses a per-invocation `model_reasoning_effort` config override. Codex levels come from the selected model's local `models_cache.json` capability metadata, including Max and Ultra when advertised. Default, custom models and models without capability metadata offer Low / Medium / High / Extra high / Max; Codex validates model and account limits when invoked. DeepSeek offers Low / High / Max through Claude Code, with `CLAUDE_CODE_EFFORT_LEVEL` applied to the child and its private settings file. Its [direct API](https://api-docs.deepseek.com/guides/thinking_mode/) sends `reasoning_effort` and also offers Off. Antigravity offers Low / Medium / High; Claude, Qoder, and Kiro expose their documented CLI levels and apply model limits. Known older Claude models without adaptive effort offer Default only. Unsupported choices and conflicting additional effort flags are rejected before the affected agent runs. Selecting effort never invokes a model or edits terminal CLI configuration.

An agent can request a teammate through an explicit own-line block outside a code fence:

```xml
<conductor-send to="noah">Review the proposed change and report problems.</conductor-send>
```

Rust delivers the request to that coworker's own session and returns a correlated reply to the sender. Ordinary agent prose does not dispatch work. **Mailbox** beside chat shows queued, delivered, waiting for the human, completed, failed, cancelled and paused deliveries. You can queue a user message during an active exchange or cancel a particular queued/current delivery. Requests and replies remain visible in the transcript. At most three requests are accepted per response and eight turns run per exchange; remaining mail pauses for **Continue queued messages**. Duplicate requests are suppressed within the same exchange, including after a human question/restart. Up to 32 user deliveries can be pending, with a 3 MiB pending-text budget; history retains up to 256 deliveries / 4 MiB. The transcript retains the original task and recent exchanges within 128 messages / 4 MiB. Each invocation receives the original task excerpt (8 KiB), recent shared excerpts (48 KiB), and its current delivery, labeled by coworker and message kind.

Team discussion schedules one lead answer, one review per teammate, and one final lead answer directly, so it works even when an agent does not emit a dispatch block. Agents receive the current user message, the lead's answer, and shared conversation context. The final lead turn includes each review or an explicit failure notice, and asks the lead to preserve unresolved disagreements. A failed lead stops the discussion; a failed review allows the other reviews and final summary to finish while marking the task failed. Additional agent-generated requests are paused during this bounded round. The option is sent per message and recorded with the user message; it does not change provider configuration or native session scope.

Agents can also ask the human for clarification in Chat. An inline card shows one to four questions, single-choice or multiple-choice options with descriptions, and a custom answer field. Nothing is selected or submitted automatically. Answer or skip every question, then **Send answers** to resume the asking agent. The chat shows **Waiting for you** while the team exchange is paused. Pending questions, answers, the original lead, and the remaining teammate schedule survive restarts. Answers go only to the question's owner; `@mentions` inside a custom answer stay ordinary answer text. Questions and selected answers are included in Markdown exports.

In coworker chats, **Ask a teammate** on the question card lets you assign its questions to another available coworker. Two coworkers on the same connection remain separate choices and use their own saved sessions. The mailbox tracks the answer request; the card shows who is answering and lets you cancel a queued or running attempt. A validated answer records **Answered by [name]**, selects the returned choices or custom text, and resumes the asking coworker's session automatically. Failed, invalid or cancelled attempts leave the original questions open for a human answer or another teammate. If the answering teammate needs human clarification, their own question appears in chat; answering it resumes that teammate before returning to the original asker. Pending answer deliveries survive restart and can be continued from the card. Command approvals remain human decisions.

Every headless provider receives the same question protocol. A live question uses an own-line envelope outside a code fence:

```xml
<conductor-ask>
{"questions":[{"header":"Scope","question":"Which approach should I use?","options":[{"label":"Focused change","description":"Keep the existing design"},{"label":"Full change","description":"Replace the feature"}],"multi_select":false}]}
</conductor-ask>
```

Options may be omitted for free text; up to eight choices per question are supported. Agents end their turn after asking, and Conductor resumes their exact saved session with the human's answers. This works with the current one-shot headless CLIs and direct DeepSeek API mode. Claude-style `AskUserQuestion` events that remain unanswered after a completed turn are converted into the same cards. Native interactive SDK tool-response channels are not wired: [Claude's headless modes can deny interactive questions](https://code.claude.com/docs/en/headless#auto-approve-tools), whereas its [Agent SDK uses a callback for question replies](https://code.claude.com/docs/en/agent-sdk/user-input#handle-clarifying-questions). Clarification answers never change file or tool permissions.

## Responses and thinking

Responses keep the answer separate from provider-supplied **Thinking**, or **Reasoning summary** for Codex. The collapsed section previews the latest text; expand it to read the retained content in a bounded scroll area. Reasoning is saved with its own message or stage, capped at 64 KiB per invocation, and is not added to shared coworker context or the final answer.

The decoder accepts Claude/Qoder thinking blocks and deltas, Codex JSONL reasoning items, DeepSeek `reasoning_content`, and Kiro ACP thought chunks. It displays only readable text returned by the provider, never signatures or encrypted/redacted blocks. Some configurations expose only token counts; those produce one **Thinking…** activity entry. Old saved `System: thinking_tokens` spam is also coalesced when displayed. Text discarded by earlier builds cannot be recovered from those counters. Provider formats: [Claude streaming](https://platform.claude.com/docs/en/build-with-claude/streaming), [Codex noninteractive JSONL](https://learn.chatgpt.com/docs/non-interactive-mode#make-output-machine-readable), [DeepSeek thinking mode](https://api-docs.deepseek.com/guides/thinking_mode/), [Kiro ACP updates](https://kiro.dev/docs/cli/v3/acp-migration/).

## Attention, changes and isolation

The coworker list shows **Working**, **Waiting for [coworker]**, **Needs your answer**, **Ready for review**, and queued/stopped/error states. The sidebar **Inbox** collects unanswered questions, command approvals and changes awaiting review across saved chats. Opening an item selects its owning chat and jumps to the question/approval or opens Changes.

**Changes** beside chat shows Git files, colored diffs, the responsible coworker and recorded checks. Snapshots are captured before execution and after each turn. An unchanged diff keeps its attribution; a changed diff is assigned to the coworker whose turn changed it. This is snapshot attribution, not a filesystem audit; concurrent external edits can affect it. Existing dirty files start unassigned. Shared folders compare against HEAD; isolated task branches compare against their starting commit, including edits already committed by a coworker. Previews cap at 80 files / 16 KiB per file and report truncation. Git external diff and text conversion hooks are disabled for previews.

Send file review feedback to its owner or choose another coworker; it becomes a directed message in their own session. **Ask reviewer** invokes a Reviewer role. **Run check** executes the entered command as literal arguments in this task's working directory, records the real output and exit code, and supports Stop. It does not expand shell variables, pipelines or command substitutions. Explicitly invoking a shell still runs that shell. Checks time out after five minutes and retain 32 KiB from each output stream, with a truncation notice; the latest 24 results remain in the pane.

Agents can request an explicit command approval using the same headless envelope pattern:

```xml
<conductor-approval>
{"summary":"Run the project's tests","argv":["cargo","test","--locked"]}
</conductor-approval>
```

The card shows the exact arguments and task folder. **Approve once** executes those arguments once and resumes the requesting coworker with the actual result; **Decline** executes nothing and returns that decision to the owner. The decision grants no other commands or CLI permissions. Approvals survive restart. If the app closes during an approved command and the result is unknown, it records Interrupted and requires fresh approval before another execution. This explicit command protocol is separate from provider-native interactive SDK/tool approvals, which are not yet brokered.

Before starting a chat, choose **Shared project folder**, **New isolated worktree**, or **Share another task's workspace**. Isolation creates a `codex/team-…` branch from HEAD and a checkout under the local data directory's `worktrees` folder. All coworkers in that chat deliberately share its checkout. Independent chats can use separate worktrees; explicit sharing reuses a selected task's checkout without reusing its coworkers or sessions. Original uncommitted files are left in the source folder. Isolation requires a Git repository with a commit. Branches/worktrees are preserved; merging and cleanup are manual. The UI groups an isolated chat under its original project folder.

Parallel/Handoff in the Rust fallback still use their selected folder and do not automatically isolate concurrent file edits. Only one task exchange, check or batch runs at a time. The native Mac app attaches to a background host; enabling Remote keeps it available after the desktop closes. Herdr/SSH integration is a later phase.

## Permissions and cancellation

- Prompts and arguments are passed with `tokio::process::Command`, without a shell. Codex and Kiro read their prompts from stdin; other CLIs receive literal argv. Additional arguments are a JSON array rather than a shell command.
- Codex defaults to `--sandbox read-only`. Enabling file edits selects `workspace-write`; approval requests are denied with `approval_policy="never"`.
- Claude and the DeepSeek Claude Code harness use `dontAsk`, and Qoder uses `dont_ask`, unless file edit approvals are enabled, which selects `acceptEdits` / `accept_edits`. Existing CLI permission rules still apply; these modes are not a universal read-only sandbox.
- Antigravity retains its own permission settings, which may auto-allow workspace file writes and deny unattended shell approvals.
- Kiro uses V3 and explicitly trusts only its file-reading/search tools by default. **Allow file edits** adds `fs_write`, `fs_append`, and `str_replace`. Existing Kiro permission rules still apply, and unattended shell or MCP approvals follow those rules. No session-wide `--trust-all-tools` flag is added. Session API keys are passed only to the Kiro child process and stay out of saved data.
- No permission-bypass flags are added by default. User-configured extra arguments can change CLI behavior.
- **Cancel run**, closing the app, and the per-agent timeout stop owned CLI processes. On macOS/Linux, processes run in a new process group, and cleanup kills that group, including ordinary tool subprocesses. Detached processes that deliberately leave the group are outside that guarantee. On Windows, cleanup currently kills the parent process only.

Handoff remains an explicit sequence of fresh agent sessions; use Chat for persistent coworker sessions, a mailbox, command approval cards and teammate messaging. Worktrees are never merged or deleted automatically.

## Local data

Settings and the last 100 runs are saved as JSON under the operating system's local app-data directory:

- macOS: `~/Library/Application Support/agent-conductor`
- Linux: `$XDG_DATA_HOME/agent-conductor` or `~/.local/share/agent-conductor`
- Windows: `%LOCALAPPDATA%/agent-conductor`

Writes use a temporary file followed by rename; Unix files are created with mode `0600`. Response display is capped at 256 KiB per stage and activity at 1,500 entries per stage. Incomplete saved runs become **Interrupted** after restart. Invalid saved files are preserved and automatic saving is disabled until they are repaired.

Session API keys are never serialized into saved settings, history, or exports. Claude Code overrides also place them in the private temporary settings file for the lifetime of the subprocess. CLI credentials remain managed by each CLI. Avoid placing credentials in additional arguments because those arguments are saved. Prompts, responses, and tool diagnostics can contain sensitive project data; they are retained locally and are sent to the selected providers when a run executes.

**Copy** copies the selected agent response. **Export** writes a Markdown report to the data directory's `exports` folder. **Use task again** prepares a new task without starting it automatically.

**Clear inbox** dismisses the notifications currently visible in the Inbox; the **×** on a row dismisses just that notification. These acknowledgements are saved across restarts. Pending questions and approvals remain available in their chats, and a new question or a new review from the same coworker appears again. **Delete chat** is available in a chat's header, its sidebar context menu, and Run history. Confirming deletion permanently removes the saved conversation, mailbox and inbox entries from Conductor. Stop a working chat before deleting it. Project files, worktrees, CLI sessions and exported reports are kept.

Chat and saved responses share a native Markdown renderer. Tables have aligned headers, borders, wrapping cells, and horizontal scrolling when needed. Numbered and nested lists, task checkboxes, block quotes, dividers, headings, links, and inline formatting retain their structure. Fenced and indented code keep their whitespace, with a language label and **Copy** button. Parsing runs off the UI thread and also accepts unfinished streamed Markdown; saved response text and Markdown exports remain intact.

## Development

The accepted implementation plan is delivered in five phases:

| Phase | Implemented behavior | Verification |
| --- | --- | --- |
| Coworker identities and roles | Fresh Architect/Builder/Reviewer teams; repeated connections; per-person model, effort, rename and exact native session | Swift team store fixture and Rust bridge CLI fixture |
| Rust mailbox | Correlated requests/replies, delivery states, queued human messages, per-delivery cancellation and bounded durable continuation | Duplicate-Codex, cancellation, eight-turn limit and restart fixtures |
| Attention and decisions | Coworker state labels; one Inbox for questions, approvals and reviews; answers return to their owner | Native navigation fixture, persisted question and approve/decline checks |
| Changes and review | Git snapshots, colored file diffs, attribution, real check results and directed review feedback | Temporary repository, literal-command and actual exit-code tests |
| Workspace isolation | Separate task branches/worktrees or deliberate sharing; original project grouping and dirty source preservation | Worktree, committed-diff and shared-checkout fixtures |

The new team path lives in `src/team.rs`; legacy chat and Rust batch protocols remain available for compatibility. The HTTP remote companion adds a detached host and browser access; its setup and storage design are described below. Herdr integration, provider-native SDK approval callbacks and automatic worktree merging/cleanup remain later work.

Verify the engine/frontend transport with local executable fixtures (no model calls):

```sh
python3 scripts/bridge-smoke.py
python3 scripts/chat-smoke.py
python3 scripts/team-smoke.py
python3 scripts/inbox-smoke.py
```

Build the SwiftUI app and run a fixture through its actual UI model and Rust connection:

```sh
python3 scripts/bridge-smoke.py --prepare-swift
"dist/Agent Conductor.app/Contents/MacOS/agent-conductor" --data-dir "$PWD/target/swift-smoke" --smoke-test --capture "$PWD/target/swift-smoke.png"
python3 scripts/chat-smoke.py --prepare-swift
"dist/Agent Conductor.app/Contents/MacOS/agent-conductor" --data-dir "$PWD/target/swift-chat-smoke" --smoke-test --capture "$PWD/target/swift-chat-smoke.png"
```

SwiftUI `--capture` produces a layout preview using ImageRenderer. AppKit-backed text editors, pickers, and scroll views may be omitted from that preview; the fixture run separately exercises the frontend connection and lifecycle.

Check folder selection, draft restoration, task scoping, provider switching, and credential isolation without starting an app window:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" -module-cache-path target/swift-module-cache macos/Models.swift macos/NativeResponseText.swift macos/MentionEditor.swift macos/RemoteAccess.swift macos/EngineStore.swift macos/Views.swift scripts/workspace-smoke.swift -o target/workspace-smoke-test
target/workspace-smoke-test
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" -module-cache-path target/swift-module-cache macos/Models.swift macos/NativeResponseText.swift macos/MentionEditor.swift macos/RemoteAccess.swift macos/EngineStore.swift macos/Views.swift scripts/team-store-smoke.swift -o target/team-store-smoke-test
target/team-store-smoke-test
```

For populated Inbox, question, approval, team and Changes layout previews, run `python3 scripts/team-smoke.py --prepare-swift`, then pass the printed data directory's `runs.json` to `target/team-store-smoke-test PATH/runs.json --render`. It writes `target/team-*-preview.png`; AppKit controls may appear as unsupported placeholders in ImageRenderer, while native store tests exercise their state transitions.

Add `--native-preview` to render the question card's real menus and text fields in a hidden fixture window. It writes `target/team-question-native-preview.png` without opening a window on the desktop or interacting with the installed app.

For Inbox dismissal/deletion state checks and native previews, pass the directory printed by `python3 scripts/inbox-smoke.py` to this fixture:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" -module-cache-path target/swift-module-cache -O macos/Models.swift macos/NativeResponseText.swift macos/MentionEditor.swift macos/RemoteAccess.swift macos/EngineStore.swift macos/Views.swift scripts/inbox-store-smoke.swift -o target/inbox-store-smoke-test
target/inbox-store-smoke-test PATH --native-preview
```

It verifies engine/frontend notification keys, pending question and approval preservation, confirmation state, selected and unselected chat deletion, navigation cleanup and invalidation of delayed transcript updates. Native previews are written to `target/inbox-ui-preview.png` and `target/history-ui-preview.png` using hidden fixture windows.

Check UI event delivery under backpressure and response layouts:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" -module-cache-path target/swift-module-cache macos/Models.swift macos/NativeResponseText.swift macos/MentionEditor.swift macos/RemoteAccess.swift macos/EngineStore.swift macos/Views.swift scripts/responsiveness-smoke.swift -o target/responsiveness-smoke-test
target/responsiveness-smoke-test --delivery-only
target/responsiveness-smoke-test --render-only
target/responsiveness-smoke-test --offscreen-scroll
target/responsiveness-smoke-test
```

The delivery check queues 1,000 streaming snapshots before the main loop can consume them, preserving start, question, notice and completion events. Visual progress is coalesced per run and paced to 15 updates per second **before Markdown parsing**. Only one background render job runs at a time, with separate, bounded caches for interleaved chats. During user scrolling and while reading older messages, progress waits until the reader returns to the bottom or chooses **Latest**; the engine continues running. Questions, approvals, handoffs and terminal states bypass that hold. Actual viewport movement is tracked too, covering mouse wheels, momentum and scrollbar dragging without publishing state for every pixel.

Check the background renderer and history-reading delivery boundary:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" -module-cache-path target/swift-module-cache -O macos/Models.swift macos/NativeResponseText.swift macos/MentionEditor.swift macos/RemoteAccess.swift macos/EngineStore.swift macos/Views.swift scripts/renderer-delivery-smoke.swift -o target/renderer-delivery-smoke-test
target/renderer-delivery-smoke-test
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" -module-cache-path target/swift-module-cache -O macos/Models.swift macos/NativeResponseText.swift macos/MentionEditor.swift macos/RemoteAccess.swift macos/EngineStore.swift macos/Views.swift scripts/completed-scroll-smoke.swift -o target/completed-scroll-smoke-test
target/completed-scroll-smoke-test
```

The renderer check coalesces 2,000 raw progress packets, holds parsing across separate scroll gestures, catches up at Latest, and checks in-flight rendering, questions, approvals and cancellation. The full-chat check draws 24 completed cards with twelve 40 KB replies through 90 Retina viewport positions, verifies that reading older replies pauses delivery, and grows a live reply twelve times to check automatic following. It writes `target/completed-scroll-preview.png`. These hidden-window checks measure layout and drawing work, not live compositor frame rates.

Chat columns have concrete widths. Completed cards receive only their own content and display names, retain unchanged Markdown, and do not observe the streaming store. Question and approval controls observe it independently. Replies, errors, reasoning and activity use native selectable TextKit views, with cached text layout per response width. Streaming replies reuse unchanged formatted blocks and replace only the changed text suffix, preserving selection and existing table objects. Native text tables replace the SwiftUI Grid and its height preference loop. The transcript keeps stable card heights in an eager stack, avoiding paragraph selection overlays and lazy height estimation. Repeated follow requests coalesce and wait for layout; user scrolling pauses following until the reader returns to the bottom or chooses Latest.

The native window fixture measures main-loop delays during waiting, long streamed responses, teammate handoffs, mention completion and inspector switching; it uses synthetic data and never launches an engine or provider. Native window mode requires access to the desktop. `--offscreen-scroll` uses a hidden, never-ordered window to give the real chat's AppKit scroll document valid bounds. It moves the viewport through the transcript while simulating teammate updates and checking every reply's drawn bounds. ImageRenderer omits AppKit controls and is a layout check, not a substitute for native responsiveness measurements.

Exercise actual native text layout and an offscreen SwiftUI/AppKit scroll hierarchy, including large replies, selection, table geometry and cached measurements:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" -module-cache-path target/swift-module-cache -O macos/Models.swift macos/NativeResponseText.swift scripts/native-text-smoke.swift -o target/native-text-smoke-test
target/native-text-smoke-test
target/native-text-smoke-test --draw-scroll
```

This check scrolls four 28 KB replies through 600 native and 300 hosted viewport positions in a hidden window, then updates the teammate reply. It verifies that the viewport moves beyond the first reply, completed replies retain their measured layouts, user scrolling takes priority over following, and native tables occupy distinct columns. Streaming and window-resizing checks compare drawn text bounds with each card's allocated height, including code blocks, tables and wrapped formulas. Height measurement uses an independent TextKit container so the native view's previous frame cannot affect the next card size. It writes `target/native-markdown-preview.png` and `target/native-reply-bounds-preview.png`. `--draw-scroll` additionally renders 60 viewport positions at Retina scale and reports drawing timings. These offscreen checks do not measure live trackpad interaction or compositor performance.

Benchmark native streaming updates and check that incremental formatting matches a freshly formatted document, including earlier rewrites, long code, Unicode, shrinking replies and style changes:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" -module-cache-path target/swift-module-cache -O macos/Models.swift macos/NativeResponseText.swift scripts/streaming-text-smoke.swift -o target/streaming-text-smoke-test
target/streaming-text-smoke-test
```

Check backward compatibility, reasoning display data, saved heartbeat cleanup, and completed-card stability during 1,000 teammate updates:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" -module-cache-path target/swift-module-cache macos/Models.swift macos/NativeResponseText.swift macos/MentionEditor.swift macos/RemoteAccess.swift macos/EngineStore.swift macos/Views.swift scripts/response-smoke.swift -o target/response-smoke-test
target/response-smoke-test
```

Rust decoder tests cover partial/final reasoning deduplication, public summaries, session scoping, token-only heartbeats, and UTF-8 limits. Bridge and team fixtures verify persistence, separate answer text, and handoffs that exclude reasoning from coworker prompts.

Check Markdown parsing and render a layout fixture with tables, lists, quotes, and code:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path target/swift-module-cache macos/Models.swift macos/NativeResponseText.swift macos/MentionEditor.swift macos/RemoteAccess.swift macos/EngineStore.swift macos/Views.swift scripts/markdown-smoke.swift -o target/markdown-smoke
target/markdown-smoke --render
```

Capture the Rust fallback's own rendered viewport to a PNG for visual checks (requires a desktop graphics environment):

```sh
cargo run --locked -- --demo --capture target/dashboard.png
cargo run --locked -- --demo --view history --capture target/history.png
```

The capture command closes the app after saving. Without `--demo`, provider detection runs first; no agent task is submitted.

```sh
cargo fmt --all --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

Automated tests use deterministic CLI fixtures and local HTTP servers, with no paid model calls. They cover protocol decoding, semantic failures, UTF-8/SSE chunk framing, process cancellation, workflow handoffs, Claude configuration precedence, the mixed Sonnet/DeepSeek config regression, private credential-file cleanup, unchanged original settings, persistent Chat routing, teammate requests and replies, exact session resumption after restart, profile changes, conversation limits, and persistence recovery. The native Chat smoke sends three direct messages followed by a four-agent team discussion through the SwiftUI store and Rust bridge, verifying shared reviews, resumed sessions, and saved dialogue. Local HTTP fixtures require permission to bind a loopback socket if you run the tests inside a restricted sandbox.

A live `claude -p` smoke test has also succeeded using the current machine's CLI configuration; its result reported DeepSeek model usage. Other live provider accounts have not been exercised.

The native Chat fixture also selects a DeepSeek model for Claude and a custom model for Codex, switches Codex before the team discussion, and verifies the emitted model IDs, saved selections, and session change. The bridge fixture checks per-chat overrides, default restoration, restart persistence, model flags for all six providers, and rejection of hidden model overrides.

Effort checks cover all six CLI argument mappings, Claude's scoped environment and private settings, DeepSeek's HTTP payload including thinking Off, model-specific Codex levels, legacy migration, metadata-only edits, restart persistence, default restoration, unchanged peer sessions, workspace drafts, and conflicting additional arguments. The native Chat fixture also selects different efforts per teammate, changes Codex effort before a discussion, and restores them from saved history.

The SwiftUI app targets macOS. Linux and Windows builds of the Rust fallback remain to be verified. Windows requires native `.exe` CLI executables; `.cmd` shell shims are deliberately not executed.

## Code map

| File | Responsibility |
| --- | --- |
| `macos/ConductorApp.swift` | Native window lifecycle and keyboard commands |
| `macos/Views.swift` | SwiftUI workspace, connection settings, history, responses and timeline |
| `macos/MentionEditor.swift` | Native message input and teammate @ autocomplete |
| `macos/EngineStore.swift` | Background event decoding, UI state and Rust process lifecycle |
| `macos/RemoteAccess.swift` | Remote login, folder sharing, Keychain device credentials and optional startup |
| `macos/Models.swift` | Shared JSON models and response formatting |
| `macos/NativeResponseText.swift` | Cached native Markdown text layout, selectable tables, and transcript scroll tracking |
| `src/bridge.rs` | Headless engine controller, JSON protocol and batched run updates |
| `src/host.rs` | Background engine ownership, private socket and delivery acknowledgements |
| `src/remote.rs` | Outbound relay connection, bounded event projection and scoped commands |
| `src/conversation.rs` | Persistent Chat routing, shared context, teammate delivery and per-agent resumption |
| `src/team.rs` | Stable coworker IDs, roles, correlated mailbox scheduling, independent sessions and human decisions |
| `src/workspace.rs` | Task worktrees, Git diff snapshots, attribution and explicit supervised checks |
| `src/model_catalog.rs` | Provider model choices and Codex local catalogue metadata |
| `src/app.rs` | Portable Rust egui fallback |
| `src/model.rs` | Settings, run/stage states, local history records |
| `src/claude_config.rs` | Read-only Claude configuration inspection and private per-run provider overrides |
| `src/runner.rs` | CLI discovery, process supervision, HTTPS streaming, workflow scheduling |
| `src/providers.rs` | Provider-specific JSON/SSE decoding into shared events |
| `src/storage.rs` | Atomic JSON persistence and Markdown exports |
| `backend/` | Go/PostgreSQL authentication, device pairing, command queue and event relay |
| `frontend/` | SvelteKit remote workspace, same-origin HTTP proxy and live chat |
| `docker-compose.yml` | Separate Conductor database, API, web app and optional Caddy HTTPS gateway |

## Remote companion

The same repository now contains a Go/PostgreSQL relay in `backend/`, a SvelteKit browser app in `frontend/`, and `docker-compose.yml`. Remote access requires login and explicit folder sharing in the Mac app's **Remote** screen. The laptop initiates HTTP connections to the relay; web commands reuse the same local engine and coworker sessions. Provider credentials stay local.

```sh
bash scripts/remote-dev.sh
```

Open **http://localhost:3005**, create your development account, then sign in from the Mac app with the same server URL and choose folders. Public deployment requires an HTTPS domain and an owner-provisioned account; the local test stack is bound to loopback. The Mac must remain awake and online to execute work.

[Remote setup, backend storage, HTTPS deployment and verification](docs/remote-companion.md) describes retention limits, the Keychain device credential, restart behavior and test commands. Chat/diff copies are visible to the relay operator; this version uses TLS rather than end-to-end encryption.
