#!/usr/bin/env python3
"""Saved Inbox/history contract, using only temporary files and a local fake CLI."""
import json
import os
import queue
import subprocess
import threading
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AREA = ROOT / "target" / "inbox-smoke" / str(uuid.uuid4())
STATE = AREA / "state"
WORKSPACE = AREA / "project"
STATE.mkdir(parents=True)
WORKSPACE.mkdir()
(WORKSPACE / "source.rs").write_text("// Keep this workspace file.\n")
subprocess.run(["git", "init", "--quiet", str(WORKSPACE)], check=True)
CLI = AREA / "fixture-codex"
CLI.write_text('''#!/usr/bin/env python3
import json, pathlib, sys, time, uuid
if "--help" in sys.argv:
    print("exec --json --sandbox --print --output-format --include-partial-messages")
else:
    prompt = sys.stdin.read()
    if "REVIEW_FIXTURE" in prompt:
        pathlib.Path("source.rs").write_text("// Local fixture change " + str(uuid.uuid4()) + "\\n")
    else:
        time.sleep(30)
    print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":"Done"}}), flush=True)
    print(json.dumps({"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}), flush=True)
''')
CLI.chmod(0o755)
config = AREA / "claude-config"
config.mkdir()
settings = dict(workspace=str(WORKSPACE), workspace_folders=[str(WORKSPACE)], workflow="Conversation",
                claude_config_dir=str(config), timeout_seconds=60,
                agents=[dict(provider=p, executable=str(CLI), model="", extra_args="[]", allow_edits=False,
                             selected=p == "codex") for p in ["claude", "codex", "antigravity", "qoder", "deep_seek", "kiro"]])
(STATE / "settings.json").write_text(json.dumps(settings))

def uid():
    return str(uuid.uuid4())

def message(author, question=False, approval=False):
    m = dict(id=uid(), at="2026-10-12T12:00:00Z", kind="assistant", author="codex", author_id=author,
             to=[], recipient_ids=[], text="Saved reply", status="Completed", model="", session_id=None,
             logs=[], usage=dict(input_tokens=0, output_tokens=0, cost_usd=None), error=None)
    if question:
        m["status"] = "WaitingForUser"
        m["question_request"] = dict(id=uid(), questions=[dict(id="q1", header="Scope", question="Which scope?",
                                                             options=[], multi_select=False)], answers=None)
    if approval:
        m["status"] = "WaitingForUser"
        m["approval_request"] = dict(id=uid(), summary="Run cargo test", argv=["cargo", "test"], decision=None, result=None)
    return m

def chat(name, with_questions):
    owner = uid()
    worker = dict(id=owner, provider="codex", name=name, mention=name.lower(), role="builder", model="",
                  effort="default", attention="ready_for_review", waiting_for=None)
    messages = [message(owner)]
    if with_questions:
        messages += [message(owner, question=True), message(owner, approval=True)]
    return dict(id=uid(), prompt=f"{name}'s saved chat", workspace=str(WORKSPACE), workflow="Conversation",
                created_at="2026-10-12T12:00:00Z", finished_at="2026-10-12T12:01:00Z",
                status="WaitingForUser" if with_questions else "Completed", stages=[],
                conversation=dict(members=["codex"], lead="codex", lead_id=owner, messages=messages, sessions=[],
                                  coworkers=[worker], mailbox=[]))

