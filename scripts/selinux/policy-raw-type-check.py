#!/usr/bin/env python3
"""Every type a raw policy rule names must be declared in scope.

A raw rule (allow, type_transition, ..., or a support macro such as
manage_files_pattern / can_exec) that names a type the module neither
declares nor lists in a gen_require block can still compile, because an
earlier interface call in the same scope happened to require that type.
It then breaks, silently or at checkmodule time, when that interface
changes or the call moves. checkmodule also stops at the first unknown
type, so a build reports these one at a time. This check reports them
all, from the sources, without a build.

A use is covered by a `type`/`attribute`/`typealias` declaration or a
gen_require entry in the same block or any enclosing block. The blocks
are optional_policy, tunable_policy, ifdef/ifndef, interface and template
bodies. A gen_require attaches to the block that contains it.

Not checked: types reached only through interface calls (the interface
requires them itself) and $N parameters. For support-macro arguments
only identifiers ending in _t are checked; class and permission
arguments are not types.

Usage: policy-raw-type-check.py FILE.te|FILE.if ...
Exit status: 0 clean, 1 findings, 2 usage or read error.
"""

import re
import sys

RULE_KEYWORDS = (
    "allow", "dontaudit", "auditallow", "neverallow",
    "allowxperm", "dontauditxperm", "auditallowxperm",
    "type_transition", "type_change", "type_member",
)
RULE_RE = re.compile(r"^\s*(%s)\b" % "|".join(RULE_KEYWORDS))
DECL_RE = re.compile(r"^\s*(type|attribute|typealias|attribute_role)\s+([A-Za-z_][\w]*)")
# typealias X alias { a b }; and type X alias Y; declare the aliases too.
ALIAS_RE = re.compile(r"\balias\s+(\{[^}]*\}|[A-Za-z_]\w*)")
SUPPORT_MACRO_RE = re.compile(r"\b(\w+_pattern|can_exec)\(([^()]*)\)")
IDENT_RE = re.compile(r"[A-Za-z_]\w*")
BLOCK_OPEN_RE = re.compile(
    r"^\s*(gen_require|optional_policy|tunable_policy|ifdef|ifndef|"
    r"interface|template|gen_tunable_policy)\("
)
NON_TYPES = {"self"}


def strip_comment(line):
    i = line.find("#")
    return line if i < 0 else line[:i]


def idents(text):
    return [t for t in IDENT_RE.findall(text) if t not in NON_TYPES]


def rule_types(stmt):
    """Type identifiers a raw rule statement names (not classes/perms)."""
    kw = RULE_RE.match(stmt).group(1)
    body = stmt[RULE_RE.match(stmt).end():].rstrip().rstrip(";")
    # "allow <role> <role>;" is a role allow: no class, no types.
    if kw == "allow" and ":" not in body:
        return []
    # "<src> <tgt>:<class> <perms|new_type> [name]"
    head, _, tail = body.partition(":")
    types = idents(head)
    if kw in ("type_transition", "type_change", "type_member"):
        # tail = "<class> <new_type> [\"name\"]"
        tail = re.sub(r'"[^"]*"', "", tail)
        tail_ids = idents(tail)
        # class may be a set "{ a b }" - the new type is the last identifier
        if tail_ids:
            types.append(tail_ids[-1])
    return types


def check(path):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        print(f"{path}: {e}", file=sys.stderr)
        return None

    # Each frame: {"kind": str, "declared": set}
    stack = [{"kind": "file", "declared": set()}]
    uses = []  # (lineno, type, frame-chain snapshot as list of frame refs)
    pending = None  # (start_lineno, text) for a multi-line raw rule

    def chain():
        return list(stack)

    def declare(name):
        # gen_require entries belong to the enclosing non-require frame.
        for fr in reversed(stack):
            if fr["kind"] != "gen_require":
                fr["declared"].add(name)
                return

    for n, raw in enumerate(lines, 1):
        line = strip_comment(raw)
        if not line.strip():
            continue

        if pending is not None:
            pending = (pending[0], pending[1] + " " + line.strip())
            if ";" in line:
                for t in rule_types(pending[1]):
                    uses.append((pending[0], t, chain()))
                pending = None
            continue

        m = BLOCK_OPEN_RE.match(line)
        if m and line.rstrip().endswith("`"):
            stack.append({"kind": m.group(1), "declared": set()})
            continue

        in_require = stack[-1]["kind"] == "gen_require"
        if in_require:
            # "type a, b, c;"  "attribute x;"  "class ..." (ignored)
            m = re.match(r"^\s*(type|attribute|typealias)\s+(.*)", line)
            if m:
                for t in idents(m.group(2).rstrip(";")):
                    declare(t)
        else:
            d = DECL_RE.match(line)
            if d:
                stack[-1]["declared"].add(d.group(2))
                a = ALIAS_RE.search(line)
                if a:
                    for t in idents(a.group(1)):
                        stack[-1]["declared"].add(t)
            if RULE_RE.match(line):
                if ";" in line:
                    for t in rule_types(line):
                        uses.append((n, t, chain()))
                else:
                    pending = (n, line.strip())
            for mm in SUPPORT_MACRO_RE.finditer(line):
                for t in idents(mm.group(2)):
                    if t.endswith("_t"):
                        uses.append((n, t, chain()))

        # A line that is (or ends with) the m4 close "')" ends the block.
        # tunable_policy's "',`" (else branch) keeps the same frame.
        closes = len(re.findall(r"'\)", line))
        for _ in range(closes):
            if len(stack) > 1:
                stack.pop()

    findings = []
    seen = set()
    for n, t, frames in uses:
        if any(t in fr["declared"] for fr in frames):
            continue
        key = (n, t)
        if key in seen:
            continue
        seen.add(key)
        findings.append((n, t))
    return findings


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-3], file=sys.stderr)
        return 2
    status = 0
    for path in argv[1:]:
        findings = check(path)
        if findings is None:
            return 2
        for n, t in findings:
            print(f"{path}:{n}: type '{t}' used in a raw rule but not "
                  f"declared or gen_require'd in scope")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
