#!/usr/bin/env python3
"""Run make in a logged tmux pane, independently of an agent's tool call.

Usage:
  agent-build.py start [--worktree PATH] <topic> -- <target>... [VAR=value]...
  agent-build.py status <run-dir>

Each run gets scratch/builds/<run-id>/ with run.json (command, build directory,
source commit and dirty files), started.json, result.json (make's exit code)
and terminal.log. See docs/AGENT_BUILDS.md.
"""

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid


SELF = Path(__file__).resolve()
SOCKET = "iotgw-builds"
# Makefile targets that end up running bitbake; keep in step with the Makefile.
BUILD_TARGETS = {"base", "dev", "prod", "desktop", "bundle", "parse", "layers", "bitbake-task",
                 "sbom-cve", "cve-report", "sbom-report", "kernel-hardening-report"}
RUNNING = r"bin/(bitbake|bitbake-server|kas|kas-container)( |$)"
# One BitBake build per host, across worktrees and build directories. The
# runner takes this lock before it reports ready and holds it for the whole
# build, so two launches that both pass the process check cannot both start.
HOST_LOCK = Path(os.environ.get("IOTGW_AGENT_BUILD_HOST_LOCK")
                 or Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "iotgw-agent-build.lock")


def tmux(*args):
    return subprocess.run(["tmux", "-L", SOCKET, *args], check=True,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(path)


def wait_for(path, seconds=15):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Timed out waiting for {path}; inspect the run before retrying")
        time.sleep(0.05)


def running_builds():
    out = subprocess.run(["pgrep", "-af", RUNNING], capture_output=True, text=True).stdout
    # Shell wrappers that merely mention a path in their command string are not builds.
    return [line for line in out.splitlines() if not re.match(r"\d+ \S*sh -c ", line)]


def git_state(root):
    def git(*args):
        result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None
    status = git("status", "--porcelain")
    return {"commit": git("rev-parse", "HEAD"),
            "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
            "dirty": status.splitlines() if status else []}


def runner(run):
    meta = json.loads((run / "run.json").read_text())
    build = Path(meta["build_dir"])
    build.mkdir(parents=True, exist_ok=True)
    with (build / ".agent-build.lock").open("a") as lock, \
            open(meta.get("host_lock") or os.devnull, "a") as host_lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            (run / "startup-error").write_text("Another launcher build owns this build directory\n")
            return 1
        if meta.get("host_lock"):
            try:
                fcntl.flock(host_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                (run / "startup-error").write_text(
                    "Another launcher build is running on this host; one build at a time\n")
                return 1
        (run / "ready").touch()
        try:
            wait_for(run / "start", 30)
        except RuntimeError as exc:
            (run / "startup-error").write_text(str(exc) + "\n")
            return 1
        # Preserve the pane's terminal settings, but never inherit stale build
        # settings from a previously started tmux server.
        env = meta["environment"] | {"TERM": os.environ.get("TERM", "screen")}
        write_json(run / "started.json", {"started": now()})
        print("+ " + shlex.join(meta["command"]), flush=True)
        # Ctrl-C reaches make through the pane's foreground process group.
        # Keep the supervisor alive long enough to record make's exit status.
        signal.signal(signal.SIGINT, lambda *_: None)
        process = subprocess.Popen(meta["command"], cwd=meta["worktree"], env=env,
                                   pass_fds=(lock.fileno(), host_lock.fileno()))
        code = process.wait()
        write_json(run / "result.json", {"finished": now(), "exit_code": code})
        print(f"\nBUILD EXIT={code}", flush=True)
        return code if code >= 0 else 128 - code


def start(args):
    root = Path(args.worktree).resolve()
    if not (root / "Makefile").is_file():
        raise ValueError(f"No Makefile in {root}")
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", args.topic):
        raise ValueError("Topic must contain only letters, digits, underscores or hyphens")
    command = args.make_args
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise ValueError("Supply a make target")
    for arg in command:
        if arg.startswith("-") or arg.startswith("KAS_BUILD_DIR="):
            raise ValueError("Use targets and VAR=value arguments only; set KAS_BUILD_DIR in the environment")
        if arg.startswith("sign-"):
            raise ValueError("HSM signing is operator-driven; run this target interactively")
    if BUILD_TARGETS & set(command):
        busy = running_builds()
        if busy:
            raise RuntimeError("A bitbake/kas build is already running on this host; one build "
                               "at a time: " + "; ".join(line[:120] for line in busy[:3]))
    # Explicit, limited environment transfer. Do not persist credentials or a
    # wholesale environment dump. Host-local setup can be supplied by env.sh.
    names = {"PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE",
             "TMPDIR", "KAS_WORK_DIR", "KAS_BUILD_DIR", "KAS_REPO_REF_DIR"}
    names.update(k for k in os.environ if k.startswith("IOTGW_ENABLE_"))
    env = {k: os.environ[k] for k in names if k in os.environ}
    build = Path(env.get("KAS_BUILD_DIR", str(root / "build")))
    if not build.is_absolute():
        build = root / build
    build = build.resolve()
    env["KAS_BUILD_DIR"] = str(build)
    env.setdefault("KAS_WORK_DIR", str(root / ".kas"))
    run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + args.topic + "-" + uuid.uuid4().hex[:8]
    run = root / "scratch" / "builds" / run_id
    run.mkdir(parents=True, mode=0o700)
    session = "build-" + run_id
    meta = {"created": now(), "worktree": str(root), "build_dir": str(build),
            "host_lock": str(HOST_LOCK) if BUILD_TARGETS & set(command) else None,
            "source": git_state(root), "session": session, "command": ["make", *command], "environment": env}
    write_json(run / "run.json", meta)
    # Start a waiting runner, configure capture, then release it. No send-keys
    # and no race between initial make output and installing pipe-pane.
    # history-limit only applies to panes created after it is set, so a
    # placeholder holds the session open while the options are applied. Both
    # are scoped to this session; global and user tmux settings are untouched.
    placeholder = tmux("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", session, "sleep", "60")
    try:
        tmux("set-option", "-t", session, "mouse", "on")
        tmux("set-option", "-t", session, "history-limit", "50000")
        pane = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", session,
                    "-c", str(root), sys.executable, str(SELF), "_run", str(run))
        tmux("kill-pane", "-t", placeholder)
        tmux("set-option", "-w", "-t", pane, "remain-on-exit", "on")
        deadline = time.monotonic() + 15
        while not (run / "ready").exists():
            if (run / "startup-error").exists():
                raise RuntimeError((run / "startup-error").read_text().strip())
            if time.monotonic() >= deadline:
                raise RuntimeError("Runner did not become ready")
            time.sleep(0.05)
        capture = "exec 3>> " + shlex.quote(str(run / "terminal.log")) + " && touch " + shlex.quote(str(run / "capture-ready")) + " && exec cat >&3"
        tmux("pipe-pane", "-t", pane, capture)
        wait_for(run / "capture-ready")
        (run / "start").touch()
    except Exception:
        # The start gate was never released: no make process to interrupt.
        subprocess.run(["tmux", "-L", SOCKET, "kill-session", "-t", session], capture_output=True)
        if (run / "startup-error").exists():
            raise RuntimeError((run / "startup-error").read_text().strip()) from None
        raise
    print(f"Run: {run}\nWatch: tmux -L {SOCKET} attach-session -r -t {session}")
    print(f"Status: python3 {SELF} status {shlex.quote(str(run))}")
    print(f"Log: {run / 'terminal.log'}")


def status(run):
    meta = json.loads((run / "run.json").read_text())
    if (run / "result.json").exists():
        result = json.loads((run / "result.json").read_text())
        code = result["exit_code"]
        # A negative code is Popen's "killed by signal -code": an interrupted
        # build (Ctrl-C is -2), not a failing one.
        if code < 0:
            print(json.dumps({"state": "interrupted", "signal": -code, **result}))
        else:
            print(json.dumps({"state": "succeeded" if code == 0 else "failed", **result}))
        return
    if (run / "startup-error").exists():
        print(json.dumps({"state": "startup-failed", "error": (run / "startup-error").read_text().strip()}))
        return
    try:
        alive = tmux("list-panes", "-t", meta["session"], "-F", "#{pane_dead}") == "0"
    except subprocess.CalledProcessError:
        alive = False
    print(json.dumps({"state": ("running" if (run / "started.json").exists() else "starting")
                     if alive else "unknown/interrupted"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    launch = sub.add_parser("start", help="Launch make targets in a dedicated tmux session")
    launch.add_argument("--worktree", default=str(SELF.parents[2]))
    launch.add_argument("topic")
    launch.add_argument("make_args", nargs=argparse.REMAINDER)
    for name in ("status", "_run"):
        sub.add_parser(name).add_argument("run", type=Path)
    args = parser.parse_args()
    if args.action == "start":
        start(args)
    elif args.action == "status":
        status(args.run.resolve())
    else:
        return runner(args.run.resolve())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"agent-build: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        sys.exit(1)
