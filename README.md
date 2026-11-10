# QoS-Ex

Gaming-focused traffic shaping and game-server filtering for OpenWrt
**24.10 and newer**.

## What it does

- **Shaper** — CAKE, HFSC or HTB keeps game traffic in its own low-latency
  queue while downloads, streams and calls stay out of its way.
- **Rule sets** — Adaptive (default), Advanced or Simple (SGS) mark each
  connection with one of nine DSCP classes.
- **Ping Filter** — finds the game servers your console or PC uses,
  measures their ping, maps them, and can block slow or distant ones by
  ping, distance or country.
- **Auto Setup** — checks the router, runs a speed test and suggests every
  setting; one Apply, one Undo.
- **Web app** — a LuCI app under **Network → QoS-Ex**, or everything over
  SSH.

## Requirements

- OpenWrt 24.10 or newer (fw4 / nftables): 24.10 with `opkg`, 25.12 with
  `apk`.
- A router fast enough to shape your line in software.
- LuCI, for the web app.

The installer adds the packages it needs: `tc-full kmod-sched
kmod-sched-cake kmod-sched-ctinfo kmod-ifb ip-full conntrack
coreutils-timeout tcpdump-mini`.

## Quick install

Paste into an SSH session on the router:

```sh
wget -O- https://raw.githubusercontent.com/choppyc79/QoS-Ex/main/QoS-Ex-install.sh | sh
```

Then log in to LuCI again, open **Network → QoS-Ex** and press **Auto
Setup**.

## Guides

| Guide | What is in it |
|---|---|
| [SETUP.md](docs/SETUP.md) | Install, first setup, common tasks, troubleshooting, updates, SSH commands; every shaper setting |
| [PINGFILTER.md](docs/PINGFILTER.md) | Ping Filter: set up, modes, common tasks, troubleshooting, SSH commands; every Ping Filter setting |
| [LUCI-GUIDE.md](docs/LUCI-GUIDE.md) | The web app, page by page |
| [BUILD.md](docs/BUILD.md) | Building QoS-Ex into your own firmware, or as a package |
| [CHANGELOG.md](docs/CHANGELOG.md) | What changed in each version |

Problems: [report form](https://github.com/choppyc79/QoS-Ex/issues/new/choose)
with the debug report from **System → Maintenance → Generate debug report**
(or `qos-ex.sh debug`).

## Licence

GPL-3.0-or-later.

The HFSC class layout and the Simple rule set derive from
**SimpleHFSCgamerscript by dlakelan** (GPL-3.0). The ctinfo DSCP restore and
parts of the Simple classifier are adapted from
**[qosmate](https://github.com/hudra0/qosmate) by @hudra0**
(GPL-3.0-or-later). Thanks to @hudra0 for qosmate.

Maintainer: Ash Clarke &lt;clarkeaj@hotmail.co.uk&gt;
