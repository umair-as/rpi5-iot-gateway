"""Tests for policy-raw-type-check.py: fixture policies, no build needed."""

import importlib.util
import pathlib

import pytest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent / "policy-raw-type-check.py"
REPO = HERE.parents[2]
POLICY = REPO / "meta-iot-gateway/recipes-security/refpolicy/files/policy"

spec = importlib.util.spec_from_file_location("raw_type_check", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def run(tmp_path, text, name="t.te"):
    p = tmp_path / name
    p.write_text(text)
    return [t for _, t in mod.check(str(p))]


def test_shipped_policy_is_clean():
    for f in ("iotgw.te", "iotgw.if"):
        assert mod.check(str(POLICY / f)) == [], f


def test_missing_require_is_reported(tmp_path):
    assert run(tmp_path, "type a_t;\nallow a_t var_spool_t:dir mounton;\n") == ["var_spool_t"]


def test_every_missing_type_is_reported(tmp_path):
    src = "type a_t;\nallow a_t var_spool_t:dir mounton;\nallow a_t var_t:chr_file unlink;\n"
    assert run(tmp_path, src) == ["var_spool_t", "var_t"]


def test_top_level_require_covers_file(tmp_path):
    src = "type a_t;\ngen_require(`\n\ttype b_t;\n')\nallow a_t b_t:file read;\n"
    assert run(tmp_path, src) == []


def test_require_in_optional_does_not_leak_out(tmp_path):
    src = (
        "type a_t;\n"
        "optional_policy(`\n"
        "\tgen_require(`\n\t\ttype b_t;\n\t')\n"
        "\tallow a_t b_t:file read;\n"
        "')\n"
        "allow a_t b_t:dir search;\n"
    )
    assert run(tmp_path, src) == ["b_t"]


def test_outer_require_covers_optional(tmp_path):
    src = (
        "type a_t;\ngen_require(`\n\ttype b_t;\n')\n"
        "optional_policy(`\n\tallow a_t b_t:file read;\n')\n"
    )
    assert run(tmp_path, src) == []


def test_self_and_sets(tmp_path):
    src = "type a_t;\ngen_require(`\n\ttype b_t;\n')\nallow a_t { self b_t c_t }:file read;\n"
    assert run(tmp_path, src) == ["c_t"]


def test_multiline_rule(tmp_path):
    src = "type a_t;\nallow a_t\n\tb_t:file\n\t{ read open };\n"
    assert run(tmp_path, src) == ["b_t"]


def test_type_transition_new_type(tmp_path):
    src = (
        "type a_t;\ngen_require(`\n\ttype tmp_t;\n')\n"
        'type_transition a_t tmp_t:file new_t "name";\n'
    )
    assert run(tmp_path, src) == ["new_t"]


def test_support_macros(tmp_path):
    src = "type a_t;\nmanage_files_pattern(a_t, b_t, b_t)\ncan_exec(c_t, a_t)\n"
    assert run(tmp_path, src) == ["b_t", "c_t"]


def test_role_allow_is_not_a_type_rule(tmp_path):
    src = "gen_require(`\n\trole user_r, system_r;\n')\nallow user_r system_r;\n"
    assert run(tmp_path, src) == []


def test_interface_calls_are_not_raw(tmp_path):
    assert run(tmp_path, "type a_t;\nfiles_read_etc_files(a_t)\n") == []


def test_interface_body_needs_own_require(tmp_path):
    src = (
        "interface(`x_read',`\n"
        "\tgen_require(`\n\t\ttype x_t;\n\t')\n"
        "\tallow $1 x_t:file read;\n"
        "')\n"
        "interface(`y_read',`\n"
        "\tallow $1 x_t:file read;\n"
        "')\n"
    )
    assert run(tmp_path, src, "t.if") == ["x_t"]


def test_comment_apostrophe_does_not_close_block(tmp_path):
    src = (
        "type a_t;\n"
        "optional_policy(`\n"
        "\t# it's fine')\n"
        "\tgen_require(`\n\t\ttype b_t;\n\t')\n"
        "\tallow a_t b_t:file read;\n"
        "')\n"
    )
    assert run(tmp_path, src) == []


def test_cli_exit_status(tmp_path, capsys):
    bad = tmp_path / "bad.te"
    bad.write_text("type a_t;\nallow a_t b_t:file read;\n")
    assert mod.main(["x", str(bad)]) == 1
    assert "b_t" in capsys.readouterr().out
    good = tmp_path / "good.te"
    good.write_text("type a_t;\nallow a_t self:file read;\n")
    assert mod.main(["x", str(good)]) == 0
