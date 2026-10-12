#!/usr/bin/env python3
"""Exercise the real web proxy/relay/background engine with an isolated fake coding CLI.

Run after Docker Compose is up. Creates a random fixture account, private data directory,
and disposable project. Never accesses real provider credentials or desktop state.
"""
import copy
import http.cookiejar
import json
import os
import queue
import secrets
import shutil
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ORIGIN = os.environ.get("CONDUCTOR_TEST_ORIGIN", "http://localhost:3005")
AREA = ROOT / "target" / "remote-smoke" / str(uuid.uuid4())
AREA.mkdir(parents=True, mode=0o700)
PROJECT = AREA / "project"
PROJECT.mkdir()
STATE = AREA / "state"
CALLS = AREA / "calls.jsonl"
CALLS.write_text("")
BIN = AREA / "bin"
BIN.mkdir()
ENGINE = BIN / "conductor-engine"
shutil.copy2(ROOT / "target/debug/agent-conductor", ENGINE)
CONFIG = AREA / "claude-config"
CONFIG.mkdir()
(CONFIG / "settings.json").write_text(json.dumps({"env": {"ANTHROPIC_AUTH_TOKEN": "fixture-secret-never-upload"}}))
KEY = AREA / "fixture-keychain"

# Production reads Keychain through the signed UI helper; this fixture supplies a private token.
HELPER = BIN / "agent-conductor"
HELPER.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nprint(Path(" + repr(str(KEY)) + ").read_text())\n")
HELPER.chmod(0o700)

CLI = AREA / "fixture-codex"
CLI.write_text(r'''#!/usr/bin/env python3
import json, os, pathlib, re, sys, time, uuid
if "--help" in sys.argv or "--version" in sys.argv:
    print("exec --json --sandbox resume --model model_reasoning_effort")
    raise SystemExit
args = sys.argv[1:]
prompt = sys.stdin.read()
matches = list(re.finditer(r"\nCURRENT (\w+)(?: FROM [^\n]+)?\n", prompt))
body = prompt[matches[-1].end():] if matches else prompt
session = args[args.index("resume") + 1] if "resume" in args else str(uuid.uuid4())
with open(os.environ["REMOTE_FIXTURE_CALLS"], "a") as file:
    file.write(json.dumps(dict(session=session, body=body, argv=args, cwd=os.getcwd(), pid=os.getpid())) + "\n")
print(json.dumps(dict(type="thread.started",thread_id=session)),flush=True)
if "SLOW" in body: time.sleep(30)
if "USER ANSWERS" in body or "human declined" in body or "Actual result:" in body:
    answer = "Continued with your decision in the same session."
elif "ASK_QUESTION" in body:
    answer = '<conductor-ask>\n' + json.dumps({"questions":[{"question":"Which fixture scope?","multi_select":True,"options":[{"label":"Small"},{"label":"Full"}]}]}) + '\n</conductor-ask>'
elif "ASK_APPROVAL" in body:
    answer = '<conductor-approval>\n' + json.dumps({"summary":"Create a harmless fixture file","argv":[sys.executable,"-c","from pathlib import Path; Path('approved.txt').write_text('approved')"]}) + '\n</conductor-approval>'
else: answer = "Streamed fixture response 🦀 from the laptop.\n\n| Coworker | Status |\n| --- | --- |\n| Maya | Ready |\n\nThis is an isolated fixture running through the real relay and background engine."
print(json.dumps({"type":"item.started","item":{"id":"reply","type":"agent_message","text":""}}),flush=True)
for end in range(8,len(answer),8):
    print(json.dumps({"type":"item.updated","item":{"id":"reply","type":"agent_message","text":answer[:end]}}),flush=True)
    time.sleep(.12)
print(json.dumps({"type":"item.completed","item":{"id":"reply","type":"agent_message","text":answer}}),flush=True)
print(json.dumps({"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}),flush=True)
''')
CLI.chmod(0o700)


