# kernel-hardening-checker report on the resolved kernel .config.
#
# REPORT-ONLY. The task compares the checker's FAIL rows with the board
# baseline (files/khc/<MACHINE>.baseline.json) and writes a report plus a
# baseline proposal; it never fails the build. Run it with
# `make kernel-hardening-report` (bitbake virtual/kernel -c iotgw_khc_report).
#
# The task is not anchored in the default task chain, so adding it or editing
# the baseline changes no other task signature and rebuilds nothing; anchored
# after do_configure, which has no sstate, it would force a kernel unpack and
# configure on every image build that otherwise restores the kernel. The
# checker is a task-level dependency rather than a DEPENDS entry: DEPENDS would
# enter every kernel task signature and recompile the kernel.
#
# Turning this into an enforcing gate means: commit a baseline with a reason
# for every entry, drop --report-only, and anchor the task before do_compile.
# Anchored there, every baseline edit re-runs compilation, so batch the
# reason edits before anchoring.

IOTGW_KHC_DIR = "${FILE_DIRNAME}/files/khc"
IOTGW_KHC_BASELINE ?= "${IOTGW_KHC_DIR}/${MACHINE}.baseline.json"
IOTGW_KHC_OUTDIR = "${WORKDIR}/khc"

python do_iotgw_khc_report() {
    import os
    import subprocess

    outdir = d.getVar('IOTGW_KHC_OUTDIR')
    os.makedirs(outdir, exist_ok=True)
    native_bin = d.getVar('STAGING_BINDIR_NATIVE')
    cmd = [os.path.join(native_bin, 'python3-native', 'python3'),
           os.path.join(d.getVar('IOTGW_KHC_DIR'), 'khc-gate.py'),
           '--report-only',
           '--checker', os.path.join(native_bin, 'kernel-hardening-checker'),
           '--config', os.path.join(d.getVar('B'), '.config'),
           '--baseline', d.getVar('IOTGW_KHC_BASELINE'),
           '--report', os.path.join(outdir, 'khc-report.md'),
           '--propose', os.path.join(outdir, 'khc-baseline.proposed.json')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        bb.plain(line)
    if r.returncode != 0:
        bb.warn('iotgw khc report: checker run failed (rc=%d); report-only, not failing the build'
                % r.returncode)
        return
    bb.plain('iotgw khc report: %s/khc-report.md, proposal %s/khc-baseline.proposed.json'
             % (outdir, outdir))
}
addtask iotgw_khc_report after do_configure
do_iotgw_khc_report[depends] += "kernel-hardening-checker-native:do_populate_sysroot python3-native:do_populate_sysroot"
# Always re-run: an on-demand report must reflect the current baseline file.
do_iotgw_khc_report[nostamp] = "1"
do_iotgw_khc_report[dirs] = "${B}"
