# OTA Adaptive Benchmark

## Purpose
Validate whether RAUC adaptive streaming (`block-hash-index`) materially improves OTA install performance on the Raspberry Pi 5 gateway in our real workflow (`iotgw-rauc-install` with HTTPS streaming bundle).

## Test setup
- Device: Raspberry Pi 5 gateway (same target for all runs)
- Slots: A/B (`rootfs.0` / `rootfs.1`)
- Bundle path: `iot-gw-image-dev-bundle-full-fit.raucb`
- Transport: HTTPS + mTLS (`--tls-profile system`)
- Update method: manual wrapper (`iotgw-rauc-install --direct`)
- Date: Tuesday, March 3, 2026

## Results

| mode | run | slot before -> updated slot | wall time (`time`) | downloaded % | avg `nbd dl_speed` | result | txn |
|---|---|---|---|---|---|---|---|
| adaptive OFF | 1 | B -> `rootfs.0` (A) | `7m50.287s` | `100.3%` | `52,206,554 B/s` | success | `89600220` |
| adaptive OFF | 2 | A -> `rootfs.1` (B) | `7m56.001s` | `100.3%` | `45,004,463 B/s` | success | `c044a690` |
| adaptive ON | 1 | B -> `rootfs.0` (A) | ~`2m13s` (RAUC phase) | `7.1%` | `67,336,306 B/s` | success | `0b53b793` |
| adaptive ON | 2 | A -> `rootfs.1` (B) | ~`1m34s` (RAUC phase) | `7.1%` | `66,584,658 B/s` | success | `8ed9733e` |

## Interpretation
- Adaptive OFF consistently downloaded the full bundle (`100.3%`) and took about 8 minutes.
- Adaptive ON downloaded only `7.1%` and completed substantially faster in these runs.
- Throughput (`dl_speed`) was not worse with adaptive; the main gain came from dramatically lower transferred data.

## Conclusion
Keep adaptive OTA enabled by default for this product profile.  
The measured data shows a large and repeatable improvement in transfer size and practical install duration on target hardware.

## Notes
- Adaptive ON wall times above are based on RAUC journal phase start/end timestamps.
- OFF wall times were measured with shell `time` around `iotgw-rauc-install`.
