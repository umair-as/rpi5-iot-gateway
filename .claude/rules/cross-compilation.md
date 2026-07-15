# Cross-Compilation Rules

## Target Architecture

Primary: **aarch64** (ARM64)
- Raspberry Pi 5: `aarch64-poky-linux`
- Toolchain prefix: `aarch64-poky-linux-`

## SDK Environment

Before cross-compiling outside Yocto:

```bash
# Source SDK environment (adjust path)
source /opt/poky/<version>/environment-setup-cortexa76-poky-linux  # <version> = wrynose (6.0) SDK

# Verify
echo $CC  # Should show aarch64-poky-linux-gcc
```

## CMake Cross-Compilation

The SDK sets `CMAKE_TOOLCHAIN_FILE` automatically. If manual:

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER aarch64-poky-linux-gcc)
set(CMAKE_CXX_COMPILER aarch64-poky-linux-g++)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
```

## Rust Cross-Compilation

```bash
# Add target
rustup target add aarch64-unknown-linux-gnu

# Build
cargo build --target aarch64-unknown-linux-gnu --release
```

In `.cargo/config.toml`:

```toml
[target.aarch64-unknown-linux-gnu]
linker = "aarch64-poky-linux-gcc"
```

## Go Cross-Compilation

```bash
# Static build (no CGO)
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o app

# With CGO (requires SDK)
GOOS=linux GOARCH=arm64 CGO_ENABLED=1 \
  CC=aarch64-poky-linux-gcc \
  go build -o app
```

## Common Pitfalls

1. **Host libraries linked** — Verify with `file <binary>` and `readelf -d <binary>`
2. **Wrong libc** — Ensure targeting glibc, not musl (unless intentional)
3. **Missing sysroot** — SDK must be sourced for header/library paths
4. **Floating point ABI** — RPi5 uses hard-float (default)

## Verification Commands

```bash
# Check architecture
file myapp
# Expected: ELF 64-bit LSB executable, ARM aarch64

# Check dependencies
aarch64-poky-linux-readelf -d myapp | grep NEEDED

# Check for host contamination
strings myapp | grep -i x86
```

## Static vs Dynamic Linking

| Approach | When to Use |
|----------|-------------|
| **Static** | Single-binary deployment, minimal dependencies |
| **Dynamic** | Shared libs already on target, smaller binary |

Prefer static for application binaries, dynamic for system libraries.
