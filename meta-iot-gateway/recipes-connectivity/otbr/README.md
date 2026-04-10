# OTBR Container Path (Optional)

This directory includes an optional OCI/containerized OpenThread Border Router
build path. It is not the default runtime model used by the gateway images.

## Current Project Status

- Default OTBR deployment in this repo: host/systemd services (`otbr-rpi5` + `otbr-webui`).
- Container path: available via `otbr-rpi5-container` recipe for dedicated testing/porting tracks.
- Current intent: keep container path available for future platform alignment (including i.MX93-class workflows), while host path remains primary on this project branch.

## Included Recipes

- `otbr-rpi5.bb`: host OTBR package
- `otbr-webui_0.1.0.bb`: web UI package used by host OTBR path
- `otbr-rpi5-container.bb`: OCI image recipe for containerized OTBR
- `otbr-rpi5-container/entrypoint.sh`: container entrypoint

## Build Container Image

```bash
kas build kas/otbr.yml --target otbr-rpi5-container
```

Typical artifact:

- `otbr-rpi5-container-<machine>-<timestamp>.rootfs-oci.tar`

## Load And Run (Example)

```bash
# On target/host where Podman is available
cd /tmp
tar xf otbr-rpi5-container-*.rootfs-oci.tar
skopeo copy oci:otbr-rpi5-container-*:latest containers-storage:localhost/otbr-rpi5:latest

podman run -d \
  --name otbr \
  --network host \
  --privileged \
  --device=/dev/ttyACM0 \
  -e OTBR_RCP_BUS=ttyACM0 \
  -e OTBR_INFRA_IF=eth0 \
  -e OTBR_LOG_LEVEL=info \
  localhost/otbr-rpi5:latest
```

## Notes

- Treat this as an optional deployment track, not the baseline image workflow.
- Validate device exposure (`/dev/ttyACM*` or `/dev/ttyUSB*`) and host networking/firewall policy before container rollout.
- For mainline gateway operations and runbook commands, use [OTBR guide](../../../docs/OTBR.md).
