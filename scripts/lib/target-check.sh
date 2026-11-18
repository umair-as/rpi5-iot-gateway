#!/bin/bash
# Reporting helpers shared by the on-target check scripts (*-target.sh).
#
# The check scripts run ON the gateway, usually streamed over SSH by
# scripts/run-target-checks.sh, which sends this file and the check script as
# one stdin stream. Run directly on a device, a check script sources this file
# from ../lib relative to itself, so copy both when copying by hand.
#
# Contract for a check script:
#   - report each assertion with say_pass / say_fail / say_skip
#   - end with `summary` (optionally passing extra "key: value" lines); its
#     return status is the script's exit status: non-zero on any FAIL
#
# Output: human-readable PASS/FAIL/SKIP lines, then one machine-readable line
#   RESULT pass=<n> fail=<n> skip=<n>
# for release and CI regression runs to parse (anchor on "^RESULT ").

PASS=0
FAIL=0
SKIP=0

# Separator between a SKIP subject and its reason; a script whose output is
# ASCII-only overrides it.
TC_SKIP_SEP="${TC_SKIP_SEP:- — }"

say_pass() { printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1)); }
say_fail() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
say_skip() { printf '  \e[33mSKIP\e[0m %s%s%s\n' "$1" "$TC_SKIP_SEP" "${2:-}"; SKIP=$((SKIP+1)); }
section()  { printf '\n== %s ==\n' "$1"; }

# Run a command, pass if exit 0
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then say_pass "$name"; else say_fail "$name"; fi
}

# Run a command, capture stdout, pass if matches regex
check_match() {
    local name="$1" regex="$2"; shift 2
    local out
    out=$("$@" 2>/dev/null) || { say_fail "$name (command failed)"; return; }
    if printf '%s' "$out" | grep -qE "$regex"; then say_pass "$name"
    else say_fail "$name (no match for '$regex')"; fi
}

# Machine-readable result line; returns non-zero on any FAIL.
tc_result() {
    printf 'RESULT pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" -eq 0 ]
}

# Summary block, extra lines first, then the RESULT line.
summary() {
    local line
    printf '\n== summary ==\n'
    for line in "$@"; do printf '  %s\n' "$line"; done
    printf '  PASS: %d\n' "$PASS"
    printf '  FAIL: %d\n' "$FAIL"
    printf '  SKIP: %d\n' "$SKIP"
    tc_result
}
