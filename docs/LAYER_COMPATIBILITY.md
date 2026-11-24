# Layer compatibility (`yocto-check-layer`)

`meta-iot-gateway` is a product layer: it exists to build this distribution
for this board, and it is not meant to be added to other builds. It does not
claim Yocto Project Compatible status. This page records which of the
`yocto-check-layer` requirements it meets, where it deliberately does not, and
why.

## What the check tests

oe-core's `scripts/yocto-check-layer` adds the layer to a fresh build that uses
oe-core's default distro (`nodistro`) and only the layer's declared
dependencies. A distro layer must then:

- carry a README (maintainer, patch instructions, an email address) and a
  `SECURITY.md`, set `LAYERSERIES_COMPAT`, and give every patch an
  `Upstream-Status`;
- parse, and pass `bitbake -e` and `bitbake -S none world`, without its distro
  being selected;
- leave every other recipe's task signatures unchanged when the layer is added
  (the signature test). In other words, adding the layer must not change a
  build that does not select its distro;
- define its distros without setting `DISTRO` itself.

## Met

| Requirement | How |
|---|---|
| README and `SECURITY.md` | `meta-iot-gateway/README.md`, `meta-iot-gateway/SECURITY.md` |
| `LAYERSERIES_COMPAT` | `conf/layer.conf` |
| `LAYERDEPENDS` lists every layer the layer appends or builds on | `conf/layer.conf` |
| `Upstream-Status` on every patch | also enforced by the build's patch-status QA |
| defines its distros, does not set `DISTRO` | `conf/distro/` |

## Deliberately not met

1. **The layer requires the `iotgw` distro.** Some recipes and appends check
   the distro's policy at parse time. For example, the U-Boot append insists on
   the watchdog feature the verity boot path is built on, and the container
   principal's recipe reads its uid from the distro's static id tables. Under
   any other distro these stop the parse instead of skipping. Guarding them
   would only serve builds that do not exist.
2. **Appends modify upstream recipes for every distro.** Most of the layer's
   `.bbappend` files change their recipe without restricting the change to the
   `iotgw` distro, so the signature test would fail once the layer is added to
   another build. Scoping every append would touch almost all of them, and each
   change risks the images this layer exists to build, for no user of this
   project.
3. **telegraf fetches during `do_compile`.** The check also refuses network
   access in any task other than fetch; the telegraf recipe's Go build fetches
   its modules at compile time. The recipe is in no image, and whether to keep
   and update it or drop it is under review.

Revisit these if the layer is ever offered for reuse outside this project.

## Running it

Run it inside the kas environment. The wrapper creates a throwaway build
directory, so `build/` is not touched. Everything after `--` goes to
`yocto-check-layer`; name the layer first, and list the dependency layer
directories one by one, since `.kas/` as a whole also contains bitbake's test
layers:

```bash
K=$PWD/.kas
. scripts/env.sh && kas shell "$(make -s stack IMAGE=dev)" -c \
  "yocto-check-layer-wrapper -- $PWD/meta-iot-gateway --no-auto-dependency \
   --machines raspberrypi5 --dependency $K/meta-openembedded $K/meta-raspberrypi \
   $K/meta-rauc $K/meta-selinux $K/meta-virtualization $K/meta-secure-core"
```

`--no-auto-dependency` keeps the dependency layers out of the test: they are
only used, not tested.
