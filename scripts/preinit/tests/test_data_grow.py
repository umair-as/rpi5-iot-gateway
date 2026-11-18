"""Tests for the /data growth in iotgw-preinit.

The growth functions are extracted from the shipped script and run under the
POSIX shells available on the host (busybox ash, dash) against disk-image
files, with the real parted, sgdisk, dumpe2fs and resize2fs. An image file
stands in for the card: one that is larger than the image written to it still
carries its backup GPT where the image ended, which is the case that matters.

Difference from the board: there the filesystem is grown online (mounted);
here it is grown offline after a forced e2fsck, because mounting needs root.
The decision logic and the commands are the same.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
PREINIT = REPO / "meta-iot-gateway/recipes-support/iotgw-preinit/files/iotgw-preinit.sh"
TOOLS = ("parted", "sgdisk", "dumpe2fs", "resize2fs", "mkfs.ext4", "e2fsck")
SHELLS = [s for s in (["busybox", "ash"], ["dash"]) if shutil.which(s[0])]
MIB = 1024 * 1024

pytestmark = pytest.mark.skipif(
    not all(shutil.which(t) or Path("/usr/sbin", t).exists() for t in TOOLS),
    reason="needs parted, gptfdisk and e2fsprogs on the host",
)


def functions() -> str:
    text = PREINIT.read_text()
    m = re.search(r"^# /data growth -+\n.*?(?=^# Last resort)", text, re.S | re.M)
    assert m, "/data growth block not found in iotgw-preinit.sh"
    return m.group(0)


def call(tmp_path: Path, shell, body: str):
    log = tmp_path / "preinit.log"
    script = "\n".join([
        "export PATH=/usr/sbin:/usr/bin:/sbin:/bin",
        f'LOG="{log}"',
        f'log() {{ echo "$*" >> "{log}"; }}',
        functions(),
        body,
        "echo rc=$?",
    ])
    r = subprocess.run([*shell, "-c", script], capture_output=True, text=True)
    lines = log.read_text().splitlines() if log.exists() else []
    return r, lines


def sh(*cmd):
    subprocess.run(cmd, check=True, capture_output=True)


def make_disk(path: Path, image_mib: int, card_mib: int, data_mib: int):
    """GPT image like the WIC layout (data is partition 5), on a larger card."""
    path.write_bytes(b"")
    with open(path, "wb") as f:
        f.truncate(image_mib * MIB)
    sh("sgdisk", "-o", str(path))
    sh("sgdisk", "-n", "1:2048:+2M", "-c", "1:boot", str(path))
    sh("sgdisk", "-n", "2:0:+1M", "-c", "2:ubootenv", str(path))
    sh("sgdisk", "-n", "3:0:+4M", "-c", "3:rootA", str(path))
    sh("sgdisk", "-n", "4:0:+4M", "-c", "4:rootB", str(path))
    sh("sgdisk", "-n", f"5:0:+{data_mib}M", "-c", "5:data", str(path))
    with open(path, "r+b") as f:
        f.truncate(card_mib * MIB)


def geometry(path: Path):
    out = subprocess.run(["parted", "-sm", str(path), "unit", "s", "print"],
                         capture_output=True, text=True).stdout.splitlines()
    disk = int(out[1].split(":")[1].rstrip("s"))
    end = next(int(l.split(":")[2].rstrip("s")) for l in out[2:] if l.startswith("5:"))
    return disk, end


@pytest.fixture(params=SHELLS, ids=[s[0] for s in SHELLS])
def shell(request):
    return request.param


def test_grows_partition_on_larger_card(tmp_path, shell):
    disk = tmp_path / "card.img"
    make_disk(disk, image_mib=32, card_mib=64, data_mib=8)
    r, log = call(tmp_path, shell, f'grow_data_part "{disk}" 5')
    assert "rc=0" in r.stdout, (r.stdout, r.stderr, log)
    size, end = geometry(disk)
    assert size - 34 - end < 2048, (size, end)
    assert any("now ends at the end" in l for l in log)
    v = subprocess.run(["sgdisk", "-v", str(disk)], capture_output=True, text=True)
    assert "No problems found" in v.stdout, v.stdout


def test_second_boot_does_nothing(tmp_path, shell):
    disk = tmp_path / "card.img"
    make_disk(disk, image_mib=32, card_mib=64, data_mib=8)
    call(tmp_path, shell, f'grow_data_part "{disk}" 5')
    (tmp_path / "preinit.log").unlink()
    before = disk.read_bytes()
    r, log = call(tmp_path, shell, f'grow_data_part "{disk}" 5')
    assert "rc=0" in r.stdout
    assert log == []
    assert disk.read_bytes() == before


def test_card_same_size_as_image_does_nothing(tmp_path, shell):
    disk = tmp_path / "card.img"
    make_disk(disk, image_mib=32, card_mib=32, data_mib=8)
    sh("sgdisk", "-d", "5", str(disk))
    sh("sgdisk", "-n", "5:0:0", "-c", "5:data", str(disk))
    before = disk.read_bytes()
    r, log = call(tmp_path, shell, f'grow_data_part "{disk}" 5')
    assert "rc=0" in r.stdout and log == []
    assert disk.read_bytes() == before


def test_unreadable_table_is_logged_not_fatal(tmp_path, shell):
    disk = tmp_path / "card.img"
    make_disk(disk, image_mib=32, card_mib=64, data_mib=8)
    r, log = call(tmp_path, shell, f'grow_data_part "{disk}" 9; echo after')
    assert "rc=0" in r.stdout and "after" in r.stdout
    assert any("cannot read the partition table" in l for l in log)


def test_grows_filesystem_to_partition(tmp_path, shell):
    fs = tmp_path / "data.img"
    with open(fs, "wb") as f:
        f.truncate(8 * MIB)
    sh("mkfs.ext4", "-q", "-F", "-L", "data", str(fs))
    with open(fs, "r+b") as f:
        f.truncate(24 * MIB)
    sh("e2fsck", "-fp", str(fs))
    r, log = call(tmp_path, shell, f'grow_data_fs "{fs}" {24 * MIB}')
    assert "rc=0" in r.stdout, (r.stdout, r.stderr, log)
    out = subprocess.run(["dumpe2fs", "-h", str(fs)], capture_output=True, text=True).stdout
    count = int(re.search(r"^Block count:\s+(\d+)", out, re.M).group(1))
    bs = int(re.search(r"^Block size:\s+(\d+)", out, re.M).group(1))
    assert count * bs == 24 * MIB
    assert any("grown to its partition" in l for l in log)


def test_full_filesystem_is_left_alone(tmp_path, shell):
    fs = tmp_path / "data.img"
    with open(fs, "wb") as f:
        f.truncate(16 * MIB)
    sh("mkfs.ext4", "-q", "-F", "-L", "data", str(fs))
    before = fs.read_bytes()
    r, log = call(tmp_path, shell, f'grow_data_fs "{fs}" {16 * MIB}')
    assert "rc=0" in r.stdout and log == []
    assert fs.read_bytes() == before
