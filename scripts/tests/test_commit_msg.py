"""Accepted and refused messages for the commit-msg hook.

Each case runs the hook on a message file inside a throwaway repository, so
this clone's own commit-patterns file and git config play no part. The
throwaway repository carries a per-clone pattern file with neutral tokens.
"""

import os
import pathlib
import shutil
import subprocess

import pytest

HOOKS = pathlib.Path(__file__).resolve().parents[1] / "hooks"
HOOK = HOOKS / "commit-msg"

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git not installed")

BODY = "Body."
PATTERNS = "# test patterns\nPRIVTOKEN\n/opt/privhost/\n"


def git_env(tmp):
    env = dict(os.environ)
    env.update(
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_NOSYSTEM="1",
        HOME=str(tmp),
        GIT_AUTHOR_NAME="t",
        GIT_AUTHOR_EMAIL="t@example.invalid",
        GIT_COMMITTER_NAME="t",
        GIT_COMMITTER_EMAIL="t@example.invalid",
    )
    return env


@pytest.fixture
def repo(tmp_path):
    r = tmp_path / "repo"
    subprocess.run(
        ["git", "init", "-q", "-b", "main", str(r)], env=git_env(tmp_path), check=True
    )
    (r / ".git" / "info").mkdir(exist_ok=True)
    (r / ".git" / "info" / "commit-patterns").write_text(PATTERNS)
    return r


def hook(repo, message):
    msg = repo.parent / "msg"
    msg.write_text(message + "\n")
    return subprocess.run(
        [str(HOOK), str(msg)],
        cwd=repo,
        env=git_env(repo.parent),
        capture_output=True,
        text=True,
        check=False,
    )


EDITOR_TEMPLATE = """\
# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
#
# On branch fix-PRIVTOKEN-thing
# Changes to be committed:
#\tnew file:   scripts/PRIVTOKEN/x
#"""

SCISSORS = """\
# ------------------------ >8 ------------------------
# Do not modify or remove the line above.
diff --git a/PRIVTOKEN b/PRIVTOKEN
+Co-Authored-By: Claude <noreply@anthropic.com>"""

CASES = [
    # (expected, name, message)
    ("pass", "no trailer", "fix(ota): do a thing\n\nBody."),
    (
        "pass",
        "an existing Assisted-by line is not refused",
        "docs: x\n\nAssisted-by: claude-code:example-model-1",
    ),
    (
        "pass",
        "human Co-Authored-By",
        f"docs: x\n\nCo-Authored-By: Jane Doe <jane@example.invalid>\n{BODY}",
    ),
    (
        "pass",
        "Dependabot co-author is not an AI tool",
        f"docs: x\n\n{BODY}\nCo-authored-by: dependabot[bot] <x@example.invalid>",
    ),
    (
        "pass",
        "editor template naming a matching branch and path",
        f"docs: x\n\n{BODY}\n{EDITOR_TEMPLATE}",
    ),
    (
        "pass",
        "comment lines without a match",
        f"docs: x\n\n{BODY}\n# Please enter the commit message for your changes.",
    ),
    ("pass", "diff below the scissors line", f"docs: x\n\n{BODY}\n{SCISSORS}"),
    ("pass", "fixup skips the subject check", "fixup! docs: x"),
    ("pass", "squash skips the subject check", "squash! docs: x"),
    ("pass", "amend skips the subject check", "amend! docs: x"),
    ("pass", "merge skips the subject check", "Merge branch 'topic'"),
    (
        "pass",
        "revert skips the subject check",
        'Revert "docs: x"\n\nThis reverts commit 0.',
    ),
    (
        "fail",
        "comment line with a match (kept by commit -m)",
        f"docs: x\n\n{BODY}\n# see PRIVTOKEN notes",
    ),
    ("fail", "pattern in the body", f"docs: x\n\nRan /opt/privhost/tool.\n\n{BODY}"),
    ("fail", "pattern on a fixup", "fixup! docs: PRIVTOKEN"),
    (
        "fail",
        "AI Co-Authored-By",
        f"docs: x\n\n{BODY}\nCo-Authored-By: Claude <noreply@anthropic.com>",
    ),
    (
        "fail",
        "AI Co-Authored-By, lower case",
        f"docs: x\n\n{BODY}\nco-authored-by: codex <codex@openai.com>",
    ),
    (
        "fail",
        "Copilot agent co-author",
        f"docs: x\n\n{BODY}\nCo-authored-by: copilot-swe-agent[bot] <x@example.invalid>",
    ),
    (
        "fail",
        "AI Co-Authored-By on a fixup",
        "fixup! docs: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>",
    ),
    ("fail", "not a Conventional Commit subject", f"update things\n\n{BODY}"),
    ("fail", "subject ends with a period", f"docs: x.\n\n{BODY}"),
    (
        "fail",
        "body over 25 lines",
        "docs: x\n\n" + "\n".join(f"line {i}" for i in range(26)) + f"\n\n{BODY}",
    ),
]


@pytest.mark.parametrize("expected, name, message", CASES, ids=[c[1] for c in CASES])
def test_hook(repo, expected, name, message):
    r = hook(repo, message)
    got = "pass" if r.returncode == 0 else "fail"
    assert got == expected, r.stderr


def test_no_pattern_file_disables_only_the_pattern_check(repo):
    (repo / ".git" / "info" / "commit-patterns").unlink()
    assert hook(repo, "docs: PRIVTOKEN").returncode == 0
    assert hook(repo, "PRIVTOKEN").returncode != 0


def test_real_commit(repo):
    """The hook wired through core.hooksPath into an actual git commit."""
    env = git_env(repo.parent)

    def git(*args):
        return subprocess.run(
            ["git", "-c", f"core.hooksPath={HOOKS}", *args],
            cwd=repo,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    (repo / "f").write_text("x")
    assert git("add", "f").returncode == 0
    refused = git(
        "commit",
        "-q",
        "-m",
        "docs: add f",
        "-m",
        "Co-Authored-By: Claude <noreply@anthropic.com>",
    )
    assert refused.returncode != 0
    assert "AI Co-Authored-By" in refused.stderr
    assert git("commit", "-q", "-m", "docs: add f").returncode == 0
