#!/usr/bin/env python3
"""Real JSON bridge, fixture CLIs and temporary Git repo; no model or remote calls."""
import copy
import json
import os
import queue
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AREA = ROOT / "target" / "team-smoke"
AREA.mkdir(parents=True, exist_ok=True)
DATA = AREA / str(uuid.uuid4())
PROJECT = DATA / "project"
PROJECT.mkdir(parents=True)
CALLS = DATA / "calls.jsonl"
CALLS.write_text("")
for command in (["git", "init"], ["git", "config", "user.name", "Fixture"], ["git", "config", "user.email", "fixture@example.invalid"]):
    subprocess.run(command, cwd=PROJECT, check=True, capture_output=True)
(PROJECT / "tracked.txt").write_text("original\n")
for command in (["git", "add", "."], ["git", "commit", "-m", "base"]):
    subprocess.run(command, cwd=PROJECT, check=True, capture_output=True)

fixture = r'''#!/usr/bin/env python3
import json, os, pathlib, re, sys, time, uuid
if "--help" in sys.argv:
    print("--print --output-format --include-partial-messages --permission-mode --json --sandbox --resume --effort --reasoning-effort")
    raise SystemExit
provider = pathlib.Path(sys.argv[0]).name.split("-")[-1]
args = sys.argv[1:]
prompt = sys.stdin.read() if provider == "codex" else args[-1]
handle = re.search(r"You are .*?\(@([a-z0-9_-]+)\)", prompt)[1]
matches = list(re.finditer(r"\nCURRENT (\w+)(?: FROM [^\n]+)?\n", prompt))
assert matches, prompt
kind = matches[-1][1]
body = prompt[matches[-1].end():]
session = next((args[i+1] for i, a in enumerate(args[:-1]) if a in ("--resume", "resume")), None)
session = session or provider + "-" + str(uuid.uuid4())
with open(os.environ["TEAM_FIXTURE_CALLS"], "a") as f:
    f.write(json.dumps(dict(handle=handle, provider=provider, kind=kind, body=body, session=session, argv=args, cwd=os.getcwd(), pid=os.getpid())) + "\n")
if provider == "codex": print(json.dumps(dict(type="thread.started", thread_id=session)), flush=True)
else: print(json.dumps(dict(type="system", subtype="init", session_id=session)), flush=True)
if "SLOW" in body: time.sleep(30)
if kind == "QuestionAnswer":
    request = json.loads(re.search(r"\nDELEGATED QUESTION REQUEST\n([^\n]+)", prompt)[1])
    questions = " ".join(q["question"] for q in request["questions"])
    if "PEER_DELAY" in questions: time.sleep(30)
    if "PEER_NEEDS_INPUT" in questions and "USER ANSWERS" not in body:
        answer = '<conductor-ask>\n' + json.dumps({"questions":[{"question":"What workspace fact should I use?","options":[{"label":"Verified scope"}]}]}) + '\n</conductor-ask>'
    else:
        answers = [dict(question_id=q["id"], option_ids=[q["options"][0]["id"]] if q["options"] else [], text="Verified by " + handle + "; @maya is ordinary context", skipped=False) for q in request["questions"]]
        if handle == "alex" and "PEER_BAD" in questions: answers[0]["option_ids"] = ["invalid-option"]
        answer = 'I checked the shared task.\n<conductor-answer>\n' + json.dumps(dict(request_id=request["request_id"], answers=answers)) + '\n</conductor-answer>'
elif "USER ANSWERS" in body or "TEAMMATE ANSWERS" in body or "human declined" in body or "Actual result:" in body:
    answer = "I continued using the human's decision in my own session."
elif "ASK_QUESTION" in body:
    marker = next((m for m in ["PEER_BAD", "PEER_NEEDS_INPUT", "PEER_DELAY", "PEER_FOUR"] if m in body), "")
    question_items = [{"question":"Which scope for item " + str(i + 1) + "? " + marker,"options":[{"label":"Small"},{"label":"Full"}]} for i in range(4 if marker == "PEER_FOUR" else 1)]
    answer = 'Need scope.\n<conductor-ask>\n' + json.dumps({"questions":question_items}) + '\n</conductor-ask>'
elif "ASK_APPROVAL" in body:
    command = [sys.executable, "-c", "from pathlib import Path; Path('approved.txt').write_text('approved')"]
    answer = 'Need approval.\n<conductor-approval>\n' + json.dumps(dict(summary="Create the fixture marker", argv=command)) + '\n</conductor-approval>'
elif "LOOP" in body:
    to = "noah" if handle == "alex" else "alex"
    answer = '<conductor-send to="' + to + '">LOOP ' + str(uuid.uuid4()) + '</conductor-send>'
elif kind == "User" and "BUILD_CHANGE" in body:
    pathlib.Path("tracked.txt").write_text("built by " + handle + "\n")
    answer = 'Implemented.\n<conductor-send to="noah">Review my change.</conductor-send>'
elif kind == "DiscussionLead": answer = "Initial finding for " + body
elif kind == "DiscussionReview": answer = "Review by " + handle + " for " + body
else:
    answer = "Finding from " + handle + " in my own session."
if provider == "codex":
    print(json.dumps({"type":"item.started","item":{"id":"r1","type":"reasoning","text":""}}), flush=True)
    print(json.dumps({"type":"item.updated","item":{"id":"r1","type":"reasoning","text":"Fixture thinking for "}}), flush=True)
    print(json.dumps({"type":"item.completed","item":{"id":"r1","type":"reasoning","text":"Fixture thinking for " + handle}}), flush=True)
    print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":answer}}), flush=True)
    print(json.dumps({"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}), flush=True)
else:
    for _ in range(100): print(json.dumps({"type":"system","subtype":"thinking_tokens"}), flush=True)
    print(json.dumps({"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}), flush=True)
    print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Fixture thinking for " + handle}}}), flush=True)
    print(json.dumps({"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"Fixture thinking for " + handle},{"type":"text","text":answer}]}}), flush=True)
    print(json.dumps({"type":"result","subtype":"success","result":answer,"session_id":session,"is_error":False}), flush=True)
'''
paths = {}
for provider in ("claude", "codex"):
    path = DATA / ("fixture-" + provider)
    path.write_text(fixture)
    path.chmod(0o755)
    paths[provider] = str(path)

