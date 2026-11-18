# shellcheck shell=bash
# Sourced by pre-commit and commit-msg. Prints an extended regex built from
# the optional per-clone pattern file <git-common-dir>/info/commit-patterns
# (one regex per line, # starts a comment). The file is never committed and
# all worktrees of a clone share it. No file: prints nothing, check is off.

commit_patterns() {
    local re="" p file
    file="$(git rev-parse --git-common-dir)/info/commit-patterns"
    [ -f "$file" ] || return 0
    while IFS= read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        re+="${re:+|}$p"
    done < "$file"
    printf '%s' "$re"
}
