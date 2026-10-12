#!/usr/bin/env python3
"""Exercise the SwiftUI/Rust JSON contract with local CLI fixtures, without model calls."""
import json
import os
import queue
import subprocess
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AREA = ROOT / "target" / "bridge-smoke"
AREA.mkdir(parents=True, exist_ok=True)
SECOND = AREA / "second project"
SECOND.mkdir(exist_ok=True)
CONFIG = AREA / "claude-config"
CONFIG.mkdir(exist_ok=True)
config_path = CONFIG / "settings.json"
config_path.write_text(json.dumps({"permissions":{"deny":["Read(.env)"]}, "env": {
    "ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic", "ANTHROPIC_MODEL":"deepseek-flash",
    "ANTHROPIC_AUTH_TOKEN":"fixture-config-deepseek-key"}}))
config_path.chmod(0o600)
config_before = config_path.read_bytes()
child_env = {key:value for key,value in os.environ.items() if not key.startswith("ANTHROPIC_") and key not in ["DEEPSEEK_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]}
child_env["CLAUDE_CONFIG_DIR"] = str(CONFIG)
FIXTURE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
if "--help" in sys.argv:
    print("--print --output-format --include-partial-messages --permission-mode --json --sandbox")
    raise SystemExit
name = pathlib.Path(sys.argv[0]).name
prompt = sys.stdin.read() if "codex" in name else sys.argv[-1]
pathlib.Path(name + ".prompt").write_text(prompt)
if "claude" in name:
    env = dict(os.environ)
    configured = pathlib.Path(env.get("CLAUDE_CONFIG_DIR", "")) / "settings.json"
    if configured.is_file() and "target" in configured.parts:
        env.update(json.loads(configured.read_text()).get("env", {}))
    overrides = []
    for index, arg in enumerate(sys.argv[:-1]):
        if arg == "--settings":
            overrides.append(sys.argv[index + 1])
            env.update(json.loads(pathlib.Path(sys.argv[index + 1]).read_text()).get("env", {}))
    pathlib.Path(name + ".routing.json").write_text(json.dumps({
        "endpoint":env.get("ANTHROPIC_BASE_URL"), "model":env.get("ANTHROPIC_MODEL"),
        "auth_token_empty":not env.get("ANTHROPIC_AUTH_TOKEN"),
        "native_fixture_key":env.get("ANTHROPIC_API_KEY") == "fixture-claude-session-key",
        "custom_fixture_key":env.get("ANTHROPIC_AUTH_TOKEN") == "fixture-custom-session-key",
        "temporary_settings":overrides}))
if "slow fixture" in prompt:
    time.sleep(30)
else:
    time.sleep(0.1)
text = "Fixture response from " + name + " 🦀"
if "codex" in name:
    print(json.dumps({"type":"item.completed","item":{"id":"r1","type":"reasoning","text":"Fixture thinking for " + name}}), flush=True)
    print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":text}}), flush=True)
    print(json.dumps({"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}), flush=True)
else:
    for _ in range(100): print(json.dumps({"type":"system","subtype":"thinking_tokens"}), flush=True)
    print(json.dumps({"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Fixture thinking for " + name}]}}), flush=True)
    print(json.dumps({"type":"result","result":text,"is_error":False,"session_id":"fixture-session"}), flush=True)
'''
providers = ["claude", "codex", "antigravity", "qoder", "deep_seek"]
agents = []
for provider in providers:
    executable = AREA / ("fixture-" + provider)
    executable.write_text(FIXTURE)
    executable.chmod(0o755)
    agents.append(dict(provider=provider, selected=provider in ["claude", "codex"], executable=str(executable), model="", extra_args="[]", allow_edits=False))
settings = dict(workspace=str(AREA), agents=agents, workflow="Independent", timeout_seconds=30,
                deepseek_base_url="https://api.deepseek.com", deepseek_mode="ClaudeCode", deepseek_use_cli_config=False)
if "--prepare-swift" in sys.argv:
    destination = ROOT / "target" / "swift-smoke"
    destination.mkdir(exist_ok=True)
    (destination / "settings.json").write_text(json.dumps(dict(settings, workspace_folders=[str(AREA), str(SECOND)], claude_config_dir=str(CONFIG))))
    (destination / "runs.json").write_text("[]")
    print(destination)
    raise SystemExit

# Seed before discovery so every executable probe also uses the local fixture.
(AREA / "settings.json").write_text(json.dumps(settings))
(AREA / "runs.json").write_text("[]")
child = subprocess.Popen([str(ROOT / "target/debug/agent-conductor"), "--bridge", "--data-dir", str(AREA)],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=child_env)
events = queue.Queue()
def read_events():
    for line in child.stdout:
        events.put(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()
def send(command):
    child.stdin.write(json.dumps(command) + "\n")
    child.stdin.flush()
def until(predicate):
    while True:
        event = events.get(timeout=15)
        assert all(secret not in json.dumps(event) for secret in ["fixture-private-key", "fixture-config-deepseek-key", "fixture-claude-session-key", "fixture-custom-session-key"]), "A credential leaked into an event"
        if predicate(event): return event
try:
    initial = until(lambda e: e["type"] == "state")
    assert initial["protocol_version"] == 1 and initial["runs"] == []
    assert initial["settings"]["workspace_folders"] == [str(AREA)], "Legacy workspace was not migrated"
    assert initial["claude_config"]["backend"] == "DeepSeek"
    assert initial["claude_config"]["config_dir"] == str(CONFIG)
    until(lambda e: e["type"] == "agents_updated")
    send(dict(type="session_key", key="fixture-private-key"))
    literal = "Literal task with $() and quotes ' \" 🦀"
    send(dict(type="start", prompt=literal, settings=settings))
    run = until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Completed")["run"]
    assert len(run["stages"]) == 2 and all(s["output"].startswith("Fixture response") for s in run["stages"])
    assert all(s["reasoning"].startswith("Fixture thinking for ") for s in run["stages"])
    assert all(sum(log["text"] == "Thinking…" for log in s["logs"]) == 1 for s in run["stages"])
    assert (AREA / "fixture-claude.prompt").read_text() == literal
    send(dict(type="get_run", run_id=run["id"]))
    assert until(lambda e: e["type"] == "run_detail")["run"]["prompt"] == literal
    send(dict(type="export", run_id=run["id"]))
    until(lambda e: e["type"] == "notice" and not e["error"])
    assert (AREA / "exports" / (run["id"] + ".md")).exists()
    settings["workspace_folders"] = [str(AREA), str(SECOND), str(AREA)]
    settings["workspace"] = str(SECOND)
    settings["workflow"] = "Collaborate"
    send(dict(type="start", prompt="Handoff fixture", settings=settings))
    handoff = until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Completed")["run"]
    assert handoff["workspace"] == str(SECOND)
    assert "Fixture response from fixture-claude" in (SECOND / "fixture-codex.prompt").read_text()
    assert "Fixture thinking for " not in (SECOND / "fixture-codex.prompt").read_text()
    assert all(s["reasoning"].startswith("Fixture thinking for ") for s in handoff["stages"])
    settings["workflow"] = "Independent"
    send(dict(type="start", prompt="slow fixture", settings=settings))
    slow = until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Running")["run"]
    settings["workspace"] = str(AREA)
    send(dict(type="update_settings", settings=settings))
    send(dict(type="cancel", run_id=slow["id"]))
    cancelled = until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Cancelled")["run"]
    assert all(s["status"] == "Cancelled" for s in cancelled["stages"])
    assert cancelled["workspace"] == str(SECOND), "Switching folders moved an active run"
    for agent in settings["agents"]:
        agent["selected"] = agent["provider"] == "claude"
    for mode, key, endpoint, model in [
        ("Anthropic", "fixture-claude-session-key", "https://api.anthropic.com", "sonnet"),
        ("DeepSeek", "", "https://api.deepseek.com/anthropic", "deepseek-flash"),
        ("Custom", "fixture-custom-session-key", "https://gateway.example/anthropic", "fixture-model"),
    ]:
        settings["claude_backend"] = mode
        settings["claude_base_url"] = "https://gateway.example/anthropic"
        settings["agents"][0]["model"] = "fixture-model" if mode == "Custom" else ""
        send(dict(type="session_key", key="", claude_key=key))
        send(dict(type="update_settings", settings=settings))
        send(dict(type="discover"))
        until(lambda e: e["type"] == "agents_updated" and next(a for a in e["agents"] if a["provider"] == "claude")["status"] == "ready")
        send(dict(type="start", prompt="Routing fixture " + mode, settings=settings))
        until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Completed")
        routing = json.loads((AREA / "fixture-claude.routing.json").read_text())
        assert routing["endpoint"] == endpoint and routing["model"] == model
        if mode == "Anthropic": assert routing["auth_token_empty"] and routing["native_fixture_key"]
        if mode == "Custom": assert routing["custom_fixture_key"]
        assert all(not Path(path).exists() for path in routing["temporary_settings"]), "Temporary credential file survived its run"
    assert config_path.read_bytes() == config_before, "Provider overrides changed the original Claude configuration"
    send(dict(type="shutdown"))
    child.stdin.close()
    assert child.wait(timeout=10) == 0
    saved = (AREA / "settings.json").read_text() + (AREA / "runs.json").read_text()
    assert all(secret not in saved for secret in ["fixture-private-key", "fixture-config-deepseek-key", "fixture-claude-session-key", "fixture-custom-session-key"])
    assert len(json.loads((AREA / "runs.json").read_text())) == 6
    saved_settings = json.loads((AREA / "settings.json").read_text())
    assert saved_settings["workspace_folders"] == [str(AREA), str(SECOND)]
    assert saved_settings["workspace"] == str(AREA)
    restarted = subprocess.Popen([str(ROOT / "target/debug/agent-conductor"), "--bridge", "--data-dir", str(AREA)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=child_env)
    try:
        restored = json.loads(restarted.stdout.readline())
        assert restored["settings"]["workspace_folders"] == [str(AREA), str(SECOND)]
        assert restored["settings"]["workspace"] == str(AREA)
        restarted.communicate(json.dumps(dict(type="shutdown")) + "\n", timeout=10)
        assert restarted.returncode == 0
    finally:
        if restarted.poll() is None:
            restarted.kill()
            restarted.wait()
    print("Bridge smoke passed: Claude/DeepSeek/custom routing, unchanged CLI configuration, private credential files, folders, parallel runs, handoff, cancellation, export")
finally:
    if child.poll() is None:
        child.kill()
        child.wait()
