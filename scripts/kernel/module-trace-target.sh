#!/bin/sh
# Record every kernel module load during a feature run, WITH the process that
# asked for it. Runs on the target as root. Three sources, correlated by time:
#
#   module:module_request  fires in the context of the task that triggered an
#                          in-kernel autoload (request_module): socket(AF_xxx),
#                          a filesystem mount, a netfilter target, a crypto
#                          algorithm, ... The comm/pid on that line IS the
#                          requester. call_site names the kernel path.
#   module:module_load     fires when the module is live; the comm/pid is the
#                          LOADER: (udev-worker) for hardware-driven loads,
#                          systemd-modules for modules-load.d, modprobe for the
#                          kernel.modprobe usermode helper, or an admin shell.
#   kernel.modprobe wrapper (optional, --wrap): logs every usermode-helper
#                          invocation with the module name and the environment
#                          the kernel passes (MODPROBE_MODULE); udev loads do
#                          not pass through it (libkmod in-process), the
#                          tracepoints cover those.
#
# The boot-time loads happen before this can start: take them from the first
# `lsmod` snapshot (`start` records it) and from `journalctl -b -u
# systemd-modules-load` + `udevadm info -e | grep MODALIAS`. For a boot-complete
# trace, the dev image would need `trace_event=module:module_request,module:module_load`
# on the (signed) kernel command line; not done here.
#
# Usage (on the board):
#   module-trace-target.sh start [--wrap]      # begin recording to /data/module-trace/<utc>/
#   ... run the feature set: Wi-Fi reconnect, firewall reload, RAUC A->B, BT on/off, TPM, containers ...
#   module-trace-target.sh stop                # final snapshot + summary (module -> requester(s) -> loader)
#   module-trace-target.sh summary <dir>       # re-summarise an old run
#
# Output: trace.log (raw trace_pipe), lsmod.start/lsmod.stop, modprobe-wrapper.log
# (with --wrap), summary.tsv (module, first_request_comm:pid, call_site, loader_comm:pid).
# Everything is under /data/module-trace so it survives the reboot that a RAUC
# install triggers; start it again after the reboot to cover slot B.
set -u
TRACEFS=/sys/kernel/tracing
BASE=/data/module-trace
STATE=/run/module-trace
WRAP=/run/module-trace/modprobe-wrap.sh

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "module-trace: $*" >&2; exit 1; }

do_start() {
    wrap=0; [ "${1:-}" = "--wrap" ] && wrap=1
    [ "$(id -u)" -eq 0 ] || die "run as root"
    mountpoint -q "$TRACEFS" || mount -t tracefs tracefs "$TRACEFS" || die "no tracefs"
    [ -d "$TRACEFS/events/module" ] || die "kernel has no module tracepoints"
    [ -e "$STATE/dir" ] && die "already running ($(cat "$STATE/dir")); stop it first"
    run="$BASE/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$run" "$STATE"
    echo "$run" > "$STATE/dir"

    lsmod > "$run/lsmod.start"
    { echo "# boot-time loaders (modules-load.d) and hardware MODALIAS requests seen by udev"; \
      journalctl -b -u systemd-modules-load --no-pager 2>/dev/null; \
      udevadm info -e 2>/dev/null | grep -E '^E: (MODALIAS|DRIVER)=' | sort | uniq -c; } > "$run/boot-context.txt" 2>&1

    echo 0 > "$TRACEFS/tracing_on"
    echo > "$TRACEFS/trace"
    echo boot > "$TRACEFS/trace_clock" 2>/dev/null || true
    echo 1 > "$TRACEFS/events/module/module_request/enable"
    echo 1 > "$TRACEFS/events/module/module_load/enable"
    echo 1 > "$TRACEFS/events/module/module_free/enable"
    echo 1 > "$TRACEFS/tracing_on"
    # trace_pipe blocks until data arrives; keep the reader alive across the run.
    nohup cat "$TRACEFS/trace_pipe" >> "$run/trace.log" 2>/dev/null < /dev/null &
    echo $! > "$STATE/reader.pid"

    if [ "$wrap" -eq 1 ]; then
        real=$(readlink -f "$(sysctl -n kernel.modprobe)")
        cat > "$WRAP" <<EOF
#!/bin/sh
# kernel.modprobe wrapper: log the usermode-helper call, then run the real modprobe.
printf '%s pid=%s ppid=%s args=%s MODPROBE_MODULE=%s\\n' "\$(date -u +%FT%TZ)" "\$\$" "\$PPID" "\$*" "\${MODPROBE_MODULE:-}" >> "$run/modprobe-wrapper.log"
exec "$real" "\$@"
EOF
        chmod 0755 "$WRAP"
        echo "$real" > "$STATE/modprobe.real"
        sysctl -q -w kernel.modprobe="$WRAP"
    fi
    echo "module-trace: recording into $run (reader pid $(cat "$STATE/reader.pid"), wrapper=$wrap)"
}