def coworker(name, provider, role, model="", effort="default"):
    return dict(id=str(uuid.uuid4()), name=name, mention=name.lower(), provider=provider, role=role, model=model, effort=effort, attention="idle", waiting_for=None)

TEAM = [coworker("Maya", "claude", "architect"), coworker("Alex", "codex", "builder", "fixture-a", "low"), coworker("Noah", "codex", "reviewer", "fixture-b", "high")]
CONFIG = DATA / "claude-config"
CONFIG.mkdir()

class Bridge:
    def __init__(self):
        env = dict(os.environ, TEAM_FIXTURE_CALLS=str(CALLS), CLAUDE_CONFIG_DIR=str(CONFIG), CODEX_HOME=str(DATA / "codex"))
        self.proc = subprocess.Popen([str(ROOT / "target/debug/agent-conductor"), "--bridge", "--data-dir", str(DATA / "state")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.events = queue.Queue()
        self.latest = {}
        threading.Thread(target=self.read, daemon=True).start()
        state = self.wait(lambda e: e["type"] == "state")
        self.settings = state["settings"]
    def read(self):
        for line in self.proc.stdout:
            self.events.put(json.loads(line))
    def send(self, **command):
        self.proc.stdin.write(json.dumps(command) + "\n")
        self.proc.stdin.flush()
    def wait(self, predicate, timeout=15):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try: event = self.events.get(timeout=max(.1, end - time.monotonic()))
            except queue.Empty: break
            if event["type"] in ("run_updated", "run_detail"):
                self.latest[event["run"]["id"]] = event["run"]
            if predicate(event): return event
            if event["type"] == "notice" and event["error"]:
                raise AssertionError(event["message"])
        raise AssertionError("Timed out waiting for bridge; exit=" + str(self.proc.poll()))
    def finish(self, run_id=None, status="Completed"):
        event = self.wait(lambda e: e["type"] == "run_updated" and (run_id is None or e["run"]["id"] == run_id) and e["run"]["status"] in ("Completed", "Failed", "Cancelled", "Interrupted", "WaitingForUser"))
        run = event["run"]
        assert run["status"] == status, [(m["status"], m.get("error"), m["text"]) for m in run["conversation"]["messages"][-4:]]
        return run
    def chat(self, text, run_id=None, lead=None, isolation=None, team=None, discussion=False, target=None):
        self.send(type="team_chat", run_id=run_id, prompt=text, lead_id=lead or TEAM[1]["id"], target_id=target, settings=self.settings, coworkers=team or TEAM, discussion=discussion, isolation=isolation or {"mode":"shared"})
        if run_id is not None and self.latest.get(run_id, {}).get("status") in ("Queued", "Running"):
            return run_id
        return self.wait(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Queued" and (run_id is None or e["run"]["id"] == run_id))["run"]["id"]
    def close(self):
        self.send(type="shutdown")
        self.proc.wait(timeout=8)
        assert self.proc.returncode == 0, self.proc.stderr.read()

b = Bridge()
settings = b.settings
settings.update(workspace=str(PROJECT), workspace_folders=[str(PROJECT)], workflow="Conversation", claude_backend="Anthropic", claude_config_dir=str(CONFIG))
for agent in settings["agents"]:
    agent["executable"] = paths.get(agent["provider"], "")
    agent["selected"] = agent["provider"] in paths
    agent["allow_edits"] = True
b.send(type="update_settings", settings=settings)
b.send(type="discover")
b.wait(lambda e: e["type"] == "agents_updated" and all(a["status"] == "ready" for a in e["agents"] if a["provider"] in paths))
rid = b.chat("BUILD_CHANGE", isolation={"mode":"worktree"})
run = b.finish(rid)
assert run["workspace"] != str(PROJECT) and run["workspace_info"]["isolated"]
assert (PROJECT / "tracked.txt").read_text() == "original\n"
assert Path(run["workspace"], "tracked.txt").read_text() == "built by alex\n"
answers = [m for m in run["conversation"]["messages"] if m["kind"] == "assistant"]
assert [m["author_id"] for m in answers] == [TEAM[1]["id"], TEAM[2]["id"], TEAM[1]["id"]]
assert answers[0]["session_id"] == answers[2]["session_id"] != answers[1]["session_id"]
assert [m["model"] for m in answers] == ["fixture-a", "fixture-b", "fixture-a"]
assert [m["effort"] for m in answers] == ["low", "high", "low"]
assert [m["reasoning"] for m in answers] == ["Fixture thinking for alex", "Fixture thinking for noah", "Fixture thinking for alex"]
assert all(sum(log["text"] == "Thinking…" for log in m["logs"]) == 1 for m in answers)
assert all("thinking_tokens" not in log["text"] for m in answers for log in m["logs"])
assert all("Fixture thinking for " not in json.loads(line)["body"] for line in CALLS.read_text().splitlines())
assert run["changes"]["files"][0]["owner_id"] == TEAM[1]["id"]
assert all(m["state"] == "completed" for m in run["conversation"]["mailbox"])
assert any(m["kind"] == "reply" and m["reply_to"] for m in run["conversation"]["mailbox"])
alex_session, noah_session = answers[0]["session_id"], answers[1]["session_id"]

# Editing one worker's model never changes the other worker on the same connection.
edited = dict(TEAM[2], model="fixture-c", effort="low", name="Noah", mention="noah")
b.send(type="update_coworker", run_id=rid, coworker=edited)
b.wait(lambda e: e["type"] == "run_updated" and any(c["id"] == edited["id"] and c["model"] == "fixture-c" for c in e["run"]["conversation"]["coworkers"]))
b.chat("@noah continue", rid)
run = b.finish(rid)
assert run["conversation"]["messages"][-1]["session_id"] != noah_session
b.chat("@alex continue", rid)
run = b.finish(rid)
assert run["conversation"]["messages"][-1]["session_id"] == alex_session

# File feedback is explicitly addressed; handles in the comment remain context.
before = len([m for m in run["conversation"]["messages"] if m["kind"] == "assistant"])
b.chat("Review feedback: @alex mentioned this; @codex is ambiguous context.", rid, target=TEAM[2]["id"])
run = b.finish(rid)
assert len([m for m in run["conversation"]["messages"] if m["kind"] == "assistant"]) == before + 1
assert run["conversation"]["messages"][-1]["author_id"] == TEAM[2]["id"]

# Pending questions survive restart and replies containing another handle stay with the owner.
b.chat("@noah ASK_QUESTION", rid)
run = b.finish(rid, "WaitingForUser")
question = run["conversation"]["messages"][-1]
owner_session = question["session_id"]
b.close()
b = Bridge()
b.send(type="discover")
b.wait(lambda e: e["type"] == "agents_updated" and all(a["status"] == "ready" for a in e["agents"] if a["provider"] in paths))
b.send(type="get_run", run_id=rid)
saved = b.wait(lambda e: e["type"] == "run_detail")["run"]
assert saved["status"] == "WaitingForUser" and saved["conversation"]["coworkers"][2]["id"] == TEAM[2]["id"]
q = question["question_request"]
assert saved["conversation"]["messages"][-1]["question_request"]["id"] == q["id"]
b.send(type="team_answer", run_id=rid, message_id=question["id"], request_id=q["id"], answers=[dict(question_id=q["questions"][0]["id"], option_ids=[q["questions"][0]["options"][0]["id"]], text="@alex is ordinary answer text", skipped=False)], settings=b.settings)
run = b.finish(rid)
assert run["conversation"]["messages"][-1]["author_id"] == TEAM[2]["id"]
assert run["conversation"]["messages"][-1]["session_id"] == owner_session

def send_human_answers(message):
    request = message["question_request"]
    b.send(type="team_answer", run_id=rid, message_id=message["id"], request_id=request["id"],
           answers=[dict(question_id=q["id"], option_ids=[q["options"][0]["id"]] if q["options"] else [], text="Human fact", skipped=False) for q in request["questions"]], settings=b.settings)

def delegate(message, responder=TEAM[1]):
    b.send(type="delegate_question", run_id=rid, message_id=message["id"], request_id=message["question_request"]["id"], coworker_id=responder["id"], settings=b.settings)

# Same-connection coworkers answer in separate native sessions; quoted handles do not dispatch.
b.chat("@noah ASK_QUESTION PEER_FOUR", rid)
run = b.finish(rid, "WaitingForUser")
question = run["conversation"]["messages"][-1]
owner_session = question["session_id"]
delegate(question, TEAM[2])
b.wait(lambda e: e["type"] == "notice" and e["error"] and "another coworker" in e["message"])
delegate(question)
run = b.finish(rid)
resolved = next(m for m in run["conversation"]["messages"] if m["id"] == question["id"])["question_request"]
assert resolved["answered_by"] == TEAM[1]["id"] and len(resolved["answers"]) == 4 and all(a["option_ids"] == ["o1"] for a in resolved["answers"])
assert run["conversation"]["messages"][-1]["session_id"] == owner_session
peer = next(m for m in reversed(run["conversation"]["messages"]) if m["kind"] == "assistant" and m["author_id"] == TEAM[1]["id"])
assert peer["session_id"] == alex_session and peer["session_id"] != owner_session
answer = next(m for m in reversed(run["conversation"]["messages"]) if m["kind"] == "answer")
assert answer["author_id"] == TEAM[1]["id"] and answer["recipient_ids"] == [TEAM[2]["id"]] and "User answer:" not in answer["text"]
assert all(m["state"] == "completed" for m in run["conversation"]["mailbox"] if m.get("question_target", {}).get("request_id") == resolved["id"])

# Invalid choices leave the original question open and can be retried with another connection.
b.chat("@noah ASK_QUESTION PEER_BAD", rid)
run = b.finish(rid, "WaitingForUser")
question = run["conversation"]["messages"][-1]
delegate(question)
run = b.finish(rid, "WaitingForUser")
assert next(m for m in run["conversation"]["messages"] if m["id"] == question["id"])["question_request"]["answers"] is None
assert run["conversation"]["messages"][-1]["status"] == "Failed"
delegate(question, TEAM[0])
run = b.finish(rid)
assert next(m for m in run["conversation"]["messages"] if m["id"] == question["id"])["question_request"]["answered_by"] == TEAM[0]["id"]

# A teammate can ask the human first; answering it resumes the assigned teammate, then the asker.
b.chat("@noah ASK_QUESTION PEER_NEEDS_INPUT", rid)
run = b.finish(rid, "WaitingForUser")
question = run["conversation"]["messages"][-1]
delegate(question)
run = b.finish(rid, "WaitingForUser")
peer_question = run["conversation"]["messages"][-1]
assert peer_question["author_id"] == TEAM[1]["id"] and peer_question["question_request"]["answers"] is None
peer_session = peer_question["session_id"]
send_human_answers(peer_question)
run = b.finish(rid)
assert next(m for m in run["conversation"]["messages"] if m["id"] == question["id"])["question_request"]["answered_by"] == TEAM[1]["id"]
assert next(m for m in reversed(run["conversation"]["messages"]) if m["kind"] == "assistant" and m["author_id"] == TEAM[1]["id"])["session_id"] == peer_session

# Cancelling a running answer request does not choose answers or invoke the original asker.
b.chat("@noah ASK_QUESTION PEER_DELAY", rid)
run = b.finish(rid, "WaitingForUser")
question = run["conversation"]["messages"][-1]
delegate(question)
active = b.wait(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Running")["run"]
assignment = next(m for m in active["conversation"]["mailbox"] if m.get("question_target", {}).get("request_id") == question["question_request"]["id"])
b.send(type="cancel_mail", run_id=rid, mail_id=assignment["id"])
run = b.finish(rid, "WaitingForUser")
assert next(m for m in run["conversation"]["messages"] if m["id"] == question["id"])["question_request"]["answers"] is None
assert next(m for m in run["conversation"]["mailbox"] if m["id"] == assignment["id"])["state"] == "cancelled"
send_human_answers(question)
run = b.finish(rid)

# Decline executes nothing. Approve executes the exact argv once and records the real result.
for approved in (False, True):
    b.chat("@alex ASK_APPROVAL", rid)
    run = b.finish(rid, "WaitingForUser")
    message = run["conversation"]["messages"][-1]
    approval = message["approval_request"]
    b.send(type="delegate_question", run_id=rid, message_id=message["id"], request_id=approval["id"], coworker_id=TEAM[2]["id"], settings=b.settings)
    b.wait(lambda e: e["type"] == "notice" and e["error"] and "unanswered question" in e["message"])
    b.send(type="team_approval", run_id=rid, message_id=message["id"], request_id=approval["id"], approved=approved, settings=b.settings)
    run = b.finish(rid)
    assert Path(run["workspace"], "approved.txt").exists() == approved
    resolved = next(m for m in run["conversation"]["messages"] if m["id"] == message["id"])["approval_request"]
    assert resolved["decision"] == approved
    if approved:
        assert resolved["result"]["exit_code"] == 0 and run["changes"]["checks"][-1]["exit_code"] == 0

b.send(type="run_check", run_id=rid, argv=["/usr/bin/false"], owner_id=None)
run = b.finish(rid, "Failed")
assert run["changes"]["checks"][-1]["exit_code"] == 1

# Queued mail can be cancelled before the CLI starts; current deliveries can be stopped separately.
before_noah = len([json.loads(l) for l in CALLS.read_text().splitlines() if json.loads(l)["handle"] == "noah"])
b.chat("@alex SLOW", rid)
active = b.wait(lambda e: e["type"] == "run_updated" and e["run"]["status"] == "Running")["run"]
b.chat("@noah SHOULD_NOT_RUN", rid)
b.wait(lambda e: e["type"] == "team_queued")
b.send(type="get_run", run_id=rid)
active = b.wait(lambda e: e["type"] == "run_detail")["run"]
queued = next(m for m in active["conversation"]["mailbox"] if m["state"] == "queued" and "SHOULD_NOT_RUN" in m["text"])
current = next(m for m in active["conversation"]["mailbox"] if m["state"] == "delivered")
b.send(type="cancel_mail", run_id=rid, mail_id=queued["id"])
b.send(type="cancel_mail", run_id=rid, mail_id=current["id"])
run = b.finish(rid)
after_noah = len([json.loads(l) for l in CALLS.read_text().splitlines() if json.loads(l)["handle"] == "noah"])
assert before_noah == after_noah
assert all(m["state"] == "cancelled" for m in run["conversation"]["mailbox"] if m["id"] in (queued["id"], current["id"]))

# Agent loops stop at a bound and retain their remaining deliveries for explicit continuation.
before = len([m for m in run["conversation"]["messages"] if m["kind"] == "assistant"])
b.chat("@alex LOOP", rid)
run = b.finish(rid)
assert len([m for m in run["conversation"]["messages"] if m["kind"] == "assistant"]) - before == 8
assert any(m["state"] == "paused" for m in run["conversation"]["mailbox"])
for m in run["conversation"]["mailbox"]:
    if m["state"] == "paused": b.send(type="cancel_mail", run_id=rid, mail_id=m["id"])

fresh_team = copy.deepcopy(TEAM)
for worker in fresh_team: worker["id"] = str(uuid.uuid4())
fresh_id = b.chat("New independent task", team=fresh_team, lead=fresh_team[1]["id"])
fresh = b.finish(fresh_id)
assert fresh["id"] != rid and fresh["conversation"]["messages"][-1]["session_id"] != alex_session

# Repeated discussions must synthesize only their own reviews, including duplicate connections.
for marker in ("ROUND_ONE", "ROUND_TWO"):
    before_calls = len(CALLS.read_text().splitlines())
    b.chat(marker, rid, discussion=True)
    discussion = b.finish(rid)
    round_calls = [json.loads(l) for l in CALLS.read_text().splitlines()[before_calls:]]
    assert [c["kind"] for c in round_calls] == ["DiscussionLead", "DiscussionReview", "DiscussionReview", "DiscussionSummary"]
    assert marker in round_calls[-1]["body"]
    if marker == "ROUND_TWO": assert "ROUND_ONE" not in round_calls[-1]["body"]

# Explicit sharing uses the existing task checkout, while a different isolated task gets another checkout.
for worker in fresh_team: worker["id"] = str(uuid.uuid4())
shared_id = b.chat("Shared task checkout", team=fresh_team, lead=fresh_team[1]["id"], isolation={"mode":"share_task", "run_id":rid})
shared = b.finish(shared_id)
assert shared["workspace"] == run["workspace"] and shared["workspace_info"]["project"] == str(PROJECT)
if "--prepare-swift" in sys.argv:
    b.chat("@noah ASK_QUESTION", rid)
    b.finish(rid, "WaitingForUser")
    b.chat("@alex ASK_APPROVAL", shared["id"], lead=fresh_team[1]["id"])
    b.finish(shared["id"], "WaitingForUser")
b.close()
saved = next(r for r in json.loads((DATA / "state" / "runs.json").read_text()) if r["id"] == fresh_id)
assert [m["reasoning"] for m in saved["conversation"]["messages"] if m["kind"] == "assistant"] == [m["reasoning"] for m in fresh["conversation"]["messages"] if m["kind"] == "assistant"]
print("Team smoke passed: independent sessions, teammate question answers and attribution, invalid answer recovery, nested human questions, cancellation, mailbox bounds, durable questions, approvals, checks and workspace isolation.")
print("Team fixture data: " + str(DATA / "state"))
