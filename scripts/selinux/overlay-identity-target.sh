#!/bin/bash
# Enforcing regression check for object creation through the /var overlays.
#
# /var/lib, /var/cache, /var/spool and /srv are overlays mounted by
# mount-copybind in iotgw_overlay_t. overlayfs repeats each create as that
# mounter while the new object keeps the caller's SELinux user, so the
# mounter needs the object-identity exemption or admins cannot create anything
# there. The negative cases show the exemption stays with the mounter: a caller
# without the rights is still refused.
#
# The shell's domain selects the cases:
#   root in sysadm_t  allow cases: IOTGW_SSH_USER=devel run-target-checks.sh <host> overlay-identity
#   root in staff_t   deny cases:  IOTGW_SSH_USER=root  run-target-checks.sh <host> overlay-identity
# Run the allow cases first: they leave the fixture the deny cases use. It sits
# in the volatile /var/lib overlay and is gone at the next boot.
#
# Exit status: 0 if no check FAILed.

if ! type say_pass >/dev/null 2>&1; then
    # shellcheck source=../lib/target-check.sh
    . "$(cd "$(dirname "$0")" && pwd)/../lib/target-check.sh"
fi

CTX=$(id -Z 2>/dev/null)
CALLER_USER=${CTX%%:*}
DOMAIN=$(printf '%s' "$CTX" | cut -d: -f3)
START=$(date +%s)
MODULE=iotgw_overlay_regress
WORKDIR=
FIXTURE=/var/lib/iotgw-overlay-regress-fixture

