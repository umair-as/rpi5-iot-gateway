#!/usr/bin/env python3
"""Integration checks with a temporary Makefile; no Yocto build is invoked."""
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

            fake = None
            try:
                for target in ("sign-bootfiles-fit-yk", "sign-slot-fits-yk"):
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
                meta = json.loads((run / "run.json").read_text())
                self.assertEqual(meta["build_dir"], str(root / "build"))
                self.assertIn("dirty", meta["source"])
                env["IOTGW_ENABLE_OTBR"] = "1"
                run = launch("ok")
                self.assertEqual(finish(run), 0)
                self.assertEqual(state(run), "succeeded")
                deadline = time.monotonic() + 5
                while "LAST OUTPUT" not in (run / "terminal.log").read_text():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                self.assertIn("FIRST OUTPUT", (run / "terminal.log").read_text())
                run = launch("slow")
                self.assertEqual(state(run), "running")
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
                self.assertEqual(finish(run), -2)
                self.assertEqual(state(run), "interrupted")
                run = launch("hold")
                subprocess.run(["tmux", "-L", SOCKET, "kill-session", "-t", sessions[-1]], check=True)
                self.assertEqual(state(run), "unknown/interrupted")
            finally:
                if fake:
                    fake.kill()
                for session in sessions:
                    subprocess.run(["tmux", "-L", SOCKET, "kill-session", "-t", session], capture_output=True)


if __name__ == "__main__":
    unittest.main()
