# IoT Gateway TUI Banner (Rust/ratatui)

Modern, professional TUI banner generator inspired by Claude Code's aesthetic.

## Features

- 🎨 Beautiful colored ASCII logo with gradient effects
- 📊 Real-time system information:
  - CPU usage and temperature
  - Memory usage
  - Load averages
  - Network interfaces and IP addresses
  - RAUC A/B slot status
  - Kernel version and uptime
- 🎯 Professional panels and borders using ratatui
- ⚡ Blazingly fast (compiled Rust)
- 📦 Small binary (~2-3MB after stripping)

## Usage

```bash
# Run manually to see the TUI banner
iotgw-banner-tui

# Or call from SSH login scripts, etc.
```

## Build Notes

**First build**: Will take 30-40 minutes as it compiles Rust toolchain + all dependencies
**Subsequent builds**: Fast (~2-5 minutes) thanks to cargo caching

## Technologies

- **ratatui**: Terminal UI library (like what Claude Code uses)
- **crossterm**: Cross-platform terminal manipulation
- **sysinfo**: System and process information
- **anyhow**: Error handling

## Comparison with bash version

| Feature | Bash | Rust/ratatui |
|---------|------|--------------|
| Build time | Instant | 30+ min (first), 2min (cached) |
| Binary size | 2KB script | 2-3MB binary |
| Dependencies | Zero (bash) | Zero (statically linked) |
| Performance | Fast | Blazingly fast |
| Visual quality | Good | Excellent (professional TUI) |
| Maintainability | Medium | High (type-safe Rust) |
| Real-time updates | No | Yes (can add) |

## Future Enhancements

- [ ] Interactive mode (press keys to see different views)
- [ ] Real-time updating dashboard (like htop/btop)
- [ ] Container status (podman containers)
- [ ] Network traffic graphs
- [ ] Service status overview