runs = [chat("Olivia", True), chat("Isla", False)]
(STATE / "runs.json").write_text(json.dumps(runs))
env = {k: v for k, v in os.environ.items() if not k.startswith("ANTHROPIC_") and k not in ["DEEPSEEK_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]}
env["CLAUDE_CONFIG_DIR"] = str(config)

class Bridge:
    def __init__(self):
        self.child = subprocess.Popen([str(ROOT / "target/debug/agent-conductor"), "--bridge", "--data-dir", str(STATE)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.events = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()
    def read(self):
        for line in self.child.stdout:
            self.events.put(json.loads(line))
    def send(self, **command):
        self.child.stdin.write(json.dumps(command) + "\n")
        self.child.stdin.flush()
    def until(self, predicate):
        while True:
            e = self.events.get(timeout=15)
            if predicate(e):
                return e
    def close(self):
        self.send(type="shutdown")
        self.child.wait(timeout=8)
        assert self.child.returncode == 0, self.child.stderr.read()
    def detail(self, run_id):
        self.send(type="get_run", run_id=run_id)
        return self.until(lambda e: e["type"] == "run_detail" and e["run"]["id"] == run_id)["run"]
    def dismiss(self, pairs):
        self.send(type="dismiss_attention", items=[dict(run_id=rid, id=item["id"], revision=item["revision"]) for rid, item in pairs])
        return self.until(lambda e: e["type"] == "attention_dismissed")

bridge = Bridge()
try:
    initial = bridge.until(lambda e: e["type"] == "state")
    assert [len(r["attention"]) for r in initial["runs"]] == [3, 1]
    # Save matching summary/detail fixtures for the Swift store and native UI checks.
    (AREA / "initial-state.json").write_text(json.dumps(initial))
    (AREA / "initial-runs.json").write_text(json.dumps([bridge.detail(r["id"]) for r in runs]))
    review = next(item for item in initial["runs"][0]["attention"] if item["kind"] == "review")
    assert len(bridge.dismiss([(runs[0]["id"], review)])["items"]) == 1
    detail = bridge.detail(runs[0]["id"])
    assert detail["conversation"]["messages"][1]["question_request"]["answers"] is None
    assert detail["conversation"]["messages"][2]["approval_request"]["decision"] is None
    remaining = [(r["id"], i) for r in initial["runs"] for i in r["attention"] if i["id"] != review["id"]]
    assert len(bridge.dismiss(remaining)["items"]) == 3
    saved = json.loads((STATE / "runs.json").read_text())
    assert [len(r["dismissed_attention"]) for r in saved] == [3, 1], "Acknowledgement must follow a durable save"
    bridge.close()
    bridge = Bridge()
    reopened = bridge.until(lambda e: e["type"] == "state")
    assert all(not r["attention"] for r in reopened["runs"]), "Cleared items came back after restarting"
    bridge.close()
    # A new review generation and a new question must survive the previous clear.
    saved = json.loads((STATE / "runs.json").read_text())
    worker = saved[0]["conversation"]["coworkers"][0]
    worker["review_id"] = uid()
    saved[0]["conversation"]["messages"].append(message(worker["id"], question=True))
    (STATE / "runs.json").write_text(json.dumps(saved))
    bridge = Bridge()
    fresh = bridge.until(lambda e: e["type"] == "state")
    assert len(fresh["runs"][0]["attention"]) == 2
    assert not bridge.dismiss([(runs[0]["id"], review)])["items"], "An old acknowledgement hid a new review"
    bridge.send(type="delete_run", run_id=runs[0]["id"])
    bridge.until(lambda e: e["type"] == "run_deleted" and e["run_id"] == runs[0]["id"])
    assert len(json.loads((STATE / "runs.json").read_text())) == 1
    assert (WORKSPACE / "source.rs").read_text() == "// Keep this workspace file.\n"
    assert bridge.detail(runs[1]["id"])["prompt"] == runs[1]["prompt"]
    bridge.close()
    bridge = Bridge()
    reopened = bridge.until(lambda e: e["type"] == "state")
    assert [r["id"] for r in reopened["runs"]] == [runs[1]["id"]], "Deleted chat returned after restarting"
    bridge.until(lambda e: e["type"] == "agents_updated")
    live_settings = dict(settings, workflow="Independent")
    bridge.send(type="start", prompt="Local slow fixture", settings=live_settings)
    active = bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Running")["run"]
    bridge.send(type="delete_run", run_id=active["id"])
    rejection = bridge.until(lambda e: e["type"] == "notice" and e["error"])
    assert "Stop this chat" in rejection["message"], rejection
    bridge.send(type="cancel", run_id=active["id"])
    bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["id"] == active["id"] and e["run"]["status"] == "Cancelled")
    bridge.send(type="delete_run", run_id=active["id"])
    bridge.until(lambda e: e["type"] == "run_deleted" and e["run_id"] == active["id"])
    # Real mailbox turns must generate distinct review notifications for one coworker.
    worker = dict(id=uid(), provider="codex", name="Maya", mention="maya", role="builder", model="", effort="default")
    team_settings = dict(settings)
    team_settings["agents"] = [dict(a, allow_edits=True) if a["provider"] == "codex" else a for a in settings["agents"]]
    bridge.send(type="team_chat", run_id=None, prompt="REVIEW_FIXTURE first edit", lead_id=worker["id"],
                settings=team_settings, coworkers=[worker], isolation={"mode": "shared"})
    edited = bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Completed" and e["run"]["prompt"] == "REVIEW_FIXTURE first edit")["run"]
    reviewer = edited["conversation"]["coworkers"][0]
    assert reviewer["attention"] == "ready_for_review"
    old_revision = reviewer["review_id"]
    assert old_revision == edited["conversation"]["messages"][-1]["id"]
    bridge.dismiss([(edited["id"], dict(id=worker["id"], revision=old_revision))])
    bridge.send(type="team_chat", run_id=edited["id"], prompt="REVIEW_FIXTURE second edit", lead_id=worker["id"],
                settings=team_settings, coworkers=[])
    edited_again = bridge.until(lambda e: e["type"] == "run_updated" and e["run"]["id"] == edited["id"] and e["run"]["status"] == "Completed" and len(e["run"]["conversation"]["messages"]) >= 4)["run"]
    assert edited_again["conversation"]["coworkers"][0]["review_id"] != old_revision
    bridge.close()
    bridge = Bridge()
    reopened = bridge.until(lambda e: e["type"] == "state")
    assert len(next(r for r in reopened["runs"] if r["id"] == edited["id"])["attention"]) == 1
    bridge.close()
    print("Inbox/history bridge passed: per-item and bulk dismiss, restart persistence, preserved questions/approvals, fresh reviews, deletion, workspace retention and live-run protection.")
    print(AREA)
finally:
    if bridge.child.poll() is None:
        bridge.child.kill()
        bridge.child.wait()
