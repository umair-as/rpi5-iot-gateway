## Reusable adaptive slot geometry validation for RAUC bundle recipes.
##
## This class enforces that rootA/rootB partition sizes in IoT Gateway RAUC
## WKS layouts are exact multiples of 4096 bytes when adaptive mode is on.

python do_iotgw_rauc_alignment_check() {
    import glob
    import os
    import re

    if d.getVar("IOTGW_RAUC_ADAPTIVE") != "1":
        bb.note("Adaptive alignment gate skipped (IOTGW_RAUC_ADAPTIVE != 1)")
        return

    alignment = 4096

    def parse_size_to_bytes(size_token):
        match = re.match(r"^\s*([0-9]+)\s*([KMGT]?)\s*$", size_token)
        if not match:
            bb.fatal("Invalid WKS --size value for adaptive gate: %s" % size_token)

        value = int(match.group(1))
        unit = match.group(2).upper()
        factor = {
            "": 1,
            "K": 1024,
            "M": 1024 * 1024,
            "G": 1024 * 1024 * 1024,
            "T": 1024 * 1024 * 1024 * 1024,
        }[unit]
        return value * factor

    def resolve_wks_file(wks_name):
        bbpath = d.getVar("BBPATH") or ""
        for relpath in (wks_name, os.path.join("wic", wks_name)):
            candidate = bb.utils.which(bbpath, relpath)
            if candidate:
                return candidate

        search_paths = (d.getVar("WKS_SEARCH_PATH") or "").split(":")
        for base in search_paths:
            if not base:
                continue
            candidate = os.path.join(base, wks_name)
            if os.path.isfile(candidate):
                return candidate

        return None

    def collect_root_slot_sizes(wks_path):
        root_sizes = {}
        with open(wks_path, encoding="utf-8") as handle:
            for lineno, line in enumerate(handle, 1):
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or not stripped.startswith("part "):
                    continue

                label_match = re.search(r"--label\s+([^\s]+)", stripped)
                if not label_match:
                    continue

                label = label_match.group(1)
                if label not in ("rootA", "rootB"):
                    continue

                size_match = re.search(r"--(?:fixed-size|size)\s+([0-9]+\s*[KMGT]?)\b", stripped)
                if not size_match:
                    bb.fatal(
                        "Adaptive alignment gate: missing --size/--fixed-size for %s in %s:%d"
                        % (label, wks_path, lineno)
                    )

                size_token = size_match.group(1)
                root_sizes[label] = (size_token, parse_size_to_bytes(size_token), lineno)

        return root_sizes

    # Keep guard deterministic across bundle contexts: discover IoT GW RAUC
    # layouts from the layer's wic directory, instead of hardcoding filenames.
    wks_paths = []

    thisdir = d.getVar("THISDIR") or ""
    layer_wic_dir = os.path.normpath(os.path.join(thisdir, "..", "wic"))
    if os.path.isdir(layer_wic_dir):
        for candidate in sorted(glob.glob(os.path.join(layer_wic_dir, "iot-gw-rauc*.wks.in"))):
            wks_paths.append(candidate)

    # Fallback for unusual parse contexts where THISDIR is not the class dir.
    if not wks_paths:
        bbpath = d.getVar("BBPATH") or ""
        for base in bbpath.split(":"):
            if not base:
                continue
            wic_dir = os.path.join(base, "wic")
            if not os.path.isdir(wic_dir):
                continue
            for candidate in sorted(glob.glob(os.path.join(wic_dir, "iot-gw-rauc*.wks.in"))):
                wks_paths.append(candidate)

    # Deduplicate while preserving order.
    unique_paths = []
    for path in wks_paths:
        if path not in unique_paths:
            unique_paths.append(path)
    wks_paths = unique_paths

    if not wks_paths:
        bb.fatal(
            "Adaptive alignment gate could not find IoT GW RAUC WKS layouts to validate. "
            "Checked layer wic/ directory and BBPATH fallback."
        )

    validated = []
    for wks_path in wks_paths:
        root_sizes = collect_root_slot_sizes(wks_path)
        missing = [slot for slot in ("rootA", "rootB") if slot not in root_sizes]
        if missing:
            bb.fatal(
                "Adaptive alignment gate failed: missing root slots in %s: %s"
                % (wks_path, ", ".join(missing))
            )

        for label in ("rootA", "rootB"):
            size_token, size_bytes, lineno = root_sizes[label]
            if size_bytes % alignment != 0:
                bb.fatal(
                    "Adaptive alignment gate failed for %s in %s:%d: --size %s resolves to %d bytes "
                    "(must be multiple of %d)"
                    % (label, wks_path, lineno, size_token, size_bytes, alignment)
                )

        validated.append(os.path.basename(wks_path))

    bb.note("Adaptive alignment gate passed for: %s" % ", ".join(validated))
}

addtask iotgw_rauc_alignment_check before do_configure after do_patch
