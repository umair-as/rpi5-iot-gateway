"""tpm-encrypted-store-dev.sh must only ever reuse, format or close a mapping
proven to be backed by its own image.

Every privileged command is a shell-function stub loaded through BASH_ENV;
the stubs only log what they were asked to do. No real mapper, loop device,
filesystem or TPM is touched.
"""

from __future__ import annotations

import os
import pathlib
import subprocess

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "tpm-encrypted-store-dev.sh"
MAP = "igwencstore"

STUBS = r"""
id() { printf '0\n'; }
log_call() { printf '%s\n' "$*" >> "$STUB_LOG"; }
[() {
    if [[ "${1:-}" == '!' && "${2:-}" == -e && "${3:-}" == "/dev/mapper/$MAP_NAME" ]]; then
        [[ "$MOCK_MAPPER_EXISTS" != 1 ]]; return
    fi
    if [[ "${1:-}" == -e && "${2:-}" == "/dev/mapper/$MAP_NAME" ]]; then
        [[ "$MOCK_MAPPER_EXISTS" == 1 ]]; return
    fi
    builtin [ "$@"
}
cryptsetup() {
    case "$1" in
        isLuks) return 0 ;;
        luksDump) printf 'systemd-tpm2\n' ;;
        status)
            [[ "${MOCK_STATUS_RC:-0}" == 0 ]] || return "$MOCK_STATUS_RC"
            printf '/dev/mapper/%s is active.\n  type:    LUKS2\n  device:  %s\n' "$2" "${MOCK_DEVICE:-/dev/loop7}" ;;
        open) log_call "cryptsetup open $*"; MOCK_MAPPER_EXISTS=1 ;;
        close) log_call "cryptsetup close $*" ;;
        *) log_call "UNEXPECTED cryptsetup $*"; return 98 ;;
    esac
}
losetup() { printf '%s\n' "$MOCK_BACKFILE"; }
blkid() {
    [[ -n "${MOCK_FSTYPE:-}" ]] && printf '%s\n' "$MOCK_FSTYPE"
    return "${MOCK_BLKID_RC:-0}"
}
systemd-cryptenroll() { log_call "systemd-cryptenroll $*"; return 98; }
mkfs.ext4() { log_call "mkfs.ext4 $*"; }
mount() { log_call "mount $*"; }
umount() { log_call "umount $*"; }
findmnt() { return 1; }
"""


@pytest.fixture
def store(tmp_path):
    stubs = tmp_path / "stubs.sh"
    stubs.write_text(STUBS)
    d = tmp_path / "store"
    d.mkdir()
    (d / "recovery.key").write_text("fixture only\n")
    image = d / "image"
    image.write_bytes(b"")
    foreign = tmp_path / "other-image"
    foreign.write_bytes(b"")
    return {
        "stubs": stubs,
        "dir": d,
        "image": image,
        "foreign": foreign,
        "log": tmp_path / "calls.log",
    }


def run(
    store,
    *args,
    exists,
    backfile=None,
    fstype="",
    blkid_rc=0,
    status_rc=0,
    device="/dev/loop7",
):
    env = dict(os.environ)
    env.update(
        {
            "BASH_ENV": str(store["stubs"]),
            "STUB_LOG": str(store["log"]),
            "STORE_DIR": str(store["dir"]),
            "IMAGE_PATH": str(store["image"]),
            "RECOVERY_KEY_FILE": str(store["dir"] / "recovery.key"),
            "MOUNT_POINT": str(store["dir"] / "mnt"),
            "MAP_NAME": MAP,
            "MOCK_MAPPER_EXISTS": "1" if exists else "0",
            "MOCK_BACKFILE": str(backfile or store["image"]),
            "MOCK_FSTYPE": fstype,
            "MOCK_BLKID_RC": str(blkid_rc),
            "MOCK_STATUS_RC": str(status_rc),
            "MOCK_DEVICE": device,
        }
    )
    r = subprocess.run(
        ["bash", str(SCRIPT), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    calls = store["log"].read_text().splitlines() if store["log"].exists() else []
    return r, calls


def called(calls, prefix):
    return any(c.startswith(prefix) for c in calls)


def test_absent_mapping_is_opened_and_formatted(store):
    r, calls = run(store, exists=False, blkid_rc=2)
    assert r.returncode == 0, r.stdout + r.stderr
    assert called(calls, "cryptsetup open")
    assert called(calls, "mkfs.ext4")


def test_own_mapping_with_ext4_is_reused(store):
    r, calls = run(store, exists=True, fstype="ext4")
    assert r.returncode == 0, r.stdout + r.stderr
    assert not called(calls, "cryptsetup open")
    assert not called(calls, "mkfs.ext4")
    assert called(calls, "mount")


@pytest.mark.parametrize("fstype", ["ext4", "xfs"])
def test_foreign_mapping_is_refused(store, fstype):
    r, calls = run(store, exists=True, backfile=store["foreign"], fstype=fstype)
    assert r.returncode != 0
    assert "not backed by" in r.stdout
    assert calls == []


def test_own_mapping_with_other_filesystem_is_not_formatted(store):
    r, calls = run(store, exists=True, fstype="xfs")
    assert r.returncode != 0
    assert "refusing to format" in r.stdout
    assert not called(calls, "mkfs.ext4")
    assert not called(calls, "mount")


def test_failed_probe_is_not_formatted(store):
    r, calls = run(store, exists=True, blkid_rc=4)
    assert r.returncode != 0
    assert "could not probe" in r.stdout
    assert not called(calls, "mkfs.ext4")


def test_failed_cryptsetup_status_is_refused(store):
    r, calls = run(store, exists=True, status_rc=4)
    assert r.returncode != 0
    assert "not backed by" in r.stdout
    assert calls == []


def test_force_mode_does_not_close_a_foreign_mapping(store):
    r, calls = run(store, "--force-recreate", exists=True, backfile=store["foreign"])
    assert r.returncode != 0
    assert not called(calls, "cryptsetup close")
    assert store["image"].exists()


@pytest.mark.parametrize("device", ["/dev/loop7p1", "/dev/dm-3", "/dev/sda2"])
def test_mapping_not_on_a_whole_loop_device_is_refused(store, device):
    r, calls = run(store, exists=True, fstype="ext4", device=device)
    assert r.returncode != 0
    assert "not backed by" in r.stdout
    assert calls == []


def test_unresolvable_backing_and_image_are_not_ours(store, tmp_path):
    """Two failed path resolutions must not compare equal."""
    store["image"].unlink()
    gone = tmp_path / "deleted-image"
    r, calls = run(store, "--force-recreate", exists=True, backfile=gone)
    assert r.returncode != 0
    assert not called(calls, "cryptsetup close")
    assert not called(calls, "umount")
