# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Project orientation, build commands, repo layout, conventions, and task routing live in the agent-agnostic file:

@AGENTS.md

The rest of this file is Claude-Code-specific tooling that does not apply to other agents.

## Domain skills available

Yocto/embedded work has dedicated skills — invoke when the task fits:

- `add-package`, `build-image`, `debug-bitbake` — image assembly and build failures
- `create-kernel-fragment`, `patch-kernel-bsp`, `patch-uboot-bsp` — kernel/U-Boot work
- `devtool-workflow` — iterative recipe source changes via `devtool`
- `yocto-worktree` (repo-local, `.claude/skills/`) — isolated worktrees for subagent/parallel builds: `kas/local.yml` seeding, shared-cache verification, branch rename-before-PR, locked-worktree cleanup

## Subagents & parallel work

Delegate build-running or build-polluting tasks to subagents with `isolation: worktree`, and follow the `yocto-worktree` skill for seeding, coordination, and cleanup. Recipe/patch conventions live in `.claude/rules/recipe-conventions.md` (auto-loaded as a rule; also route subagents there explicitly).

## Serial console + target diagnostics MCPs

Two MCP servers are wired for on-target work:

- `mcp-serial-rs` — direct UART access (`serial_list_ports`, `serial_open` on `/dev/ttyACM0`, `serial_exec`, `serial_read_until`). Prefer it for U-Boot/boot-flow debugging; close the port (`serial_close`) before the operator starts `tio`, they can't share the device.
- `mcp-netdiag-rs` — host-side network/system diagnostics (ping, routes, neighbors, sockets, dmesg, service status) for reaching and triaging the target.

The operator may still capture UART via `tio --log --log-directory $PWD/tio-session-logs /dev/ttyACM0` and share the log path. When grepping those logs, note that the file can contain high-bit / extended-ASCII control bytes that make vanilla `grep` skip lines it considers "binary". Use `grep -a` or `strings <log> | grep …` so U-Boot/firmware output isn't silently filtered out.