do_stop() {
    [ -e "$STATE/dir" ] || die "not running"
    run=$(cat "$STATE/dir")
    if [ -e "$STATE/modprobe.real" ]; then
        sysctl -q -w kernel.modprobe="$(cat "$STATE/modprobe.real")"
    fi
    echo 0 > "$TRACEFS/tracing_on"
    sleep 1
    kill "$(cat "$STATE/reader.pid")" 2>/dev/null
    for e in module_request module_load module_free; do echo 0 > "$TRACEFS/events/module/$e/enable"; done
    # Anything left in the ring buffer that trace_pipe did not drain.
    cat "$TRACEFS/trace" >> "$run/trace.log" 2>/dev/null
    lsmod > "$run/lsmod.stop"
    rm -rf "$STATE"
    do_summary "$run"
}

do_summary() {
    run=${1:?run dir}
    [ -f "$run/trace.log" ] || die "no trace.log in $run"
    # trace_pipe line shape:
    #   <comm>-<pid> [cpu] .... <ts>: module_request: <name> wait=1 call_site=<fn>
    #   <comm>-<pid> [cpu] .... <ts>: module_load: <name> <taints>
    awk -v OUT="$run/summary.tsv" '
        function who(s) { sub(/^ +/, "", s); return s }
        /: module_request: / {
            comm = who($0); sub(/ +\[.*/, "", comm)
            name = $0; sub(/.*module_request: /, "", name); split(name, a, " "); name = a[1]
            site = $0; sub(/.*call_site=/, "", site)
            if (!(name in req)) { req[name] = comm; reqsite[name] = site } else if (index(req[name], comm) == 0) { req[name] = req[name] "," comm }
            mods[name] = 1
        }
        /: module_load: / {
            comm = who($0); sub(/ +\[.*/, "", comm)
            name = $0; sub(/.*module_load: /, "", name); split(name, a, " "); name = a[1]
            if (!(name in ld)) ld[name] = comm; else if (index(ld[name], comm) == 0) ld[name] = ld[name] "," comm
            mods[name] = 1
        }
        END {
            print "module\trequested_by(comm-pid)\tcall_site\tloaded_by(comm-pid)" > OUT
            for (m in mods) printf "%s\t%s\t%s\t%s\n", m, (m in req ? req[m] : "-"), (m in reqsite ? reqsite[m] : "-"), (m in ld ? ld[m] : "-") >> OUT
        }' "$run/trace.log"
    # Modules present at stop that were not present at start, and the reverse
    # (POSIX sh: no process substitution, so two sorted temp lists).
    awk 'NR>1{print $1}' "$run/lsmod.start" | sort > "$run/.start.lst"
    awk 'NR>1{print $1}' "$run/lsmod.stop" | sort > "$run/.stop.lst"
    { echo "# loaded during the run (in lsmod.stop, not in lsmod.start):"; \
      comm -13 "$run/.start.lst" "$run/.stop.lst"; \
      echo "# unloaded during the run:"; \
      comm -23 "$run/.start.lst" "$run/.stop.lst"; } > "$run/lsmod.delta" 2>/dev/null
    rm -f "$run/.start.lst" "$run/.stop.lst"
    echo "module-trace: summary -> $run/summary.tsv ($(($(wc -l < "$run/summary.tsv") - 1)) modules with events), delta -> $run/lsmod.delta"
    column -t -s "$(printf '\t')" "$run/summary.tsv" 2>/dev/null | head -60
}

case "${1:-}" in
    start)   shift; do_start "$@" ;;
    stop)    do_stop ;;
    summary) do_summary "${2:-}" ;;
    *)       usage ;;
esac