class Browser:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.csrf = ""

    def api(self, path, method="GET", body=None):
        headers = {"Origin": ORIGIN, "Content-Type": "application/json"}
        if method != "GET":
            headers["X-CSRF-Token"] = self.csrf
        request = urllib.request.Request(ORIGIN + "/api/v1" + path, method=method, headers=headers,
                                        data=json.dumps(body).encode() if body is not None else None)
        with self.client.open(request, timeout=30) as response:
            return json.load(response)

    def register(self):
        data = self.api("/auth/register", "POST", {"email": str(uuid.uuid4()) + "@example.test", "password": secrets.token_urlsafe(24)})
        self.csrf = data["csrf"]


class Connection:
    def __init__(self):
        env = dict(os.environ, REMOTE_FIXTURE_CALLS=str(CALLS), CLAUDE_CONFIG_DIR=str(CONFIG),
                   CODEX_HOME=str(AREA / "codex-home"), DEEPSEEK_API_KEY="fixture-secret-never-upload")
        self.process = subprocess.Popen([str(ENGINE), "--connect", "--data-dir", str(STATE)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.events = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()
        self.state = self.wait(lambda event: event["type"] == "state")

    def read(self):
        for line in self.process.stdout:
            self.events.put(json.loads(line))

    def send(self, **command):
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def wait(self, predicate, timeout=20):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                event = self.events.get(timeout=max(.1, end - time.monotonic()))
            except queue.Empty:
                break
            if event["type"] == "notice" and event["error"]:
                raise AssertionError(event["message"])
            if predicate(event):
                return event
        raise AssertionError("Engine timed out: " + str(self.process.poll()))

    def detach(self):
        self.process.stdin.close()
        self.process.wait(timeout=8)
        assert self.process.returncode == 0, self.process.stderr.read()


def wait_for(fetch, predicate, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = fetch()
        if predicate(value):
            return value
        time.sleep(.3)
    raise AssertionError("Remote condition timed out")


def daemon_pid():
    rows = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    matches = [int(row.strip().split(None, 1)[0]) for row in rows.splitlines()
               if str(ENGINE) + " --daemon --data-dir " + str(STATE) in row]
    assert len(matches) == 1, matches
    return matches[0]


browser = Browser()
browser.register()
workspace = str(uuid.uuid4())
enrolled = browser.api("/devices", "POST", {"name": "Remote smoke fixture", "workspaces": [{"id": workspace, "label": "Fixture project"}]})
device = enrolled["device"]["id"]
KEY.write_text(enrolled["token"])
KEY.chmod(0o600)
connection = None
stream = None
stream_events = queue.Queue()
last_terminal_message = {}


def overview():
    return browser.api("/devices/" + device)


def run_detail(run_id):
    try:
        return browser.api("/devices/" + device + "/runs/" + run_id)["run"]
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        return None


def command(kind, payload, command_id=None, workspace_id=None):
    identifier = command_id or str(uuid.uuid4())
    result = browser.api("/devices/" + device + "/commands", "POST", {
        "id": identifier, "workspace_id": workspace_id or workspace, "kind": kind, "payload": payload})
    assert result["id"] == identifier
    return identifier


def wait_command(identifier, status="delivered"):
    def lookup():
        return next((c for c in overview()["commands"] if c["id"] == identifier), None)
    result = wait_for(lookup, lambda c: c and c["status"] not in ("queued", "leased"))
    assert result["status"] == status, result
    return result


def completed(run_id, status="Completed"):
    previous = last_terminal_message.get(run_id)
    result = wait_for(lambda: run_detail(run_id), lambda run: run and run["status"] == status
                      and run["conversation"]["messages"][-1]["id"] != previous)
    last_terminal_message[run_id] = result["conversation"]["messages"][-1]["id"]
    return result


def read_stream():
    event = {}
    try:
        for raw in stream:
            line = raw.decode().rstrip("\r\n")
            if not line:
                if event:
                    stream_events.put(event)
                event = {}
            elif ": " in line:
                key, value = line.split(": ", 1)
                event[key] = json.loads(value) if key == "data" else value
    except (OSError, ValueError, AttributeError):
        pass


try:
    connection = Connection()
    settings = copy.deepcopy(connection.state["settings"])
    settings.update(workspace=str(PROJECT), workspace_folders=[str(PROJECT)], workflow="Conversation", claude_config_dir=str(CONFIG))
    for agent in settings["agents"]:
        agent["executable"] = str(CLI) if agent["provider"] == "codex" else str(AREA / "unavailable-cli")
        agent["selected"] = agent["provider"] == "codex"
    connection.send(type="update_settings", settings=settings)
    connection.send(type="discover")
    connection.wait(lambda event: event["type"] == "agents_updated" and any(a["provider"] == "codex" and a["status"] == "ready" for a in event["agents"]))
    config = dict(backend_url=ORIGIN, device_id=device, email="fixture@example.test", workspaces=[dict(id=workspace, label="Fixture project", path=str(PROJECT))])
    connection.send(type="remote_configure", config=config, token=enrolled["token"])
    connection.wait(lambda event: event["type"] == "remote_state" and event["remote"]["state"] == "online")
    advertised = wait_for(overview, lambda value: any(c["provider"] == "codex" and c["available"] for c in value["connections"]))
    serialized = json.dumps(advertised)
    assert "fixture-secret-never-upload" not in serialized and str(PROJECT) not in serialized
    assert enrolled["token"] not in (STATE / "remote.json").read_text()
    assert not (STATE / "remote.json").stat().st_mode & 0o077
    request = urllib.request.Request(ORIGIN + "/api/v1/events?device_id=" + device, headers={"Accept": "text/event-stream"})
    stream = browser.client.open(request, timeout=20)
    initial = []
    while line := stream.readline():
        initial.append(line)
        if line == b"\n":
            break
    assert b"event: snapshot\n" in initial, initial
    stream.close()
    stream = None

    # A duplicate network submission produces exactly one real CLI launch.
    payload = dict(prompt="Explain the fixture project", providers=["codex"], model="fixture-model", effort="low")
    cid = command("chat", payload)
    command("chat", payload, cid)
    wait_command(cid)
    data = wait_for(overview, lambda value: len(value["runs"]) == 1)
    run_id = data["runs"][0]["run_id"]
    # Select a conversation: inactive sessions emit summaries, active ones emit append patches.
    request = urllib.request.Request(ORIGIN + "/api/v1/events?device_id=" + device + "&run_id=" + run_id, headers={"Accept": "text/event-stream"})
    stream = browser.client.open(request, timeout=20)
    threading.Thread(target=read_stream, daemon=True).start()
    run = completed(run_id)
    assert "🦀" in run["conversation"]["messages"][-1]["text"]
    assert len(CALLS.read_text().splitlines()) == 1
    assert str(PROJECT) not in json.dumps(run) and "fixture-secret-never-upload" not in json.dumps(run)
    patches = []
    while not stream_events.empty():
        event = stream_events.get_nowait()
        if event.get("event") == "run_patch":
            patches.extend(event["data"]["changes"])
    assert any(patch["op"] == "append" and patch["path"][-1] == "text" for patch in patches), patches
    worker = run["conversation"]["coworkers"][0]
    follow = command("message", dict(run_id=run_id, prompt="@maya follow up", target_id=worker["id"]))
    wait_command(follow)
    completed(run_id)
    calls = [json.loads(line) for line in CALLS.read_text().splitlines()]
    assert len(calls) == 2 and calls[0]["session"] == calls[1]["session"]

    # The engine, not merely the HTTP relay, rejects invalid model input.
    invalid = command("coworker", dict(run_id=run_id, coworker_id=worker["id"], model="bad model", effort="low"))
    wait_command(invalid, "failed")
    try:
        command("cancel", dict(run_id=run_id), workspace_id=str(uuid.uuid4()))
        raise AssertionError("Unshared workspace accepted")
    except urllib.error.HTTPError as error:
        assert error.code == 404

    # Window close detaches the UI but retains remote command handling.
    pid = daemon_pid()
    connection.detach()
    connection = None
    os.kill(pid, 0)
    background = command("message", dict(run_id=run_id, prompt="Continue while the desktop is closed"))
    wait_command(background)
    completed(run_id)
    assert len(CALLS.read_text().splitlines()) == 3

    # Restart with the persisted grant and private credential helper; retry is deduplicated.
    os.kill(pid, signal.SIGTERM)
    wait_for(lambda: subprocess.check_output(["ps", "-p", str(pid), "-o", "stat="], text=True).strip() if subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0 else "", lambda state: not state or state.startswith("Z"))
    connection = Connection()
    assert next(a for a in connection.state["settings"]["agents"] if a["provider"] == "codex")["executable"] == str(CLI)
    connection.wait(lambda event: event["type"] == "remote_state" and event["remote"]["state"] == "online")
    command("message", dict(run_id=run_id, prompt="Continue while the desktop is closed"), background)
    time.sleep(1)
    assert len(CALLS.read_text().splitlines()) == 3

    question = command("message", dict(run_id=run_id, prompt="ASK_QUESTION"))
    wait_command(question)
    run = completed(run_id, "WaitingForUser")
    message = next(m for m in reversed(run["conversation"]["messages"]) if m.get("question_request") and m["question_request"]["answers"] is None)
    q = message["question_request"]["questions"][0]
    answer = command("answer", dict(run_id=run_id, message_id=message["id"], request_id=message["question_request"]["id"],
                                  answers=[dict(question_id=q["id"], option_ids=[o["id"] for o in q["options"]], text="", skipped=False)]))
    wait_command(answer)
    completed(run_id)
    approval = command("message", dict(run_id=run_id, prompt="ASK_APPROVAL"))
    wait_command(approval)
    run = completed(run_id, "WaitingForUser")
    message = next(m for m in reversed(run["conversation"]["messages"]) if m.get("approval_request") and m["approval_request"]["decision"] is None)
    approve = command("approval", dict(run_id=run_id, message_id=message["id"], request_id=message["approval_request"]["id"], approved=True))
    wait_command(approve)
    completed(run_id)
    assert (PROJECT / "approved.txt").read_text() == "approved"
    slow = command("message", dict(run_id=run_id, prompt="SLOW"))
    wait_command(slow)
    wait_for(lambda: run_detail(run_id), lambda r: r and r["status"] == "Running")
    stop = command("cancel", dict(run_id=run_id))
    wait_command(stop)
    completed(run_id, "Cancelled")
    # Cancelling an already idle task is an acknowledged no-op.
    wait_command(command("cancel", dict(run_id=run_id)))

    # Revocation stops new uploads and commands, including a connected desktop host.
    browser.api("/devices/" + device, "DELETE")
    connection.wait(lambda event: event["type"] == "remote_state" and event["remote"]["state"] == "offline")
    print("PASS: proxy login, streamed append events, scoped delivery, retry deduplication, native-session continuation, background restart, questions, approval, cancellation and revocation")
    print("Fixture:", AREA)
finally:
    if stream:
        stream.close()
    if connection and connection.process.poll() is None:
        connection.send(type="remote_disable")
        connection.wait(lambda event: event["type"] == "remote_state" and event["remote"]["state"] == "disabled")
        connection.detach()
    try:
        os.kill(daemon_pid(), signal.SIGTERM)
    except (AssertionError, ProcessLookupError):
        pass
    try:
        browser.api("/devices/" + device, "DELETE")
    except urllib.error.HTTPError:
        pass
    KEY.unlink(missing_ok=True)
    browser.api("/auth/logout", "POST", {})
