"""Tests for iotgw_fragment_gate, the fragment-honoured check in
meta-iot-gateway/classes/iotgw-kernel-fragments.bbclass.

The function is extracted from the class by name and run with bash, so the
test exercises the shipped shell text, not a copy.
"""
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
BBCLASS = REPO / "meta-iot-gateway/classes/iotgw-kernel-fragments.bbclass"


def gate_function() -> str:
    text = BBCLASS.read_text()
    m = re.search(r"^iotgw_fragment_gate\(\) \{\n.*?^\}\n", text, re.S | re.M)
    assert m, "iotgw_fragment_gate() not found in the bbclass"
    return m.group(0)


def run_gate(tmp_path: Path, config: str, fragments: dict) -> subprocess.CompletedProcess:
    cfg = tmp_path / ".config"
    cfg.write_text(config)
    paths = []
    for name, body in fragments.items():
        p = tmp_path / name
        p.write_text(body)
        paths.append(str(p))
    script = gate_function() + '\niotgw_fragment_gate "$@"\n'
    return subprocess.run(["bash", "-c", script, "gate", str(cfg), *paths],
                          capture_output=True, text=True)


def test_pass_when_all_requests_hold(tmp_path):
    r = run_gate(tmp_path,
                 "CONFIG_A=y\nCONFIG_B=m\n# CONFIG_C is not set\nCONFIG_N=30\n",
                 {"f.cfg": "CONFIG_A=y\nCONFIG_B=m\n# CONFIG_C is not set\nCONFIG_N=30\n"})
    assert r.returncode == 0, r.stdout + r.stderr


def test_dependency_dropped_request_fails_while_request_is_kept(tmp_path):
    # thermal.cfg keeps requesting BCM2711_THERMAL=y; a later fragment disables
    # its dependency, so kconfig drops it from the final config.
    r = run_gate(tmp_path,
                 "# CONFIG_THERMAL is not set\nCONFIG_OTHER=y\n",
                 {"thermal.cfg": "CONFIG_THERMAL=y\nCONFIG_BCM2711_THERMAL=y\n",
                  "dep.cfg": "# CONFIG_THERMAL is not set\n"})
    assert r.returncode == 1
    assert "thermal.cfg: CONFIG_BCM2711_THERMAL requested y, final not set" in r.stdout
    # THERMAL's winning request is dep.cfg's "not set", which holds.
    assert "CONFIG_THERMAL " not in r.stdout


def test_n_and_not_set_and_absent_are_equivalent(tmp_path):
    r = run_gate(tmp_path,
                 "# CONFIG_A is not set\nCONFIG_Z=y\n",
                 {"f.cfg": "CONFIG_A=n\nCONFIG_B=n\n# CONFIG_C is not set\n"})
    assert r.returncode == 0, r.stdout


def test_not_set_request_but_enabled_fails(tmp_path):
    r = run_gate(tmp_path, "CONFIG_SPI_SPIDEV=m\n",
                 {"tpm.cfg": "# CONFIG_SPI_SPIDEV is not set\n"})
    assert r.returncode == 1
    assert "tpm.cfg: CONFIG_SPI_SPIDEV requested not set, final m" in r.stdout


def test_only_the_last_request_for_a_symbol_is_checked(tmp_path):
    r = run_gate(tmp_path, "CONFIG_TUN=m\n",
                 {"a.cfg": "CONFIG_TUN=y\n", "b.cfg": "CONFIG_TUN=m\n"})
    assert r.returncode == 0, r.stdout


def test_int_value_must_match_exactly(tmp_path):
    r = run_gate(tmp_path, "CONFIG_ARCH_MMAP_RND_BITS=18\n",
                 {"sec.cfg": "CONFIG_ARCH_MMAP_RND_BITS=30\n"})
    assert r.returncode == 1
    assert "sec.cfg: CONFIG_ARCH_MMAP_RND_BITS requested 30, final 18" in r.stdout


def test_string_value_must_match_exactly(tmp_path):
    r = run_gate(tmp_path, 'CONFIG_LSM="landlock,selinux"\n',
                 {"sec.cfg": 'CONFIG_LSM="landlock,yama,selinux"\n'})
    assert r.returncode == 1
    assert 'CONFIG_LSM requested "landlock,yama,selinux", final "landlock,selinux"' in r.stdout


def test_comments_and_blank_lines_are_ignored(tmp_path):
    r = run_gate(tmp_path, "CONFIG_A=y\n",
                 {"f.cfg": "# a comment mentioning CONFIG_B=y in prose\n\n#CONFIG_C=y\nCONFIG_A=y\n"})
    assert r.returncode == 0, r.stdout


@pytest.mark.parametrize("trailing", [" ", "\t"])
def test_trailing_whitespace_in_fragment_is_ignored(tmp_path, trailing):
    r = run_gate(tmp_path, "CONFIG_A=y\n", {"f.cfg": f"CONFIG_A=y{trailing}\n"})
    assert r.returncode == 0, r.stdout
