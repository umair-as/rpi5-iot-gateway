#!/usr/bin/env python3
"""Integration checks with a temporary Makefile; no Yocto build is invoked."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

LAUNCHER = Path(__file__).with_name("agent-build.py").resolve()
SOCKET = "iotgw-builds"


class LauncherTest(unittest.TestCase):
    def test_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="agent build ") as tmp:
            root = Path(tmp)
            (root / "Makefile").write_text(
                "ok:\n\t@printf 'FIRST OUTPUT\\n'\n"
                "\t@test -t 1\n\t@test \"$$IOTGW_ENABLE_OTBR\" = 1\n"
                "\t@printf 'LAST OUTPUT\\n'\n"
                "fail:\n\t@exit 7\n"
                "slow:\n\t@sleep 3\n\t@echo SURVIVED\n"
                "hold:\n\t@sleep 30\n"
                "dev:\n\t@true\n")
            env = dict(os.environ, IOTGW_ENABLE_OTBR="1")
            for key in ("KAS_BUILD_DIR", "KAS_WORK_DIR"):
                env.pop(key, None)
            sessions = []

            def start(topic, *make_args):
                return subprocess.run([sys.executable, str(LAUNCHER), "start", "--worktree",
                                       str(root), topic, "--", *make_args], env=env,
                                      text=True, capture_output=True)

            def launch(target, success=True):
                result = start(target, target)
                runs = sorted((root / "scratch/builds").iterdir(), key=lambda p: p.stat().st_mtime_ns)
                run = runs[-1]
                sessions.append(json.loads((run / "run.json").read_text())["session"])
                self.assertEqual(result.returncode == 0, success, result.stderr)
                return run

            def finish(run):
                deadline = time.monotonic() + 10
                while not (run / "result.json").exists():
                    self.assertLess(time.monotonic(), deadline, str(run))
                    time.sleep(0.05)
                return json.loads((run / "result.json").read_text())["exit_code"]

            def state(run):
                result = subprocess.check_output([sys.executable, str(LAUNCHER), "status", str(run)], text=True)
                return json.loads(result)["state"]

            def wait(run, *extra):
                r = subprocess.run([sys.executable, str(LAUNCHER), "wait", "--interval", "0.1",
                                    *extra, str(run)], text=True, capture_output=True, timeout=30,
                                   check=False)
                return r.returncode, json.loads(r.stdout)

            fake = None
            try:
                for target in ("sign-slot-fits-yk", "sign-slot-fits-softhsm"):
                    refused = start("signing", target)
                    self.assertNotEqual(refused.returncode, 0)
                    self.assertIn("operator-driven", refused.stderr)
                for bad in (("-C", "/tmp", "ok"), ("ok", "KAS_BUILD_DIR=/tmp/x")):
                    refused = start("refused", *bad)
                    self.assertNotEqual(refused.returncode, 0)
                    self.assertIn("VAR=value", refused.stderr)
                # One build per host: a bitbake target is refused while a
                # bitbake process runs, whatever its build directory.
                (root / "fake/bin").mkdir(parents=True)
                # No exec: the process must keep its .../bin/bitbake command line.
                (root / "fake/bin/bitbake").write_text("#!/bin/sh\nsleep 30\n")
                (root / "fake/bin/bitbake").chmod(0o755)
                fake = subprocess.Popen([str(root / "fake/bin/bitbake")])
                time.sleep(0.2)
                refused = start("busy", "dev")
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn("one build at a time", refused.stderr)
                fake.terminate()
                fake.wait()
                fake = None
                # Keep this first pane so the tmux server persists with an
                # earlier client's settings while the next launch changes them.
                env["IOTGW_ENABLE_OTBR"] = "0"
                run = launch("fail")
                self.assertEqual(finish(run), 2)  # make's status, not the recipe shell's 7
                self.assertEqual(state(run), "failed")
                self.assertEqual(wait(run), (1, json.loads(subprocess.check_output(
                    [sys.executable, str(LAUNCHER), "status", str(run)], text=True))))
                meta = json.loads((run / "run.json").read_text())
                self.assertEqual(meta["build_dir"], str(root / "build"))
                self.assertIn("dirty", meta["source"])
                env["IOTGW_ENABLE_OTBR"] = "1"
                run = launch("ok")
                code, out = wait(run)
                self.assertEqual((code, out["state"]), (0, "succeeded"))
                self.assertEqual(finish(run), 0)
                self.assertEqual(state(run), "succeeded")
                deadline = time.monotonic() + 5
                while "LAST OUTPUT" not in (run / "terminal.log").read_text():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                self.assertIn("FIRST OUTPUT", (run / "terminal.log").read_text())
                run = launch("slow")
                self.assertEqual(state(run), "running")
                code, out = wait(run, "--timeout", "0.3")
                self.assertEqual((code, out["state"], out.get("timeout")), (3, "running", True))
                launch("ok", success=False)
                self.assertEqual(finish(run), 0)  # survives launcher process exit
                # Ctrl-C reaches make, not the supervisor: recorded, and reported
                # as an interruption rather than a build failure.
                run = launch("hold")
                deadline = time.monotonic() + 5
                while not (run / "started.json").exists():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                time.sleep(0.5)
                subprocess.run(["tmux", "-L", SOCKET, "send-keys", "-t", sessions[-1], "C-c"], check=True)
                self.assertEqual(finish(run), -2, (run / "terminal.log").read_text()[-2000:])
                self.assertEqual(state(run), "interrupted")
                self.assertEqual(wait(run)[0], 2)
                run = launch("hold")
                subprocess.run(["tmux", "-L", SOCKET, "kill-session", "-t", sessions[-1]], check=True)
                self.assertEqual(state(run), "unknown/interrupted")
                # A vanished session without result.json is never success.
                self.assertEqual(wait(run, "--timeout", "5"), (2, {"state": "unknown/interrupted"}))
            finally:
                if fake:
                    fake.kill()
                for session in sessions:
                    subprocess.run(["tmux", "-L", SOCKET, "kill-session", "-t", session], capture_output=True)

    def test_host_lock(self):
        """One BitBake build per host across worktrees, decided by the runners' host
        lock: the process check alone races (both launches can pass it before either
        build starts BitBake)."""
        # The process check is host-wide by design, so a real build refuses
        # every launch here before the lock under test is reached.
        busy = load_launcher().running_builds()
        if busy:
            self.skipTest("a real bitbake/kas process is running: " + busy[0][:80])
        with tempfile.TemporaryDirectory(prefix="agent build host ") as tmp:
            base = Path(tmp)
            roots = []
            for name in ("one", "two"):
                root = base / name
                root.mkdir()
                (root / "Makefile").write_text("parse:\n\t@sleep 3\n" "dev:\n\t@true\n"
                                                "notabuild:\n\t@true\n")
                roots.append(root)
            env = dict(os.environ, IOTGW_AGENT_BUILD_HOST_LOCK=str(base / "host.lock"))
            for key in ("KAS_BUILD_DIR", "KAS_WORK_DIR"):
                env.pop(key, None)
            sessions = []

            def start(root, target):
                result = subprocess.run([sys.executable, str(LAUNCHER), "start", "--worktree",
                                         str(root), target, "--", target], env=env,
                                        text=True, capture_output=True)
                runs = sorted((root / "scratch/builds").iterdir(), key=lambda p: p.stat().st_mtime_ns)
                sessions.append(json.loads((runs[-1] / "run.json").read_text())["session"])
                return result, runs[-1]

            def finish(run):
                deadline = time.monotonic() + 15
                while not (run / "result.json").exists():
                    self.assertLess(time.monotonic(), deadline, str(run))
                    time.sleep(0.05)
                return json.loads((run / "result.json").read_text())["exit_code"]

            try:
                first, run_a = start(roots[0], "parse")
                self.assertEqual(first.returncode, 0, first.stderr)
                self.assertEqual(json.loads((run_a / "run.json").read_text())["host_lock"],
                                 str(base / "host.lock"))
                second, _ = start(roots[1], "dev")
                self.assertNotEqual(second.returncode, 0)
                self.assertIn("one build at a time", second.stderr)
                other, run_c = start(roots[1], "notabuild")   # not a BitBake target: no host lock
                self.assertEqual(other.returncode, 0, other.stderr)
                self.assertIsNone(json.loads((run_c / "run.json").read_text())["host_lock"])
                self.assertEqual(finish(run_a), 0)
                again, run_b = start(roots[1], "dev")
                self.assertEqual(again.returncode, 0, again.stderr)
                self.assertEqual(finish(run_b), 0)
            finally:
                for session in sessions:
                    subprocess.run(["tmux", "-L", SOCKET, "kill-session", "-t", session], capture_output=True)


def load_launcher():
    spec = importlib.util.spec_from_file_location("agent_build", LAUNCHER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StatusUnitTest(unittest.TestCase):
    """status_of/wait logic without tmux: the session lookup is stubbed."""

    def setUp(self):
        self.ab = load_launcher()
        self.tmp = tempfile.TemporaryDirectory(prefix="agent build unit ")
        self.run_dir = Path(self.tmp.name)
        (self.run_dir / "run.json").write_text(json.dumps({"session": "build-none"}))
        (self.run_dir / "started.json").write_text("{}")

    def tearDown(self):
        self.tmp.cleanup()

    def test_result_written_before_pane_dies_is_the_outcome(self):
        def tmux(*args):
            # The runner finishes between the result check and the pane check.
            (self.run_dir / "result.json").write_text(json.dumps({"exit_code": 0, "finished": "t"}))
            raise subprocess.CalledProcessError(1, "tmux")
        self.ab.tmux = tmux
        self.assertEqual(self.ab.status_of(self.run_dir)["state"], "succeeded")

    def test_missing_session_without_result_is_unknown(self):
        def tmux(*args):
            raise subprocess.CalledProcessError(1, "tmux")
        self.ab.tmux = tmux
        self.assertEqual(self.ab.status_of(self.run_dir), {"state": "unknown/interrupted"})
        self.assertEqual(self.ab.wait(self.run_dir, timeout=1, interval=0.01), 2)

    def test_missing_run_json_is_unknown(self):
        (self.run_dir / "run.json").unlink()
        self.assertEqual(self.ab.wait(self.run_dir, timeout=1, interval=0.01), 2)

    def test_running_reports_progress(self):
        self.ab.tmux = lambda *args: "0"
        (self.run_dir / "terminal.log").write_bytes(
            b"Currently  2 running tasks (10 of 20)\r\n0: a-1.0-r0 do_compile - 1s (pid 1)\r\n"
            b"Currently  2 running tasks (663 of 884)  75% |###  |\r\n"
            b"\x1b[32m0: \x1b]8;;file:///x\x1b\\b-2.0-r0\x1b]8;;\x1b\\ do_fetch - 22m (pid 2)\x1b[0m\r\n"
            b"1: c-3.0-r0 do_compile - 5s (pid 3)\r\n"
            b"Setscene tasks: 5 of 5\r\n")
        state = self.ab.status_of(self.run_dir)
        self.assertEqual(state["state"], "running")
        self.assertEqual(state["progress"], {
            "running": 2, "task": 663, "of": 884,
            "tasks": ["b-2.0-r0 do_fetch - 22m (pid 2)", "c-3.0-r0 do_compile - 5s (pid 3)"]})
        self.assertEqual(self.ab.wait(self.run_dir, timeout=0.05, interval=0.01), 3)


if __name__ == "__main__":
    unittest.main()
