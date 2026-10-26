#!/usr/bin/env python3
"""Close busy and idle surfaces in disposable application instances."""

import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time


def app_pids():
    result = subprocess.run(["pgrep", "-x", "agterm"], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr)
    return {int(pid) for pid in result.stdout.split()}


def stop_test_app(pid):
    result = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    children = {}
    for line in result.splitlines():
        child, parent = map(int, line.split())
        children.setdefault(parent, []).append(child)

    def stop_tree(parent):
        for child in children.get(parent, []):
            stop_tree(child)
        try:
            os.kill(parent, signal.SIGKILL)
        except ProcessLookupError:
            pass

    stop_tree(pid)


def run_case(app, evidence, count, busy):
    name = f"{'spam' if busy else 'idle'}-{count}"
    case_dir = evidence / name
    case_dir.mkdir(parents=True, exist_ok=True)
    state = Path(tempfile.mkdtemp(prefix="agclose-", dir="/tmp"))
    (state / "windows").mkdir()
    (state / "settings.json").write_text(json.dumps({"restoreMode": "none"}))
    producer = state / "producer.py"
    producer.write_text(
        "import sys,time\n"
        "end=time.monotonic()+30\n"
        "while time.monotonic()<end:\n"
        " sys.stdout.write('\\x1b]0;title\\x07')\n"
        " sys.stdout.flush()\n"
    )
    before = app_pids()
    subprocess.run(
        ["open", "-n", "-a", str(app), "--env", f"AGTERM_STATE_DIR={state}"],
        check=True,
    )
    deadline = time.monotonic() + 5
    created = set()
    while time.monotonic() < deadline:
        created = app_pids() - before
        if created:
            break
        time.sleep(0.1)
    if len(created) != 1:
        raise RuntimeError(f"Cannot identify isolated app: {created}")
    pid = created.pop()
    ctl = app / "Contents/MacOS/agtermctl"

    def call(*args):
        result = subprocess.run(
            [str(ctl), *args, "--socket", str(state / "agterm.sock"), "--json"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode:
            raise RuntimeError(result.stderr)
        return json.loads(result.stdout)["result"]

    try:
        deadline = time.monotonic() + 12
        while not (state / "agterm.sock").exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        version = call("version")
        ids = []
        command = f"/usr/bin/python3 {shlex.quote(str(producer))}" if busy else "/bin/sleep 30"
        for index in range(count):
            ids.append(call("session", "new", "--name", f"{name}-{index}", "--command", command, "--no-select")["id"])
        deadline = time.monotonic() + 5
        while True:
            tree = call("tree")["tree"]
            sessions = [session for workspace in tree["workspaces"] for session in workspace["sessions"]]
            if all(any(s["id"] == sid and s.get("realized") for s in sessions) for sid in ids):
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Test surfaces did not realize")
            time.sleep(0.1)
        time.sleep(1)
        call("session", "close", "--target", ids[0])
        call("version")
        (case_dir / "result.json").write_text(json.dumps({"status": "passed", "version": version}))
        print(f"PASS {name}", flush=True)
    except Exception as exc:
        (case_dir / "result.json").write_text(json.dumps({"status": "failed", "error": str(exc)}))
        subprocess.run(["sample", str(pid), "2", "-file", str(case_dir / "sample.txt")], timeout=20)
        raise
    finally:
        stop_test_app(pid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    failed = []
    for count, busy in [(1, True), (8, True), (8, False)]:
        try:
            run_case(args.app.resolve(), args.evidence.resolve(), count, busy)
        except Exception as exc:
            failed.append(str(exc))
            print(f"FAIL {'spam' if busy else 'idle'}-{count}: {exc}", flush=True)
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
