# QoS-Ex — Build It Into Your Own Firmware

For people who build their own OpenWrt images (24.10 or newer)
and want QoS-Ex already in them. If you just want it on a running router,
use the one-line installer in [SETUP.md](SETUP.md) instead.

There are three ways. Pick one:

| | You have | Result |
|---|---|---|
| [A](#a-build-the-package) | The OpenWrt source tree or the SDK | A `qos-ex` package (`.ipk` or `.apk`) |
| [B](#b-image-builder-with-the-package) | The Image Builder and the package from A | A firmware image with QoS-Ex |
| [C](#c-image-builder-without-the-package) | Only the Image Builder | A firmware image with QoS-Ex |

---

## How the package works

QoS-Ex is three shell scripts that install themselves. The package does not
replace that; it carries the scripts and runs them for you:

1. The package puts the three scripts, the shaper's `lib/install.sh`, the
   web app's files (`qos-ex-luci.tar.gz`), `QoS-Ex-install.sh` and the
   check script (`qos-ex-check.sh`) in `/usr/lib/qos-ex/`, and one
   first-run script in `/etc/uci-defaults/90-qos-ex`.
2. On the first boot of the image (or when the package is installed on a
   running router) the first-run script copies them to `/root` and
   runs `sh /root/QoS-Ex.sh install`.
3. From then on it is a normal QoS-Ex install: same files, same commands,
   same web app, same **Update now** button.

The install runs in the background once the router has a default route (it
gives up waiting after 10 minutes and installs anyway). Its output is in
`/var/log/qos-ex-pkg-install.log`. If the image has `tcpdump-mini` (or full
`tcpdump`), everything QoS-Ex needs is already in it. Routes A and B do not
add it (see **Dependencies** under A), so without it the router must be online
for the install. The web app's installer also fetches the map page's library
(Leaflet); if it cannot, the map page loads it from the internet instead.

QoS-Ex is installed **switched off**, exactly as with the script installer.

---

## A. Build the package

`Makefile` in this repo is an OpenWrt package Makefile. Clone the repo into
the `package/` directory of your source tree or SDK:

```sh
cd /path/to/openwrt            # or the unpacked SDK
git clone https://github.com/choppyc79/QoS-Ex.git package/qos-ex
```

**Full source tree** — select it and build as usual:

```sh
make menuconfig                # Network  --->  <*> qos-ex
make
```

**SDK** — build just the package:

```sh
make defconfig
make package/qos-ex/compile
```

The package lands in `bin/packages/<arch>/base/`:

- OpenWrt 24.10: `qos-ex_<version>-r1_all.ipk`
- OpenWrt 25.12: `qos-ex-<version>-r1.apk`

What the Makefile sets, so you do not have to:

- **Version** — read from `QoS-Ex.sh` (the shaper's version).
- **Dependencies** — `firewall4` plus the package list in `QoS-Ex.sh`:
  `tc-full kmod-sched kmod-sched-cake kmod-sched-ctinfo kmod-ifb ip-full
  conntrack coreutils-timeout`. `tcpdump-mini` is left out: full `tcpdump`
  does the same job and the two cannot both be installed. The first-run
  install adds `tcpdump-mini` when neither is there; add it to an image
  yourself if the router will not be online on first boot.
- **Upgrading the package** keeps QoS-Ex installed and running: the removal
  script runs on `opkg remove` / `apk del` only.
- **LuCI is not a dependency.** Add `luci` to your build if you want the web
  app. Without it QoS-Ex still installs and is run over SSH.

To install the package on a running router, copy it to `/tmp` and:

```sh
opkg install /tmp/qos-ex_*.ipk                    # OpenWrt 24.10
apk add --allow-untrusted /tmp/qos-ex-*.apk       # OpenWrt 25.12
```

To pick up a newer QoS-Ex later: `git -C package/qos-ex pull`, then build
again. The package takes the shaper's version, so a release that changes only
the Ping Filter or the web app builds with the same version as before, and
the package manager may see nothing new to install. On a router that already
has the package, use **Update now** for such a release (see
[After it is installed](#after-it-is-installed)).

---

## B. Image Builder, with the package

Copy the package from A into the Image Builder's `packages/` directory, then
name it in `PACKAGES`:

```sh
cp qos-ex_*.ipk /path/to/imagebuilder/packages/     # 25.12: qos-ex-*.apk
cd /path/to/imagebuilder
make image PROFILE=<your-device> PACKAGES="qos-ex luci"
```

The dependencies are pulled in for you, except `tcpdump-mini` (see
**Dependencies** under A): add it to `PACKAGES` if the router will not be
online on first boot. `make info` lists the `PROFILE` names.

---

## C. Image Builder, without the package

No SDK needed. Put the same files in an overlay directory and list the
dependencies yourself:

```sh
git clone https://github.com/choppyc79/QoS-Ex.git
cd /path/to/imagebuilder

mkdir -p files/usr/lib/qos-ex/lib files/etc/uci-defaults
cp ../QoS-Ex/QoS-Ex.sh ../QoS-Ex/QoS-Ex-PF.sh ../QoS-Ex/QoS-Ex-luci-app.sh \
   ../QoS-Ex/qos-ex-luci.tar.gz ../QoS-Ex/QoS-Ex-install.sh \
   ../QoS-Ex/qos-ex-check.sh files/usr/lib/qos-ex/
cp ../QoS-Ex/lib/install.sh files/usr/lib/qos-ex/lib/
cp ../QoS-Ex/files/qos-ex.defaults files/etc/uci-defaults/90-qos-ex

make image PROFILE=<your-device> FILES=files \
  PACKAGES="luci tc-full kmod-sched kmod-sched-cake kmod-sched-ctinfo kmod-ifb ip-full conntrack coreutils-timeout tcpdump-mini"
```

Adjust the `../QoS-Ex` path to wherever you cloned the repo.

---

## Shipping your own settings

To have the image come up already configured, add your own
`/etc/config/qos-ex` to the image (`files/etc/config/qos-ex` with the Image
Builder, or the `files/` directory of your source tree). The installer keeps
an existing config. It adds options that are missing, and brings a config from
an older QoS-Ex up to date: renamed and retired options, and values still at
an old default. An empty `option wan` in `settings` is set to the device the
default route uses.

The quickest way to get that file is to set QoS-Ex up on one router and copy
its `/etc/config/qos-ex`. The options are listed in
[SETUP.md](SETUP.md#9-settings-reference).

Set `option enabled '1'` in the `settings` section only if the WAN interface
and line speeds in the file are right for the router the image is for.

---

## After it is installed

- **Set it up** as in [SETUP.md](SETUP.md#3-first-setup): Auto Setup, or
  by hand the WAN interface, line speeds and gaming device, then switch it
  on.
- **Updating between builds** — **System → Maintenance → Update now** or
  `sh /root/QoS-Ex-install.sh` work as usual and fetch the latest scripts from
  GitHub. Your next image brings whatever version you built into it.
- **Firmware upgrade (sysupgrade)** — your settings are kept. On the first
  boot the scripts from the new image are copied to `/root` and QoS-Ex
  reinstalls itself from them.
- **Removing it** — `opkg remove qos-ex` or `apk del qos-ex` removes the
  package and QoS-Ex with it; your settings and server history stay. To remove
  the settings too, run `qos-ex.sh uninstall` first. When QoS-Ex is built into
  the image, the files in `/usr/lib/qos-ex` are part of the firmware and stay;
  QoS-Ex is installed again after a factory reset or a firmware upgrade.

---

## Troubleshooting

**QoS-Ex is not in LuCI after the first boot.** Give it a minute after the
router is online, then log in to LuCI again. Check the install log:

```sh
cat /var/log/qos-ex-pkg-install.log
```

The log has one line per step — `ok`, `..` (note), `!!` (warning) or `XX`
(error) — and its last line starts `QoS-Ex v<version> installed` when the
install worked. If the file is empty, the first-run script is still waiting
for a default route (10 minutes at most) or for opkg / apk to finish. If it
is missing, the install ran on an earlier boot (the log does not survive a
reboot), or this is the first boot after a firmware upgrade, when QoS-Ex's
own upgrade hook reinstalls it and writes no log here.

**Run the install by hand.**

```sh
sh /root/QoS-Ex.sh install
```

**"packages not installed" in the log.** The image is missing a dependency
and the router could not download it. On routes A and B this is usually
`tcpdump-mini` (see **Dependencies** under A); on route C, anything left out
of `PACKAGES`. Add it to the image and build again, or install it on the
router.

---

## Working on the web app

The LuCI app's source is one file per view under `luci/`; see
[luci/README.md](../luci/README.md) for how it is packed and released.

---

## Tested with

OpenWrt **24.10.8** and **25.12.5**, x86/64, SDK and Image Builder:

- Route A: the package builds as `.ipk` (24.10.8) and `.apk` (25.12.5).
- Route B: images build on both, and the first-run install completes inside
  the built root filesystem.
- Route C: the same, on 24.10.8.

Not tested: flashing an image onto a router, and installing the package on a
running router with `opkg` / `apk`. The builds above predate the web app's
files moving into `qos-ex-luci.tar.gz` (LuCI app 1.2.7.3); since then only
the first-run script has been re-run, not the SDK or Image Builder builds.
