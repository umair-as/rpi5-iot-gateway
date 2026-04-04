#!/usr/bin/env python3
"""Reconcile /etc overlay upper entries during RAUC slot hooks.

Modes:
- pre: create transaction metadata and basic environment validation.
- post: apply managed-path reconciliation using the just-installed slot content.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import grp
import pwd
from pathlib import Path
import shutil
import stat
import sys
from typing import Dict, Iterable, List, Optional, Tuple


STATE_DIR = Path("/data/iotgw/overlay-reconcile")
STATE_FILE = STATE_DIR / "state.tsv"
TXN_FILE = STATE_DIR / "txn.json"
BACKUP_ROOT = STATE_DIR / "backups"
UPPER_ROOT = Path("/data/overlays/etc/upper")

MANIFEST_MAIN = Path("usr/share/iotgw/overlay-reconcile/managed-paths.conf")
MANIFEST_DIR = Path("usr/share/iotgw/overlay-reconcile/managed-paths.d")

POLICIES = {"enforce", "replace_if_unmodified", "preserve", "absent", "enforce_meta"}


MetadataSpec = Tuple[str, str, int]


def log(level: str, msg: str) -> None:
    print(f"[overlay-reconcile:{level}] {msg}", file=sys.stderr)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def ensure_state_dir() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    BACKUP_ROOT.mkdir(parents=True, exist_ok=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def read_state() -> Dict[str, str]:
    state: Dict[str, str] = {}
    if not STATE_FILE.exists():
        return state
    for line in STATE_FILE.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        state[parts[0]] = parts[1]
    return state


def write_state(state: Dict[str, str]) -> None:
    tmp = STATE_FILE.with_suffix(".tsv.new")
    with tmp.open("w", encoding="utf-8") as f:
        for path in sorted(state):
            f.write(f"{path}\t{state[path]}\n")
    os.replace(tmp, STATE_FILE)


def write_txn(payload: Dict[str, object]) -> None:
    tmp = TXN_FILE.with_suffix(".json.new")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(payload, f, sort_keys=True, indent=2)
        f.write("\n")
    os.replace(tmp, TXN_FILE)


def read_txn() -> Dict[str, object]:
    if not TXN_FILE.exists():
        return {}
    try:
        return json.loads(TXN_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def sanitize_managed_path(path: str) -> str:
    if not path.startswith("/etc/"):
        raise ValueError(f"path '{path}' is outside /etc")
    norm = os.path.normpath(path)
    if norm != path:
        raise ValueError(f"path '{path}' must be normalized")
    if "/../" in path or path.endswith("/.."):
        raise ValueError(f"path '{path}' contains parent traversal")
    return path


def resolve_uid(value: str) -> int:
    if value.isdigit():
        return int(value, 10)
    return pwd.getpwnam(value).pw_uid


def resolve_gid(value: str) -> int:
    if value.isdigit():
        return int(value, 10)
    return grp.getgrnam(value).gr_gid


def parse_mode(value: str) -> int:
    raw = value.strip().lower()
    if raw.startswith("0o"):
        raw = raw[2:]
    return int(raw, 8)


def parse_manifest_flags(
    policy: str, path: str, extras: List[str]
) -> Tuple[bool, Optional[MetadataSpec]]:
    optional = False
    kv: Dict[str, str] = {}
    unknown: List[str] = []
    for token in extras:
        low = token.lower()
        if low == "optional":
            optional = True
            continue
        if "=" in token:
            k, v = token.split("=", 1)
            kv[k.strip().lower()] = v.strip()
            continue
        unknown.append(token)

    if unknown:
        raise ValueError(f"unknown manifest flags {unknown} for {path}")

    if policy != "enforce_meta":
        if kv:
            raise ValueError(f"metadata flags {sorted(kv)} are only valid with enforce_meta for {path}")
        return optional, None

    required = {"uid", "gid", "mode"}
    missing = sorted(required - set(kv))
    if missing:
        raise ValueError(f"enforce_meta missing required flags {missing} for {path}")
    extra_keys = sorted(set(kv) - required)
    if extra_keys:
        raise ValueError(f"enforce_meta has unknown keys {extra_keys} for {path}")

    try:
        mode = parse_mode(kv["mode"])
    except (KeyError, ValueError) as exc:
        raise ValueError(f"invalid enforce_meta spec for {path}: {exc}") from exc

    return optional, (kv["uid"], kv["gid"], mode)


def load_manifest_entries(slot_mount: Path) -> List[Tuple[str, str, bool, Path, Optional[MetadataSpec]]]:
    entries: List[Tuple[str, str, bool, Path, Optional[MetadataSpec]]] = []
    seen = set()
    errors: List[str] = []

    candidates: List[Path] = []
    main = slot_mount / MANIFEST_MAIN
    if main.is_file():
        candidates.append(main)
    d = slot_mount / MANIFEST_DIR
    if d.is_dir():
        candidates.extend(sorted(d.glob("*.conf")))

    for manifest in candidates:
        for raw in manifest.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                errors.append(f"invalid entry '{line}' in {manifest}")
                continue
            policy, path = parts[0], parts[1]
            if policy not in POLICIES:
                errors.append(f"unknown policy '{policy}' for {path} in {manifest}")
                continue
            optional = False
            metadata: Optional[MetadataSpec] = None
            if len(parts) > 2:
                try:
                    optional, metadata = parse_manifest_flags(policy, path, parts[2:])
                except ValueError as exc:
                    errors.append(f"{exc} in {manifest}")
                    continue
            try:
                path = sanitize_managed_path(path)
            except ValueError as exc:
                errors.append(f"{exc} in {manifest}")
                continue
            if path in seen:
                errors.append(f"duplicate managed path '{path}' in {manifest}")
                continue
            seen.add(path)
            entries.append((policy, path, optional, manifest, metadata))

    if errors:
        raise ValueError("invalid managed-path manifest entries: " + " | ".join(errors))

    return entries


def upper_path_for(managed_path: str) -> Path:
    rel = managed_path.removeprefix("/etc/")
    rel_norm = os.path.normpath(rel)
    if rel_norm.startswith("../") or rel_norm == "..":
        raise ValueError(f"managed path escapes upper root: {managed_path}")
    return UPPER_ROOT / rel_norm


def backup_and_remove(path: Path, backup_dir: Path) -> None:
    rel = path.relative_to(UPPER_ROOT)
    target = backup_dir / rel
    target.parent.mkdir(parents=True, exist_ok=True)

    if path.is_symlink():
        target.symlink_to(os.readlink(path))
        path.unlink()
        return
    if path.is_file():
        shutil.copy2(path, target)
        path.unlink()
        return
    if path.is_dir():
        shutil.copytree(path, target, dirs_exist_ok=True)
        shutil.rmtree(path)
        return
    path.unlink(missing_ok=True)


def do_pre() -> int:
    ensure_state_dir()
    slot_name = os.environ.get("RAUC_SLOT_NAME", "")
    slot_mp = os.environ.get("RAUC_SLOT_MOUNT_POINT", "")
    bundle_mp = os.environ.get("RAUC_BUNDLE_MOUNT_POINT", "")

    payload: Dict[str, object] = {
        "created_utc": utc_now(),
        "status": "planned",
        "slot_name": slot_name,
        "slot_mount_point": slot_mp,
        "bundle_mount_point": bundle_mp,
        "notes": "plan stage recorded; apply runs in post-install",
    }
    write_txn(payload)
    log("info", f"pre-install plan recorded for slot '{slot_name or 'unknown'}'")
    return 0


def do_post() -> int:
    ensure_state_dir()
    slot_mp_raw = os.environ.get("RAUC_SLOT_MOUNT_POINT", "")
    if not slot_mp_raw:
        log("error", "RAUC_SLOT_MOUNT_POINT not set")
        return 1
    slot_mount = Path(slot_mp_raw)
    if not slot_mount.is_dir():
        log("error", f"slot mount point is not a directory: {slot_mount}")
        return 1

    entries = load_manifest_entries(slot_mount)
    if not entries:
        log("info", "no managed-path manifests found in target slot; skipping")
        return 0

    old_state = read_state()
    new_state: Dict[str, str] = {}

    updated = 0
    preserved = 0
    skipped_missing = 0
    skipped_optional_missing = 0

    backup_dir: Path | None = None

    for policy, managed_path, optional, _manifest, metadata in entries:
        desired = slot_mount / managed_path.lstrip("/")
        if policy != "absent" and not desired.is_file():
            if optional:
                log("info", f"optional managed path absent in target slot: {desired}")
                skipped_optional_missing += 1
            else:
                log("warn", f"desired file missing in target slot: {desired}")
                skipped_missing += 1
            continue

        desired_hash = ""
        if policy != "absent":
            desired_hash = sha256_file(desired)
        prev_hash = old_state.get(managed_path, "")
        upper = upper_path_for(managed_path)
        upper_exists = upper.exists() or upper.is_symlink()

        upper_hash = ""
        if upper_exists and upper.is_file():
            upper_hash = sha256_file(upper)

        remove_upper = False
        apply_meta = False
        if upper_exists:
            if policy == "enforce":
                remove_upper = upper_hash != desired_hash
            elif policy == "replace_if_unmodified":
                remove_upper = bool(
                    prev_hash
                    and upper_hash
                    and prev_hash == upper_hash
                    and upper_hash != desired_hash
                )
                if not remove_upper:
                    preserved += 1
            elif policy == "preserve":
                preserved += 1
            elif policy == "absent":
                remove_upper = True
            elif policy == "enforce_meta":
                apply_meta = True
        elif policy == "enforce_meta":
            # File exists only in lower (squashfs) layer — cannot mutate it.
            # Metadata will be enforced once an upper-layer entry is created
            # (e.g. by provisioning or first runtime write).
            preserved += 1
            log("info", f"enforce_meta: {managed_path} has no upper entry; lower layer is immutable")

        if remove_upper:
            if backup_dir is None:
                backup_dir = BACKUP_ROOT / utc_now()
            backup_and_remove(upper, backup_dir)
            updated += 1
            log("info", f"removed stale overlay entry: {managed_path}")

        if apply_meta and upper_exists and upper.is_file() and metadata:
            uid_ref, gid_ref, mode = metadata
            try:
                uid = resolve_uid(uid_ref)
                gid = resolve_gid(gid_ref)
            except LookupError as exc:
                preserved += 1
                log(
                    "warn",
                    f"unable to resolve enforce_meta uid/gid for {managed_path}: {exc}; "
                    "skipping metadata enforcement",
                )
                uid = -1
                gid = -1

            if uid == -1 or gid == -1:
                pass
            else:
                st = upper.stat()
                cur_mode = stat.S_IMODE(st.st_mode)
                changed = False
                if st.st_uid != uid or st.st_gid != gid:
                    os.chown(upper, uid, gid)
                    changed = True
                if cur_mode != mode:
                    os.chmod(upper, mode)
                    changed = True
                if changed:
                    updated += 1
                    log("info", f"enforced metadata on overlay entry: {managed_path}")

        if policy != "absent":
            new_state[managed_path] = desired_hash

    write_state(new_state)

    txn = read_txn()
    txn.update(
        {
            "applied_utc": utc_now(),
            "status": "applied",
            "updated": updated,
            "preserved": preserved,
            "skipped_missing": skipped_missing,
            "skipped_optional_missing": skipped_optional_missing,
            "slot_name": os.environ.get("RAUC_SLOT_NAME", txn.get("slot_name", "")),
            "slot_mount_point": slot_mp_raw,
        }
    )
    write_txn(txn)

    log(
        "info",
        "overlay reconciliation complete: "
        f"removed={updated}, preserved={preserved}, "
        f"missing={skipped_missing}, optional_missing={skipped_optional_missing}",
    )
    return 0


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["pre", "post"], help="hook stage to execute")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    try:
        if args.mode == "pre":
            return do_pre()
        return do_post()
    except Exception as exc:  # pragma: no cover
        log("error", str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
