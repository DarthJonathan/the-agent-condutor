#!/usr/bin/env python3
"""Exercise persistent task conversations through the actual bridge, without model calls."""
import copy
import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AREA = ROOT / "target" / "chat-smoke"
DATA = AREA / "data"
CONFIG = AREA / "claude-config"
for folder in (AREA, DATA, CONFIG):
    folder.mkdir(parents=True, exist_ok=True)
SECRET = "fixture-chat-private-key"
KIRO_SECRET = "fixture-private-kiro-key"
config_path = CONFIG / "settings.json"
config_path.write_text(json.dumps({"model": "sonnet-4-5-20250929[1m]", "permissions": {"deny": ["Read(.env)"]}, "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic", "ANTHROPIC_AUTH_TOKEN": SECRET,
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro[1m]", "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash", "CLAUDE_CODE_EFFORT_LEVEL": "max"}}))
config_path.chmod(0o600)
config_before = config_path.read_bytes()
calls_path = AREA / "calls.jsonl"
calls_path.write_text("")
fixture = r'''#!/usr/bin/env python3
import json, os, pathlib, re, sys, time, uuid
if "--help" in sys.argv:
    print("--print --output-format --include-partial-messages --permission-mode --json --sandbox --resume --conversation --no-interactive --resume-id --v3 --trust-tools --effort --reasoning-effort")
    raise SystemExit
provider = pathlib.Path(sys.argv[0]).name.removeprefix("fixture-")
argv = sys.argv[1:]
prompt = sys.stdin.read() if provider in ("codex", "kiro") else argv[-1]
session = None
for flag in ("--resume", "--conversation", "resume", "--resume-id"):
    if flag in argv: session = argv[argv.index(flag) + 1]
if session is not None and not session.startswith(provider + "-"):
    raise SystemExit("wrong agent's session")
session = session or (provider + "-" + str(uuid.uuid4()))
route = {}
private = []
for index, arg in enumerate(argv[:-1]):
    if arg == "--settings":
        private.append(argv[index + 1])
        value = json.loads(pathlib.Path(argv[index + 1]).read_text())
        route = {"model": value["model"], "endpoint": value["env"]["ANTHROPIC_BASE_URL"], "effort": value["env"].get("CLAUDE_CODE_EFFORT_LEVEL"),
                 "aliases": [value["env"][k] for k in ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"]]}
calls = pathlib.Path.cwd() / "calls.jsonl"
previous = calls.read_text().splitlines()
with calls.open("a") as log:
    log.write(json.dumps(dict(provider=provider, argv=argv, prompt=prompt, session=session, routing=route, private=private, pid=os.getpid(), env_effort=os.environ.get("CLAUDE_CODE_EFFORT_LEVEL"), kiro_auth_fixture=os.environ.get("KIRO_API_KEY") == "fixture-private-kiro-key")) + "\n")
headers = list(re.finditer(r"\n(USER MESSAGE|TEAMMATE REQUEST FROM [^\n]+|TEAMMATE REPLY \(continue your work\) FROM [^\n]+|TEAM DISCUSSION SUMMARY)\n", prompt))
header = headers[-1]
message = prompt[header.end():].strip()
source = header[1]
if provider == "codex":
    print(json.dumps({"type": "thread.started", "thread_id": session}), flush=True)
elif provider == "kiro":
    print(json.dumps({"type": "runStarted", "data": {"payloadSchema": "acp", "acpProtocolVersion": 1, "engine": "v3"}}), flush=True)
    print(json.dumps({"type": "sessionUpdate", "data": {"sessionId": session, "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "Fixture input"}}}}), flush=True)
elif provider == "antigravity":
    print(json.dumps({"event": "init", "conversation_id": session}), flush=True)
else:
    print(json.dumps({"type": "system", "subtype": "init", "session_id": session}), flush=True)
if "SLOW" in message and ("SLOW_REVIEW" not in message or source.startswith("TEAMMATE REQUEST")): time.sleep(30)
failed = ("FAIL_REVIEW" in message and source.startswith("TEAMMATE REQUEST") and provider == "qoder") or ("FAIL_LEAD" in message and source == "USER MESSAGE" and provider == "claude")
question_input = {"questions": [
    {"header": "Scope", "question": "How much should I change?", "options": [
        {"label": "Focused change (Recommended)", "description": "Keep the existing design and fix the issue."},
        {"label": "Complete redesign", "description": "Rework the entire feature."}], "multiSelect": False},
    {"header": "Platforms", "question": "Which platforms should I cover?", "options": [
        {"label": "macOS", "description": "Native SwiftUI interface."}, {"label": "Linux", "description": "Shared Rust engine."}], "multiSelect": True},
    {"header": "Details", "question": "Any extra constraints?"}
]}
question_envelope = "<conductor-ask>\n" + json.dumps(question_input) + "\n</conductor-ask>"
native_question = "NATIVE_QUESTION" in message and "USER ANSWERS TO YOUR QUESTIONS" not in message
if "USER ANSWERS TO YOUR QUESTIONS" in message:
    answer = "I received the human's answers and continued the original request in my session."
elif "ASK_HUMAN_TEAMMATE" in message and provider == "claude" and source == "USER MESSAGE":
    answer = 'I will ask Codex to review.\n<conductor-send to="codex">ASK_HUMAN_REVIEW: clarify the scope, then review it.</conductor-send>'
elif "ASK_HUMAN_WITH_DISPATCH" in message and source == "USER MESSAGE":
    answer = 'I need your scope first.\n<conductor-send to="codex">Review after clarification.</conductor-send>\n' + question_envelope
elif (re.search(r"\bASK_HUMAN\b", message) and source == "USER MESSAGE") or ("ASK_HUMAN_REVIEW" in message and provider == "codex" and source.startswith("TEAMMATE REQUEST")):
    answer = "Before I continue, I need your input.\n" + question_envelope
elif native_question:
    print(json.dumps({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [{"type": "tool_use", "id": "native-ask-1", "name": "AskUserQuestion", "input": question_input}]}}), flush=True)
    print(json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "native-ask-1", "is_error": True, "content": "AskUserQuestion is denied in headless mode"}]}}), flush=True)
    answer = "Please answer the question before I continue."
elif "QUESTION_EXAMPLE" in message:
    answer = "Here is a code example:\n```json\n" + question_envelope + "\n```"
elif "LOOP" in message:
    teammate = "codex" if provider == "claude" else "claude"
    answer = 'Loop turn.\n<conductor-send to="' + teammate + '">LOOP ' + str(len(previous)) + '</conductor-send>'
elif provider == "claude" and "ASK_CODEX" in message and not source.startswith("TEAMMATE REPLY"):
    answer = 'I will ask Codex to review.\n<conductor-send to="codex">Review the shared task and return a finding.</conductor-send>'
elif provider == "claude" and "ASK_REVIEWER" in message and not source.startswith("TEAMMATE REPLY"):
    answer = 'I will ask Reviewer to review.\n<conductor-send to="reviewer">Review the shared task and return a finding.</conductor-send>'
elif "NO_DISPATCH" in message:
    answer = 'We could ask @codex. Example only:\n```xml\n<conductor-send to="codex">sample</conductor-send>\n```'
elif source.startswith("TEAMMATE REPLY"):
    answer = "I received the teammate's finding and continued in my session."
elif source == "TEAM DISCUSSION SUMMARY":
    answer = "I received every teammate's review and synthesized the discussion in my own session."
elif failed:
    answer = "Fixture agent failed."
elif "SWIFTUI_MARKDOWN" in message:
    answer = (pathlib.Path(__file__).resolve().parents[2] / "scripts/fixtures/markdown-response.md").read_text()
else:
    answer = "Finding from " + provider + ". Shared context received."
if provider == "codex":
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": answer}}), flush=True)
    print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 5}}), flush=True)
elif provider == "kiro":
    print(json.dumps({"type": "sessionUpdate", "data": {"sessionId": session, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": answer}}}}), flush=True)
    print(json.dumps({"type": "runFinished", "data": {"sessionId": session, "status": "success", "stopReason": "end_turn", "finalText": answer, "finalTextTruncated": False, "usage": {"inputTokens": 10, "outputTokens": 5}}}), flush=True)
elif provider == "antigravity":
    print(json.dumps({"event": "result", "result": {"status": "ERROR" if failed else "SUCCESS", "response": answer, "conversation_id": session}}), flush=True)
else:
    print(json.dumps({"type": "result", "result": answer, "is_error": failed, "session_id": session}), flush=True)
'''
agents = []
for provider in ("claude", "codex", "antigravity", "qoder", "deep_seek", "kiro"):
    executable = AREA / ("fixture-" + provider)
    executable.write_text(fixture)
    executable.chmod(0o755)
    agents.append(dict(provider=provider, selected=provider not in ("antigravity", "kiro"), executable=str(executable),
                       model="", extra_args="[]", allow_edits=False))
settings = dict(workspace=str(AREA), workspace_folders=[str(AREA)], agents=agents, workflow="Conversation", chat_introduced=True,
                timeout_seconds=30, claude_config_dir=str(CONFIG), claude_backend="Inherit",
                deepseek_base_url="https://api.deepseek.com", deepseek_mode="ClaudeCode", deepseek_use_cli_config=True)
if "--prepare-swift" in sys.argv:
    destination = ROOT / "target" / "swift-chat-smoke"
    destination.mkdir(exist_ok=True)
    (destination / "settings.json").write_text(json.dumps(settings))
    (destination / "runs.json").write_text("[]")
    print(destination)
    raise SystemExit
(DATA / "settings.json").write_text(json.dumps(settings))
(DATA / "runs.json").write_text("[]")
child_env = {k: v for k, v in os.environ.items() if not k.startswith("ANTHROPIC_") and k not in
             ["DEEPSEEK_API_KEY", "KIRO_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]}
child_env["CLAUDE_CONFIG_DIR"] = str(CONFIG)


class Bridge:
    def __init__(self):
        self.child = subprocess.Popen([str(ROOT / "target/debug/agent-conductor"), "--bridge", "--data-dir", str(DATA)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=child_env)
        self.events = queue.Queue()

        def read_events():
            for line in self.child.stdout:
                self.events.put(json.loads(line))
        threading.Thread(target=read_events, daemon=True).start()
        self.state = self.until(lambda e: e["type"] == "state")
        self.until(lambda e: e["type"] == "agents_updated")

    def send(self, command):
        self.child.stdin.write(json.dumps(command) + "\n")
        self.child.stdin.flush()

    def until(self, predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            event = self.events.get(timeout=max(0.01, deadline - time.monotonic()))
            assert SECRET not in json.dumps(event) and KIRO_SECRET not in json.dumps(event), "Credential leaked into a bridge event"
            if predicate(event):
                return event
        raise AssertionError("No matching bridge event")

    def chat(self, message, run_id=None, lead="claude", names=None, team_discussion=False, models=None, efforts=None):
        self.send(dict(type="chat", run_id=run_id, prompt=message, lead=lead, settings=settings, names=names or [], models=models or [], efforts=efforts or [], team_discussion=team_discussion))
        return self.until(lambda e: e["type"] == "run_updated" and e["run"]["status"] in ["Completed", "Failed", "Cancelled", "WaitingForUser"])["run"]

    def answer(self, run, message, answers):
        self.send(dict(type="answer_question", run_id=run["id"], message_id=message["id"], request_id=message["question_request"]["id"], answers=answers, settings=settings))
        return self.until(lambda e: e["type"] == "run_updated" and e["run"]["id"] == run["id"] and e["run"]["status"] in ["Completed", "Failed", "WaitingForUser"])["run"]

    def close(self):
        self.send(dict(type="shutdown"))
        self.child.stdin.close()
        assert self.child.wait(timeout=10) == 0


def calls():
    return [json.loads(line) for line in calls_path.read_text().splitlines()]


def assistant_authors(run):
    return [m["author"] for m in run["conversation"]["messages"] if m["kind"] == "assistant"]


bridge = Bridge()
try:
    snapshot = bridge.state["claude_config"]
    assert snapshot["model"] == "sonnet-4-5-20250929[1m]" and snapshot["conductor_model"] == "deepseek-v4-pro"
    catalogs = {c["provider"]: c for c in bridge.state["model_catalogs"]}
    assert [o["id"] for o in catalogs["claude"]["options"]] == ["deepseek-flash", "deepseek-v4-pro"], "Claude's picker ignored its detected DeepSeek endpoint"
    assert [o["id"] for o in catalogs["qoder"]["options"]] == ["auto", "ultimate", "performance", "efficient"]
    bridge.send(dict(type="start", prompt="A Chat task must not dispatch all members as a batch.", settings=settings))
    error = bridge.until(lambda e: e["type"] == "notice" and e["error"])
    assert "Use Chat" in error["message"] and calls() == []
    names = [dict(provider="claude", name="Atlas", mention="atlas"), dict(provider="codex", name="Nova", mention="nova")]
    run = bridge.chat("Describe this workspace first.", names=names)
    run_id = run["id"]
    assert run["status"] == "Completed" and len(run["conversation"]["members"]) == 4
    assert assistant_authors(run) == ["claude"] and [c["provider"] for c in calls()] == ["claude"], "Selecting four agents started all four"
    assert calls()[0]["routing"]["model"] == "deepseek-v4-pro"
    assert set(calls()[0]["routing"]["aliases"]) == {"deepseek-v4-pro"}
    first_session = calls()[0]["session"]
    assert "You are Atlas (@atlas, provider Claude)" in calls()[0]["prompt"]
    assert run["conversation"]["names"][:2] == names
    assert [n["name"] for n in run["conversation"]["names"]][2:] == ["Quinn", "Sage"]

    run = bridge.chat("@claude ASK_CODEX to review your finding.", run_id)
    assert assistant_authors(run)[-3:] == ["claude", "codex", "claude"]
    assert [c["provider"] for c in calls()][-3:] == ["claude", "codex", "claude"]
    assert run["conversation"]["messages"][-2]["to"] == ["claude"] and run["conversation"]["messages"][-1]["to"] == [], "The lead's continuation must be a response to the human"
    assert calls()[-3]["session"] == calls()[-1]["session"] == first_session
    assert "--resume" in calls()[-1]["argv"] and "TEAMMATE REPLY" in calls()[-1]["prompt"]
    assert any(m["kind"] == "request" and m["to"] == ["codex"] for m in run["conversation"]["messages"])
    assert all("<conductor-send" not in m["text"] for m in run["conversation"]["messages"] if m["kind"] == "assistant")

    # Rename metadata without spawning or replacing any CLI session.
    count = len(calls())
    bindings = run["conversation"]["sessions"]
    roster = copy.deepcopy(run["conversation"]["names"])
    roster[1].update(name="Reviewer", mention="reviewer")
    bridge.send(dict(type="rename_team", run_id=run_id, names=roster))
    run = bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["conversation"]["names"] == roster)["run"]
    assert run["conversation"]["sessions"] == bindings and len(calls()) == count
    for invalid, expected in [(roster[:1], "exactly once"), (copy.deepcopy(roster), "already uses")]:
        if len(invalid) > 1: invalid[1]["mention"] = invalid[0]["mention"]
        bridge.send(dict(type="rename_team", run_id=run_id, names=invalid))
        assert expected in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"]
    bridge.send(dict(type="get_run", run_id=run_id))
    unchanged = bridge.until(lambda e: e["type"] == "run_detail")["run"]
    assert unchanged["conversation"]["names"] == roster and unchanged["conversation"]["sessions"] == bindings and len(calls()) == count
    bridge.send(dict(type="rename_agent", run_id=run_id, provider="codex", name="Reviewer", mention="reviewer"))
    run = bridge.until(lambda e: e["type"] == "run_updated" and any(n["mention"] == "reviewer" for n in e["run"]["conversation"]["names"]))["run"]
    assert run["conversation"]["sessions"] == bindings and len(calls()) == count
    bridge.send(dict(type="rename_agent", run_id=run_id, provider="claude", name="Atlas", mention="reviewer"))
    assert "already uses" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"]
    bridge.send(dict(type="rename_agent", run_id=run_id, provider="claude", name="Atlas", mention="kiro"))
    assert "reserved" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"]
    run = bridge.chat("@reviewer check the lead's finding.", run_id)
    assert calls()[-1]["provider"] == "codex" and calls()[-1]["session"] == next(s["session_id"] for s in bindings if s["provider"] == "codex")
    run = bridge.chat("@atlas ASK_REVIEWER to verify the task.", run_id)
    assert assistant_authors(run)[-3:] == ["claude", "codex", "claude"] and calls()[-1]["session"] == first_session
    assert "FROM Reviewer (Codex, @reviewer)" in calls()[-1]["prompt"]

    run = bridge.chat("@qoder check the shared findings.", run_id)
    assert calls()[-1]["provider"] == "qoder" and "Finding from codex" in calls()[-1]["prompt"]
    run = bridge.chat("@codex @deepseek compare the approach.", run_id)
    assert [c["provider"] for c in calls()][-2:] == ["codex", "deep_seek"]
    assert calls()[-1]["session"] != first_session and calls()[-1]["routing"]["model"] == "deepseek-v4-pro"
    count = len(calls())
    run = bridge.chat("NO_DISPATCH: explain mention syntax.", run_id)
    assert len(calls()) == count + 1 and "sample" in run["conversation"]["messages"][-1]["text"]

    # A team discussion guarantees lead -> every peer -> lead, even without model dispatch envelopes.
    bindings = {s["provider"]: s["session_id"] for s in run["conversation"]["sessions"]}
    count = len(calls())
    run = bridge.chat("@codex TEAM_REVIEW: discuss the best approach together.", run_id, team_discussion=True)
    exchange = calls()[count:]
    assert run["status"] == "Completed" and [c["provider"] for c in exchange] == ["claude", "codex", "qoder", "deep_seek", "claude"]
    assert all(c["session"] == bindings[c["provider"]] for c in exchange), "A team discussion replaced an agent's native session"
    for review in exchange[1:-1]:
        assert "TEAMMATE REQUEST FROM Atlas" in review["prompt"] and "INITIAL ANSWER FROM Atlas\nFinding from claude" in review["prompt"]
        assert "@codex TEAM_REVIEW" in review["prompt"]
    summary = exchange[-1]["prompt"].split("\nTEAM DISCUSSION SUMMARY\n")[-1]
    assert all("Finding from " + provider in summary for provider in ["codex", "qoder", "deep_seek"])
    assert "[Reviewer (Codex, @reviewer)]" in summary
    assert len([m for m in run["conversation"]["messages"] if m.get("team_discussion")]) == 1
    assert all(m["to"] == ["claude"] for m in run["conversation"]["messages"][-8:] if m["kind"] == "assistant" and m["author"] != "claude")
    assert run["conversation"]["messages"][-1]["to"] == []
    count = len(calls())
    run = bridge.chat("A direct follow-up should only invoke the lead.", run_id)
    assert len(calls()) == count + 1 and calls()[-1]["provider"] == "claude"

    count = len(calls())
    run = bridge.chat("Let Codex lead this team discussion.", run_id, lead="codex", team_discussion=True)
    assert [c["provider"] for c in calls()[count:]] == ["codex", "claude", "qoder", "deep_seek", "codex"]
    assert all(c["session"] == bindings[c["provider"]] for c in calls()[count:])
    assert "TEAMMATE REQUEST FROM Reviewer" in calls()[count + 1]["prompt"]

    count = len(calls())
    run = bridge.chat("FAIL_REVIEW: review this together even if a peer fails.", run_id, team_discussion=True)
    assert run["status"] == "Failed" and len(calls()) == count + 5
    assert "Quinn could not complete their review. Do not treat this as agreement." in calls()[-1]["prompt"]
    assert run["conversation"]["messages"][-1]["status"] == "Completed", "A failed peer prevented the lead from reporting the outcome"

    count = len(calls())
    failed_lead = bridge.chat("FAIL_LEAD: do not send an incomplete answer to the team.", run_id, team_discussion=True)
    assert failed_lead["status"] == "Failed" and len(calls()) == count + 1
    count = len(calls())

    bridge.send(dict(type="chat", run_id=run_id, prompt="@antigravity check", lead="claude", settings=settings))
    error = bridge.until(lambda e: e["type"] == "notice" and e["error"])
    assert "not in this task" in error["message"] and len(calls()) == count
    bridge.send(dict(type="export", run_id=run_id))
    bridge.until(lambda e: e["type"] == "notice" and not e["error"])
    exported = (DATA / "exports" / (run_id + ".md")).read_text()
    assert "I received the teammate" in exported and "## Atlas" in exported and "## Reviewer" in exported
    assert "*Team discussion*" in exported
    sessions = {s["provider"]: s["session_id"] for s in run["conversation"]["sessions"]}
    bridge.close()
    bridge = Bridge()
    assert len(bridge.state["runs"]) == 1 and bridge.state["runs"][0]["providers"] == run["conversation"]["members"]
    assert bridge.state["runs"][0]["names"] == run["conversation"]["names"], "Saved history lost the employee roster after restart"
    resumed = bridge.chat("@reviewer continue after restart.", run_id)
    assert resumed["id"] == run_id and calls()[-1]["session"] == sessions["codex"] and "resume" in calls()[-1]["argv"]
    assert next(n for n in resumed["conversation"]["names"] if n["provider"] == "codex")["name"] == "Reviewer"

    # Another provider's profile must not reset Codex's native session.
    settings["claude_backend"] = "Anthropic"
    resumed = bridge.chat("@codex keep your session after the other profile changed.", run_id)
    assert calls()[-1]["session"] == sessions["codex"]
    settings["claude_backend"] = "Inherit"
    settings["agents"][1]["model"] = "new-codex-model"
    resumed = bridge.chat("@codex use the new model and shared task history.", run_id)
    assert "resume" not in calls()[-1]["argv"] and calls()[-1]["session"] != sessions["codex"]
    assert any("Connection settings changed" in log["text"] for log in resumed["conversation"]["messages"][-1]["logs"])
    assert "Finding from qoder" in calls()[-1]["prompt"]

    # Select a model for this chat without editing Connection defaults or invoking a CLI.
    count = len(calls())
    before_sessions = resumed["conversation"]["sessions"]
    bridge.send(dict(type="set_agent_model", run_id=run_id, provider="codex", model="chat-codex-model"))
    chosen = bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["id"] == run_id
                          and any(m["model"] == "chat-codex-model" for m in e["run"]["conversation"]["models"]))["run"]
    assert chosen["conversation"]["sessions"] == before_sessions and len(calls()) == count
    resumed = bridge.chat("@codex use the selected chat model.", run_id)
    selected_session = calls()[-1]["session"]
    assert calls()[-1]["argv"][calls()[-1]["argv"].index("--model") + 1] == "chat-codex-model" and "resume" not in calls()[-1]["argv"]
    assert resumed["conversation"]["messages"][-1]["model"] == "chat-codex-model" and settings["agents"][1]["model"] == "new-codex-model"
    assert "Finding from qoder" in calls()[-1]["prompt"]
    resumed = bridge.chat("@codex stay on this model.", run_id)
    assert calls()[-1]["session"] == selected_session and "resume" in calls()[-1]["argv"]
    bridge.close()
    bridge = Bridge()
    resumed = bridge.chat("@codex continue with the saved model after restarting.", run_id)
    assert calls()[-1]["session"] == selected_session and resumed["conversation"]["models"] == [dict(provider="codex", model="chat-codex-model")]
    # Another task still takes its default from Connections.
    other = bridge.chat("Use a separate task's default model.", lead="codex")
    assert other["conversation"]["models"] == [] and calls()[-1]["argv"][calls()[-1]["argv"].index("--model") + 1] == "new-codex-model"
    # Overrides apply to teammates too; the lead's native session remains unchanged.
    count = len(calls())
    resumed = bridge.chat("Discuss with each agent's chosen model.", run_id, team_discussion=True,
                          models=[dict(provider="claude", model="deepseek-flash"), dict(provider="qoder", model="efficient")])
    exchange = calls()[count:]
    assert exchange[0]["routing"]["model"] == exchange[-1]["routing"]["model"] == "deepseek-flash"
    assert exchange[1]["session"] == selected_session and exchange[1]["argv"][exchange[1]["argv"].index("--model") + 1] == "chat-codex-model"
    assert exchange[2]["argv"][exchange[2]["argv"].index("--model") + 1] == "efficient"
    bridge.send(dict(type="export", run_id=run_id))
    bridge.until(lambda e: e["type"] == "notice" and not e["error"])
    assert "## Selected models" in (DATA / "exports" / (run_id + ".md")).read_text()
    # Clear the overrides to return to defaults before the existing cancellation tests.
    for provider in ["claude", "codex", "qoder"]:
        bridge.send(dict(type="set_agent_model", run_id=run_id, provider=provider, model=""))
        bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["id"] == run_id
                     and not any(m["provider"] == provider for m in e["run"]["conversation"]["models"]))
    resumed = bridge.chat("@claude use the detected default again.", run_id)
    first_session = calls()[-1]["session"]
    assert calls()[-1]["routing"]["model"] == "deepseek-v4-pro" and resumed["conversation"]["models"] == []
    count = len(calls())
    bridge.send(dict(type="set_agent_model", run_id=run_id, provider="codex", model="bad\nmodel"))
    assert "model ID" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"] and len(calls()) == count
    bridge.send(dict(type="set_agent_model", run_id=run_id, provider="kiro", model="auto"))
    assert "task's team" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"]
    settings["agents"][1]["extra_args"] = json.dumps(["--config", 'model="override"'])
    bridge.send(dict(type="chat", run_id=run_id, prompt="@codex a hidden override must not win.", lead="claude", settings=settings))
    assert "model picker" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"] and len(calls()) == count
    settings["agents"][1]["extra_args"] = "[]"

    # An unavailable idle team member should not block the lead's first response.
    missing = settings["agents"][2]
    missing["selected"] = True
    missing["executable"] = str(AREA / "missing-headless-cli")
    bridge.send(dict(type="update_settings", settings=settings))
    bridge.send(dict(type="discover"))
    bridge.until(lambda e: e["type"] == "agents_updated" and next(a for a in e["agents"] if a["provider"] == "antigravity")["status"] != "checking")
    idle = bridge.chat("Only the lead should act; the fifth member is not installed.")
    assert idle["status"] == "Completed" and assistant_authors(idle) == ["claude"] and len(idle["conversation"]["members"]) == 5
    idle_names = idle["conversation"]["names"]
    idle_lead = next(n for n in idle_names if n["provider"] == "claude")
    assert len(idle_names) == 5 and f'You are {idle_lead["name"]} (@{idle_lead["mention"]}' in calls()[-1]["prompt"], "The agent did not receive its chat's coworker identity"
    idle_session = calls()[-1]["session"]
    assert idle["id"] != run_id and idle_session != sessions["claude"], "A new coworker inherited another chat's native session"
    fresh = bridge.chat("Another new conversation with its own coworkers.")
    fresh_names = fresh["conversation"]["names"]
    assert {n["mention"] for n in fresh_names}.isdisjoint(n["mention"] for n in idle_names + run["conversation"]["names"]), "New chats reused saved coworker names"
    fresh_session = calls()[-1]["session"]
    assert fresh_session != idle_session and "--resume" not in calls()[-1]["argv"], "A fresh chat resumed another coworker"
    idle = bridge.chat(f'@{idle_lead["mention"]} continue our original conversation.', idle["id"])
    assert idle["conversation"]["names"] == idle_names and calls()[-1]["session"] == idle_session and "--resume" in calls()[-1]["argv"], "Reopening a coworker failed to preserve its name and native session"
    before = len(calls())
    bridge.send(dict(type="chat", prompt="The full team needs to be ready.", run_id=idle["id"], lead="claude", settings=settings, team_discussion=True))
    notice = bridge.until(lambda e: e["type"] == "notice" and e["error"])
    assert "Antigravity" in notice["message"] and len(calls()) == before, "A partially configured discussion launched the lead before rejecting the team"
    missing["selected"] = False

    # Cancelling a native session kills the owned process and preserves the task.
    before = len(calls())
    bridge.send(dict(type="chat", run_id=run_id, prompt="@claude SLOW", lead="claude", settings=settings))
    bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Running")
    deadline = time.monotonic() + 5
    while len(calls()) == before and time.monotonic() < deadline:
        time.sleep(0.02)
    assert len(calls()) == before + 1
    pid = calls()[-1]["pid"]
    bridge.send(dict(type="set_agent_model", run_id=run_id, provider="claude", model="deepseek-flash"))
    assert "current reply" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"]
    bridge.send(dict(type="rename_team", run_id=run_id, names=roster))
    assert "current reply" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"]
    bridge.send(dict(type="cancel", run_id=run_id))
    cancelled = bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Cancelled")["run"]
    assert cancelled["conversation"]["messages"][-1]["status"] == "Cancelled"
    time.sleep(0.1)
    try:
        os.kill(pid, 0)
        raise AssertionError("Cancelled fixture process survived")
    except ProcessLookupError:
        pass
    run = bridge.chat("@claude continue this same task after cancellation.", run_id)
    assert run["status"] == "Completed" and calls()[-1]["session"] == first_session

    # Stop during a peer review also cancels the scheduled remaining reviews and synthesis.
    before = len(calls())
    bridge.send(dict(type="chat", run_id=run_id, prompt="SLOW_REVIEW: discuss together.", lead="claude", settings=settings, team_discussion=True))
    deadline = time.monotonic() + 6
    while len(calls()) < before + 2 and time.monotonic() < deadline:
        time.sleep(0.02)
    assert [c["provider"] for c in calls()[before:]] == ["claude", "codex"]
    peer_pid = calls()[-1]["pid"]
    bridge.send(dict(type="cancel", run_id=run_id))
    stopped = bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Cancelled")["run"]
    assert stopped["conversation"]["messages"][-1]["status"] == "Cancelled"
    time.sleep(0.1)
    assert len(calls()) == before + 2, "Cancelled discussion invoked queued teammates"
    try:
        os.kill(peer_pid, 0)
        raise AssertionError("Cancelled teammate process survived")
    except ProcessLookupError:
        pass

    # Session-control overrides cannot silently resume a different task.
    settings["agents"][0]["extra_args"] = '["--resume=another-session"]'
    before = len(calls())
    bridge.send(dict(type="chat", run_id=run_id, prompt="Should reject the conflicting flag.", lead="claude", settings=settings))
    notice = bridge.until(lambda e: e["type"] == "notice" and e["error"])
    assert "session-control" in notice["message"] and len(calls()) == before
    settings["agents"][0]["extra_args"] = "[]"
    settings["agents"][0]["extra_args"] = '["--model=sonnet-4-5-20250929"]'
    bridge.send(dict(type="chat", run_id=run_id, prompt="Should reject a model flag overriding routing.", lead="claude", settings=settings))
    notice = bridge.until(lambda e: e["type"] == "notice" and e["error"])
    assert "model fields in Connections" in notice["message"] and len(calls()) == before
    settings["agents"][0]["extra_args"] = "[]"
    settings["agents"][0]["model"] = "sonnet-4-5-20250929"
    bridge.send(dict(type="chat", run_id=run_id, prompt="Should reject the incompatible model.", lead="claude", settings=settings))
    notice = bridge.until(lambda e: e["type"] == "notice" and e["error"])
    assert "DeepSeek requires" in notice["message"] and len(calls()) == before
    settings["agents"][0]["model"] = ""

    # Kiro uses piped prompts, scoped tools and an exact saved --resume-id.
    selected = [a["selected"] for a in settings["agents"]]
    for config in settings["agents"]: config["selected"] = config["provider"] == "kiro"
    bridge.send(dict(type="session_key", key="", kiro_key=KIRO_SECRET))
    kiro = bridge.chat("Describe the workspace.", lead="kiro", names=[dict(provider="kiro", name="Scout", mention="scout")], models=[dict(provider="kiro", model="auto")])
    assert kiro["status"] == "Completed" and assistant_authors(kiro) == ["kiro"]
    kiro_id = kiro["id"]
    kiro_session = calls()[-1]["session"]
    assert calls()[-1]["kiro_auth_fixture"] and calls()[-1]["argv"][:3] == ["chat", "--v3", "--no-interactive"]
    assert calls()[-1]["argv"][calls()[-1]["argv"].index("--model") + 1] == "auto"
    assert "--trust-all-tools" not in calls()[-1]["argv"] and "read_file,list_directory,file_search,grep_search" in calls()[-1]["argv"]
    kiro = bridge.chat("@scout continue in your session.", kiro_id, lead="kiro")
    assert calls()[-1]["session"] == kiro_session and "--resume-id" in calls()[-1]["argv"]
    before = len(calls())
    bridge.send(dict(type="chat", run_id=kiro_id, prompt="A discussion requires a teammate.", lead="kiro", settings=settings, team_discussion=True))
    assert "at least two" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"] and len(calls()) == before
    settings["agents"][-1]["extra_args"] = '["--resume-id=foreign-session"]'
    before = len(calls())
    bridge.send(dict(type="chat", run_id=kiro_id, prompt="This must be rejected.", lead="kiro", settings=settings))
    assert "session-control" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"] and len(calls()) == before
    settings["agents"][-1]["extra_args"] = "[]"
    for config, selection in zip(settings["agents"], selected): config["selected"] = selection

    # All six providers fit in one bounded discussion, including headless Kiro.
    for config in settings["agents"]: config["selected"] = True
    settings["agents"][2]["executable"] = str(AREA / "fixture-antigravity")
    bridge.send(dict(type="update_settings", settings=settings))
    bridge.send(dict(type="discover"))
    bridge.until(lambda e: e["type"] == "agents_updated" and all(a["status"] == "ready" for a in e["agents"]))
    before = len(calls())
    all_agents = bridge.chat("Discuss this project as a six-agent team.", lead="codex", team_discussion=True,
                            models=[dict(provider="antigravity", model="fixture-antigravity-model"), dict(provider="kiro", model="auto"), dict(provider="deep_seek", model="deepseek-flash")])
    assert all_agents["status"] == "Completed" and len(calls()) == before + 7
    assert [c["provider"] for c in calls()[before:]] == ["codex", "claude", "antigravity", "qoder", "deep_seek", "kiro", "codex"]
    assert calls()[-1]["session"] == calls()[before]["session"]
    assert set(s["provider"] for s in all_agents["conversation"]["sessions"]) == set(c["provider"] for c in settings["agents"])
    assert "Finding from kiro" in calls()[-1]["prompt"]
    assert calls()[before + 2]["argv"][calls()[before + 2]["argv"].index("--model") + 1] == "fixture-antigravity-model"
    assert calls()[before + 4]["routing"]["model"] == "deepseek-flash"
    agy_session = next(s["session_id"] for s in all_agents["conversation"]["sessions"] if s["provider"] == "antigravity")
    all_agents = bridge.chat("@antigravity continue after the discussion.", all_agents["id"], lead="codex")
    assert all_agents["status"] == "Completed" and calls()[-1]["session"] == agy_session and "--conversation" in calls()[-1]["argv"]

    # Effort is a separate saved choice for every teammate, without starting a CLI.
    effort_id = all_agents["id"]
    original_sessions = copy.deepcopy(all_agents["conversation"]["sessions"])
    requested = dict(claude="low", codex="high", antigravity="medium", qoder="high", deep_seek="max", kiro="xhigh")
    before = len(calls())
    for provider, effort in requested.items():
        bridge.send(dict(type="set_agent_effort", run_id=effort_id, provider=provider, effort=effort))
        selected_effort = bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["id"] == effort_id
                                      and any(c["provider"] == provider and c["effort"] == effort for c in e["run"]["conversation"]["efforts"]))["run"]
        assert selected_effort["conversation"]["sessions"] == original_sessions and len(calls()) == before
    bridge.send(dict(type="set_agent_effort", run_id=effort_id, provider="claude", effort="medium"))
    assert "does not support" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"] and len(calls()) == before
    settings["agents"][1]["effort"] = "low"
    all_agents = bridge.chat("Discuss with each teammate's reasoning effort.", effort_id, lead="codex", team_discussion=True)
    exchange = calls()[before:]
    assert len(exchange) == 7 and all_agents["status"] == "Completed"
    for call in exchange:
        provider, argv = call["provider"], call["argv"]
        expected = requested[provider]
        if provider == "codex":
            assert 'model_reasoning_effort="' + expected + '"' in argv
        else:
            flag = "--reasoning-effort" if provider == "qoder" else "--effort"
            assert argv[argv.index(flag) + 1] == expected
        if provider in ("claude", "deep_seek"):
            assert call["env_effort"] == call["routing"]["effort"] == expected
    last_answers = [m for m in all_agents["conversation"]["messages"] if m["kind"] == "assistant"][-7:]
    assert all(m["effort"] == requested[m["author"]] for m in last_answers)
    codex_session = exchange[0]["session"]
    claude_session = next(c["session"] for c in exchange if c["provider"] == "claude")
    all_agents = bridge.chat("@codex resume with your saved effort.", effort_id)
    assert calls()[-1]["session"] == codex_session
    bridge.send(dict(type="set_agent_effort", run_id=effort_id, provider="claude", effort="max"))
    bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["id"] == effort_id)
    all_agents = bridge.chat("@claude use maximum effort with the shared history.", effort_id)
    assert calls()[-1]["session"] != claude_session and calls()[-1]["routing"]["effort"] == "max"
    all_agents = bridge.chat("@codex keep your session after the teammate's effort changed.", effort_id)
    assert calls()[-1]["session"] == codex_session
    bridge.close()
    bridge = Bridge()
    all_agents = bridge.chat("@codex keep the saved effort after restarting.", effort_id)
    assert calls()[-1]["session"] == codex_session and 'model_reasoning_effort="high"' in calls()[-1]["argv"]
    bridge.send(dict(type="export", run_id=effort_id))
    bridge.until(lambda e: e["type"] == "notice" and not e["error"])
    assert "## Selected effort" in (DATA / "exports" / (effort_id + ".md")).read_text()
    bridge.send(dict(type="set_agent_effort", run_id=effort_id, provider="codex", effort="default"))
    bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["id"] == effort_id)
    all_agents = bridge.chat("@codex use the Connection default effort.", effort_id)
    assert 'model_reasoning_effort="low"' in calls()[-1]["argv"] and calls()[-1]["session"] != codex_session
    for provider in requested:
        bridge.send(dict(type="set_agent_effort", run_id=effort_id, provider=provider, effort="default"))
        bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["id"] == effort_id)
    settings["agents"][1]["effort"] = "default"
    settings["agents"][1]["extra_args"] = '["--config", "model_reasoning_effort=\\\"high\\\""]'
    before = len(calls())
    bridge.send(dict(type="chat", run_id=effort_id, prompt="@codex reject a hidden effort override", lead="codex", settings=settings))
    assert "effort controls" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"] and len(calls()) == before
    settings["agents"][1]["extra_args"] = "[]"
    for config, selection in zip(settings["agents"], selected): config["selected"] = selection

    # All six headless providers can yield structured questions and resume only their own session.
    for provider in ["claude", "codex", "antigravity", "qoder", "deep_seek", "kiro"]:
        before = len(calls())
        waiting = bridge.chat("@" + provider + " ASK_HUMAN before continuing.", effort_id, lead=provider)
        assert waiting["status"] == "WaitingForUser" and len(calls()) == before + 1
        question_message = waiting["conversation"]["messages"][-1]
        request = question_message["question_request"]
        assert question_message["author"] == provider and len(request["questions"]) == 3 and request["answers"] is None
        assert "conductor-ask" not in question_message["text"] and request["questions"][1]["multi_select"]
        session = calls()[-1]["session"]
        if provider == "codex":
            preview = ROOT / "target" / "swift-questions-preview"
            preview.mkdir(exist_ok=True)
            (preview / "settings.json").write_text(json.dumps(settings))
            (preview / "runs.json").write_text(json.dumps([waiting]))
            bridge.send(dict(type="export", run_id=effort_id))
            bridge.until(lambda e: e["type"] == "notice" and not e["error"])
            assert "Waiting for your answer" in (DATA / "exports" / (effort_id + ".md")).read_text()
            bridge.close()
            bridge = Bridge()
            assert next(r for r in bridge.state["runs"] if r["id"] == effort_id)["status"] == "WaitingForUser"
            bridge.send(dict(type="get_run", run_id=effort_id))
            restored = bridge.until(lambda e: e["type"] == "run_detail")["run"]
            assert restored["conversation"]["messages"][-1]["question_request"] == request
            bridge.send(dict(type="chat", run_id=effort_id, prompt="@claude don't silently answer the question", lead="claude", settings=settings))
            assert "pending questions" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"]
            bad = dict(type="answer_question", run_id=effort_id, message_id=question_message["id"], request_id=request["id"], answers=[], settings=settings)
            bridge.send(bad)
            assert "each question" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"]
            bad["request_id"] = "00000000-0000-0000-0000-000000000000"
            bridge.send(bad)
            assert "changed" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"]
            assert len(calls()) == before + 1
        answers = [dict(question_id="q1", option_ids=["o2"], text="", skipped=False),
                   dict(question_id="q2", option_ids=["o1", "o2"], text="", skipped=False),
                   dict(question_id="q3", option_ids=[], text="Keep @claude and @codex as ordinary answer text.", skipped=False)]
        if provider == "kiro":
            answers = [dict(question_id=q["id"], option_ids=[], text="", skipped=True) for q in request["questions"]]
        answered = bridge.answer(waiting, question_message, answers)
        assert answered["status"] == "Completed" and calls()[-1]["provider"] == provider and calls()[-1]["session"] == session
        assert len(calls()) == before + 2 and answered["conversation"]["messages"][-2]["kind"] == "answer"
        assert answered["conversation"].get("pending_exchange") is None
        stored_request = next(m for m in answered["conversation"]["messages"] if m["id"] == question_message["id"])["question_request"]
        assert stored_request["answers"] == answers and "USER ANSWERS TO YOUR QUESTIONS" in calls()[-1]["prompt"]
        bridge.send(dict(type="answer_question", run_id=effort_id, message_id=question_message["id"], request_id=request["id"], answers=answers, settings=settings))
        assert "already been answered" in bridge.until(lambda e: e["type"] == "notice" and e["error"])["message"] and len(calls()) == before + 2
    # Native Claude AskUserQuestion input is converted into the same card after an unanswered turn.
    waiting = bridge.chat("@claude NATIVE_QUESTION", effort_id)
    assert waiting["status"] == "WaitingForUser"
    native = waiting["conversation"]["messages"][-1]
    native_session = calls()[-1]["session"]
    answered = bridge.answer(waiting, native, answers)
    assert answered["status"] == "Completed" and calls()[-1]["session"] == native_session
    # A review paused for input resumes the reviewer, remaining teammates, and original lead.
    before = len(calls())
    waiting = bridge.chat("ASK_HUMAN_REVIEW: discuss this as a team.", effort_id, lead="claude", team_discussion=True)
    assert waiting["status"] == "WaitingForUser" and [c["provider"] for c in calls()[before:]] == ["claude", "codex"]
    peer = waiting["conversation"]["messages"][-1]
    lead_session, peer_session = calls()[before]["session"], calls()[-1]["session"]
    bridge.close()
    bridge = Bridge()
    continued = bridge.answer(waiting, peer, answers)
    assert continued["status"] == "Completed" and [c["provider"] for c in calls()[before:]] == ["claude", "codex", "codex", "antigravity", "qoder", "deep_seek", "kiro", "claude"]
    assert calls()[before + 2]["session"] == peer_session and calls()[-1]["session"] == lead_session
    assert continued["conversation"]["lead"] == "claude" and "human's answers" in calls()[-1]["prompt"]
    # The same pause works inside a direct teammate request and returns the result to its sender.
    before = len(calls())
    waiting = bridge.chat("@claude ASK_HUMAN_TEAMMATE", effort_id)
    assert waiting["status"] == "WaitingForUser" and [c["provider"] for c in calls()[before:]] == ["claude", "codex"]
    continued = bridge.answer(waiting, waiting["conversation"]["messages"][-1], answers)
    assert continued["status"] == "Completed" and [c["provider"] for c in calls()[before:]] == ["claude", "codex", "codex", "claude"]
    before = len(calls())
    waiting = bridge.chat("@claude ASK_HUMAN_WITH_DISPATCH", effort_id)
    assert waiting["status"] == "WaitingForUser" and len(calls()) == before + 1
    continued = bridge.answer(waiting, waiting["conversation"]["messages"][-1], answers)
    assert continued["status"] == "Completed" and [c["provider"] for c in calls()[before:]] == ["claude", "claude", "codex", "claude"]
    example = bridge.chat("@claude QUESTION_EXAMPLE", effort_id)
    assert example["status"] == "Completed" and example["conversation"]["messages"][-1].get("question_request") is None
    before = len(calls())
    bounded = bridge.chat("LOOP to test the exchange limit.")
    assert len(calls()) == before + 8, "Agent exchange was unbounded"
    assert bounded["conversation"]["messages"][-1]["kind"] == "system" and "eight turns" in bounded["conversation"]["messages"][-1]["text"]
    bridge.close()
    assert config_path.read_bytes() == config_before, "Auto routing rewrote the real-style Claude configuration"
    assert all(not Path(path).exists() for call in calls() for path in call["private"]), "Private settings survived a completed or cancelled invocation"
    saved = (DATA / "settings.json").read_text() + (DATA / "runs.json").read_text()
    assert all(key not in saved and key not in calls_path.read_text() for key in (SECRET, KIRO_SECRET))
    assert len(json.loads((DATA / "runs.json").read_text())) == 7, "Follow-ups created separate tasks"
    print("Chat smoke passed: distinct new-chat coworkers and native sessions, saved coworker resumption, structured questions for all six providers, choices/free text/skip, restart recovery, teammate exchanges, effort, models, mentions, cancellation, credentials and export")
finally:
    if bridge.child.poll() is None:
        bridge.child.kill()
        bridge.child.wait()