cleanup() {
    [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
    if [ "$DOMAIN" = sysadm_t ]; then
        semodule -l 2>/dev/null | grep -qx "$MODULE" && semodule -X 400 -r "$MODULE" >/dev/null 2>&1
    fi
}
trap cleanup EXIT

section "context"
printf '    shell: %s\n' "$CTX"
if [ "$(getenforce 2>/dev/null)" != Enforcing ]; then
    say_fail "board is not enforcing; a permissive board proves nothing here"
    summary
    exit $?
fi
say_pass "enforcing"

allow_cases() {
    rm -rf "$FIXTURE"
    for tree in /var/lib /var/cache /var/spool /srv; do
        section "allow: admin creates through the overlay at $tree"
        d=$tree/iotgw-overlay-regress.$$
        if mkdir "$d" 2>/dev/null; then
            say_pass "mkdir"
            u=$(stat -c %C "$d" | cut -d: -f1)
            [ "$u" = "$CALLER_USER" ] && say_pass "keeps the creator's user ($u)" \
                || say_fail "has user $u, creator is $CALLER_USER"
            if : > "$d/file" 2>/dev/null; then say_pass "file"; else say_fail "file"; fi
            if ln -s file "$d/link" 2>/dev/null; then say_pass "symlink"; else say_fail "symlink"; fi
            if mkfifo "$d/fifo" 2>/dev/null; then say_pass "fifo"; else say_fail "fifo"; fi
            if chcon -t tmp_t "$d/file" 2>/dev/null; then say_pass "type-only relabel"; else say_fail "type-only relabel"; fi
            if chcon -u system_u "$d/file" 2>/dev/null; then say_pass "user relabel (sysadm_t is exempt)"; else say_fail "user relabel"; fi
            rm -rf "$d"
        else
            say_fail "mkdir refused for $CALLER_USER"
        fi
    done

    section "allow: replacing and removing an entry of the lower layer"
    # Needs a whiteout, created as the mounter. The overlay is volatile, so a
    # reboot restores the entry even if the restore below fails.
    LOWER=/var/lib/sepolgen/perm_map
    if [ -f "$LOWER" ]; then
        BK=$(mktemp /tmp/iotgw-overlay-lower.XXXXXX)
        if cp -a "$LOWER" "$BK" 2>/dev/null; then
            if mv "$LOWER" "$LOWER.moved" 2>/dev/null; then say_pass "rename"; else say_fail "rename of a lower entry"; fi
            if cp -a "$BK" "$LOWER" 2>/dev/null; then say_pass "recreate over a whiteout"; else say_fail "recreate over a whiteout"; fi
            if rm -f "$LOWER.moved" "$LOWER" 2>/dev/null && [ ! -e "$LOWER" ]; then say_pass "remove"; else say_fail "remove of a lower entry"; fi
            cp -a "$BK" "$LOWER" && restorecon "$LOWER" 2>/dev/null
        else
            say_fail "cannot back up $LOWER"
        fi
        rm -f "$BK"
    else
        say_skip "lower entry" "$LOWER not in this image"
    fi

    section "allow: semodule reaches its store"
    # /tmp: a file created under /run can get a type semanage_t may not read.
    WORKDIR=$(mktemp -d /tmp/iotgw-overlay-regress.XXXXXX) || { say_fail "cannot create a work directory"; return; }
    CIL=$WORKDIR/$MODULE.cil
    printf '(type iotgw_overlay_regress_t)\n(roletype object_r iotgw_overlay_regress_t)\n' > "$CIL"
    if err=$(semodule -X 400 -i "$CIL" 2>&1); then
        say_pass "semodule -i"
        if semodule -l | grep -qx "$MODULE"; then say_pass "module listed"; else say_fail "module not listed"; fi
        if semodule -X 400 -r "$MODULE" 2>/dev/null; then say_pass "semodule -r"; else say_fail "semodule -r"; fi
    else
        case "$err" in
            # The store lives in the overlay's lower layer, and a kernel without
            # CONFIG_OVERLAY_FS_REDIRECT_DIR cannot rename such a directory.
            *"Invalid cross-device link"*) say_skip "semodule commit" "store rename needs overlay redirect_dir; the store was created and written" ;;
            *) say_fail "semodule -i: $err" ;;
        esac
    fi

    section "denials against the mounter during the run"
    if [ -r /var/log/audit/audit.log ]; then
        n=$(awk -v s="$START" -F'[(.]' '/^type=AVC/ && /iotgw_overlay_t/ { if ($2+0 >= s) c++ } END { print c+0 }' /var/log/audit/audit.log)
        [ "$n" = 0 ] && say_pass "no iotgw_overlay_t denial" || say_fail "$n iotgw_overlay_t denial(s) during the run"
    else
        say_fail "audit.log not readable"
    fi

    # Left in place for the deny cases, which staff_t cannot set up. The
    # object's user must be the deny caller's (root) to isolate the check.
    section "fixture for the deny cases"
    if mkdir "$FIXTURE" 2>/dev/null && : > "$FIXTURE/f" 2>/dev/null \
        && chcon -u root -t container_file_t "$FIXTURE/f" 2>/dev/null; then
        say_pass "created $(stat -c %C "$FIXTURE/f")"
    else
        say_fail "could not create the fixture"
    fi
}

deny_cases() {
    section "deny: the exemption does not reach the caller"
    [ "$(id -u)" = 0 ] || { say_fail "needs uid 0, so that only SELinux can refuse"; return; }
    say_pass "uid 0 in $DOMAIN"
    f=$FIXTURE/f
    case "$(stat -c %C "$f" 2>/dev/null)" in
        root:object_r:container_file_t:*) say_pass "fixture present" ;;
        *) say_fail "fixture missing or wrong: run the allow cases first"; return ;;
    esac
    if chcon -t container_ro_file_t "$f" 2>/dev/null; then
        say_pass "control: type-only relabel through the overlay succeeds"
    else
        say_fail "control: type-only relabel refused, so the next case would prove nothing"
        return
    fi
    err=$(chcon -u system_u "$f" 2>&1); rc=$?
    u=$(stat -c %C "$f" | cut -d: -f1)
    if [ "$rc" -ne 0 ] && [ "$u" = root ]; then
        case "$err" in
            *ermi*) say_pass "user relabel refused: $err" ;;
            *) say_fail "user relabel failed for another reason: $err" ;;
        esac
    else
        say_fail "$DOMAIN changed an object's SELinux user: the exemption reached the caller"
    fi
}

case "$DOMAIN" in
    sysadm_t) allow_cases ;;
    staff_t) deny_cases ;;
    *) say_skip "cases" "shell domain $DOMAIN selects none (need sysadm_t or staff_t as root)" ;;
esac

summary
