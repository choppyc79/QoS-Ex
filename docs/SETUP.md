# QoS-Ex Setup Guide

How to install the QoS-Ex shaper, set it up in the web app, check it works
and fix common problems. SSH commands are at the end. The Ping Filter has
its own guide ([PINGFILTER.md](PINGFILTER.md)); every web app page is
described in [LUCI-GUIDE.md](LUCI-GUIDE.md).

---

## 1. Before you start

You need:

- OpenWrt **24.10 or newer** (fw4 / nftables): 24.10 uses `opkg`, 25.12
  uses `apk`; QoS-Ex works with either.
- SSH access as root, for the install.
- An internet connection on the router (the installer downloads packages).
- LuCI, for the web app.

Find these before you start:

1. **Your line speed.** Run a speed test with nothing else using the
   network and note download and upload. Auto Setup can also measure it.
2. **Your console or gaming PC.** You pick it by name from a list later;
   its MAC address is under LuCI **Status → Overview → Active DHCP Leases**.

Turn off anything that conflicts:

1. **SQM** on the same WAN. QoS-Ex will not start while it is enabled. In
   LuCI: **Network → SQM QoS**, untick **Enable this SQM instance** on the
   WAN, **Save & Apply**.
2. **Any other shaper** on the WAN (qosify, a script of your own). QoS-Ex
   reports a queue it did not build and leaves it alone.
3. **mwan3** and **pbr** keep their choices in the conntrack mark, which
   QoS-Ex writes. They do not work properly while QoS-Ex shapes; QoS-Ex
   warns when either is enabled.

---

## 2. Install

1. Open an SSH session to the router.
2. Paste this one line and press Enter:

   ```sh
   wget -O- https://raw.githubusercontent.com/choppyc79/QoS-Ex/main/QoS-Ex-install.sh | sh
   ```

3. Wait for the result line, `QoS-Ex installed:` with the versions of the
   app, the Ping Filter and the shaper. Each step before it prints `ok`,
   `..` (a note), `!!` (a warning) or `XX` (an error), and the line under
   it says what to do next.
4. Open LuCI and log in again (the installer logs LuCI out).

QoS-Ex is installed **switched off**. Nothing is shaped until you set it up.
The installer checks every file against the release manifest before
anything is put in place.

> **Download fails on a minimal image?** Install HTTPS support, then run
> the line again:
>
> ```sh
> apk add ca-bundle libustream-mbedtls       # OpenWrt 25.12
> opkg update && opkg install ca-bundle libustream-mbedtls   # OpenWrt 24.10
> ```

**Manual install.** Copy `QoS-Ex.sh`, `QoS-Ex-PF.sh`, `QoS-Ex-luci-app.sh`,
`QoS-Ex-install.sh` and `qos-ex-luci.tar.gz` to `/root`, and
`lib/install.sh` to `/root/lib/`, then run `cd /root && sh QoS-Ex.sh install`.

**Your own firmware.** See [BUILD.md](BUILD.md).

---

## 3. First setup

Open **Network → QoS-Ex**. A fresh install opens on the **Auto Setup** tab,
on the **Set up QoS-Ex** card. Pick one:

- **Auto Setup** (recommended) — checks the router, measures the line and
  suggests every setting.
- **Manual setup** — keeps the defaults (CAKE queue, Adaptive rules) and
  opens **Setup → Line**.
- **Restore a settings file** — a `QoS-Ex Settings.cfg` saved earlier from
  **System → Maintenance**. QoS-Ex restarts with those settings, and setup
  is done.

### Auto Setup

1. Press **Auto Setup**. **Your router** shows what the router check found,
   and **① Line speed** runs the speed test (about 30 s; shaping stops while
   it runs). If the test cannot run, type your line speeds and press **Use
   these speeds**. Cloudflare limits how many tests one address may run:
   after a few in a row it answers HTTP 429, so type your speeds or try
   again later.
2. Once the line speed is known, go on to **② Devices**. Set your consoles
   and gaming PCs to **Gaming** and anything that downloads a lot (a NAS, a
   TV box) to **Low priority**. Consoles are set to Gaming for you from
   their names; check them, then press **Next**.
3. **③ Settings to apply** lists each suggested change with its reason.
   Untick any you do not want, then press **Apply and start** (**Finish and
   start** when nothing needs to change). The settings are saved, the shaper
   starts, and you land on the Overview.

**System → Maintenance → Undo last Auto Setup** puts the old settings back,
shaping on or off as it was before (off again after a first setup);
**Run Auto Setup** there brings the tab back. Auto Setup sets up the shaper
only; the Ping Filter is optional and set up on its own
([PINGFILTER.md](PINGFILTER.md)).

### Manual setup

1. Press **Manual setup**. **Setup → Line** opens.
2. Pick the **WAN interface** (the note under it names the device your
   internet line is on) and enter **Download rate (Mbps)** and **Upload
   rate (Mbps)**.
3. Open **Devices & Ports** and set your console or gaming PC to
   **Gaming**.
4. Press **Save & Apply**.
5. On **Overview**, turn the **Shaper** switch on.

---

## 4. The web app

Everything is under **Network → QoS-Ex**: **Overview**, **Ping Filter**,
**Live**, **Setup** and **System**, with **Auto Setup** in front until
QoS-Ex is set up. [LUCI-GUIDE.md](LUCI-GUIDE.md) goes through every page in
that order, and explains the traffic classes the pages refer to ([How
QoS-Ex sorts traffic](LUCI-GUIDE.md#how-qos-ex-sorts-traffic)).

---

## 5. Common tasks

### Set your line speeds

**Setup → Line → Download rate (Mbps)** and **Upload rate (Mbps)**: enter
what a speed test measures, then **Save & Apply**. **Headroom** (default
90%) takes the margin off for you, so do not lower the numbers yourself.
`0` leaves that direction unshaped.

**Link layer** and **Overhead** describe the line. Auto Setup sets both
from the WAN type; to set them by hand:

| Line | Link layer | Overhead (bytes) |
|---|---|---|
| Ethernet, cable, fibre | Ethernet | 38 |
| The same over PPPoE | Ethernet | 46 |
| VDSL (PTM) | Ethernet | 22 (30 with PPPoE) |
| ADSL | ATM (ADSL) | 44 |

Add 4 for a VLAN tag (not on ADSL).

### Pick the queue type and rule set

**Setup → Queue → Root qdisc**:

| Queue | Choose it when |
|---|---|
| **CAKE** | You want the least to tune. The default: one queue that also shares the line fairly between your devices. |
| **HFSC** | You want the most control: six classes, with a real-time Gaming class that is always served first. |
| **HTB** | You want the same six classes on less CPU. Auto Setup picks it, with sfq queues, on a low-spec router or one whose CPU cannot keep up with CAKE. |

With HFSC or HTB, keep **Setup → Line → Headroom** at 90% or lower.

**Setup → Rules → nft ruleset**:

| Rule set | What it does |
|---|---|
| **Adaptive** | The default. Decides each connection at its first packet: listed traffic keeps its class, everything else moves up or down as it behaves. |
| **Advanced** | Marks every packet by its port, its size and its connection's packet rate. Auto Setup's pick for a high-end router. |
| **Simple (SGS)** | The SimpleHFSCgamerscript rules: one class per connection, the fewest rules per packet. Auto Setup's pick for a low-spec router. |

More on each: [Queue](LUCI-GUIDE.md#queue) and [Rules](LUCI-GUIDE.md#rules)
in the web app guide. **Save & Apply** restarts the shaper when the queues
change, and only reloads the rules otherwise.

### Set gaming and low-priority devices

**Setup → Devices & Ports → Devices**: set each device to **Normal**,
**Gaming** or **Low priority**, then **Save & Apply**. Gaming devices' game
traffic gets the fastest queue; low-priority devices give way to the rest.
Devices are saved by MAC, so one choice covers all their addresses. A
device the router cannot see the MAC of (behind another router) can be
added by its address under the table.

### Filter game servers

The Ping Filter is optional. It needs a gaming device set as above, then
its own setup: [PINGFILTER.md](PINGFILTER.md).

### Check it is working

1. **System → Status → Health**: every dot should be green. The first red
   dot is the cause.
2. Start a game and open **Live → Flows**. Under your gaming device (marked
   **GAME**), the game's connection should be in **Gaming** (DSCP EF).
   **Overview → Gaming traffic** shows its rate.
3. Start a large download and open **Live → Stats**. The download fills
   its class, while the delay of Gaming (the Voice tin under CAKE) stays
   flat. That is shaping working.

What each class and mark means: [How QoS-Ex sorts
traffic](LUCI-GUIDE.md#how-qos-ex-sorts-traffic).

---

## 6. Troubleshoot

**Nothing is shaped.** Open **System → Status**: the first failed health
check is the cause, often the wrong **WAN interface**. Why a start failed
is in the shaper log on **System → Logs**.

**"QoS-Ex did not create it" / "another shaper".** Another shaper is on the
WAN. Stop or disable it, then press **Restart** on the Overview. An
`ifb-<wan>` device left over from QoS-Ex itself can be removed with
`ip link del ifb-<wan>` (for example `ip link del ifb-pppoe-wan`).

**Game traffic is not in Gaming.** Check the device is **Gaming** on
**Setup → Devices & Ports**. Flow offloading must be off: QoS-Ex turns it
off when shaping starts. If **System → Status** warns that it is on, press
**System → Maintenance → Diagnostics → Disable flow offloading**.

**HFSC or HTB still lags on a slow upload.** The router merges packets
(GRO), and HFSC / HTB send a merged packet in one piece. On an upload under
about 20 Mbit use CAKE, or turn GRO off on the LAN ports (needs the
`ethtool` package; the port name is an example):

```sh
ethtool -K lan1 gro off
```

**A VPN on the router is all Default.** Only forwarded traffic is
classified. A WireGuard or OpenVPN tunnel on the router itself is the
router's own traffic. LAN traffic into a full tunnel is classified only when
the **WAN interface** is the tunnel device.

**QoS-Ex is missing from the LuCI menu.** Log out and in again. If it is
still missing, run over SSH:

```sh
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*
/etc/init.d/rpcd reload
```

**"Missing packages".** **System → Status** lists them with the install
command.

**The rule set failed to load.** The error is on **System → Logs**.

**Reporting a problem.** **System → Maintenance → Diagnostics → Generate
debug report** (addresses, MACs and your location are removed). Press
**Copy report** and paste it into the
[issue form](https://github.com/choppyc79/QoS-Ex/issues/new/choose)
(**Report a problem**), or use **Copy for forum** for a forum post.

---

## 7. Update, back up, remove

**Update.** **System → Maintenance → Versions & updates → Update now**.
Only the parts that changed are reinstalled; settings are kept. A failed
update says why on **System → Logs** (Update log); nothing is installed
unless every file matched the release manifest.

**Test the dev branch.** **System → Maintenance → Versions & updates →
Advanced → Update branch** → `dev`, then **Switch to dev**. Pick `main` and
**Switch to main** to go back. Settings are kept. On `dev` the installer
also keeps a check script in `/root`: see [Over SSH](#8-over-ssh).

**Firmware upgrade (sysupgrade).** Keep *Keep settings* ticked. QoS-Ex
reinstalls itself on the first boot once the router is online.

**Back up settings.** **System → Maintenance → Settings backup → Download
settings** saves `QoS-Ex Settings.cfg`; **Restore from file…** puts it
back. Server history is not in the file.

**Start again.** **System → Maintenance → Danger zone → Reset to defaults**
erases the settings and turns QoS-Ex off; it then opens on **Auto Setup**.

**Remove.** **System → Maintenance → Danger zone → Uninstall QoS-Ex**
removes the shaper, Ping Filter, the web app, the settings, the server
history and the copies in `/root`. Installed packages stay, and flow
offloading goes back the way QoS-Ex found it.

---

## 8. Over SSH

Every command below works in the router's shell (BusyBox ash).

**Install and update.** The one-line installer is in
[section 2](#2-install). After the first install, update with:

```sh
sh /root/QoS-Ex-install.sh
```

It installs only the parts that changed and lists each part as unchanged
or with its old and new version. Options: `-a` reinstall all, `-b REF` a
branch, tag or commit (`-b main` or `-b dev` also sets the update branch),
`-n` download only, `-t TOKEN` replace the saved token. Its result goes to
`/var/log/qos-ex.log` (**System → Logs**) and the system log; an update
from **System → Maintenance** also keeps its whole output in
`/var/log/qos-ex-update.log`.

**On and off.**

```sh
qos-ex.sh enable      # switch on: starts now and at boot
qos-ex.sh disable     # switch off: stops, not at boot, Ping Filter off too
qos-ex.sh restart     # stop, then start
qos-ex.sh reload      # after a settings change
```

`reload` rebuilds the rules, and restarts the shaper when a setting that
builds the queues changed.

**Status.**

```sh
qos-ex.sh status              # settings and health checks; the first failure is the cause
qos-ex.sh stats               # queue and class counters
qos-ex.sh conntrack 20        # the 20 busiest connections (game flows first) with their DSCP
tc qdisc show dev pppoe-wan   # the upload queue (use your WAN device)
nft list tables | grep qos_ex # the rule set table
```

The download queue is on `ifb-<wan>` (for example
`tc qdisc show dev ifb-pppoe-wan`), or on the LAN device (`br-lan`) when
**Download shaped on** is the LAN device.

**Check (dev branch only).**

```sh
sh /root/qos-ex-check.sh          # read-only: each line is PASS, FAIL, INFO or SKIP
sh /root/qos-ex-check.sh match    # the same, plus the game's flows: run it during a match
```

A testing tool: the installer keeps this script in `/root` only on a
router that follows the `dev` branch, fetched with the version it checks;
switching to `main` removes it. It compares what is installed with the
copies in `/root`, then checks the queues, the rules, the DSCP restore and
the Ping Filter. The report is also saved to `/tmp/qos-ex-check.txt`. It
holds LAN and game-server addresses and log lines, so read it before you
post it. A test named after the command (`reload`, `restart`, `redial` and
others) changes something for a moment: the list, with what each one does,
is at the top of the script.

**Logs.**

```sh
logread -e QoS-Ex                  # start / stop messages in the system log
cat /var/log/qos-ex.log            # shaper log
cat /var/log/qos-ex-pf-daemon.log  # Ping Filter log
qos-ex.sh nfterr                   # the last rule set load error
qos-ex.sh debug                    # the debug report, for a problem report
```

**Settings.** Settings live in `/etc/config/qos-ex`; rates are in kbit/s
(`70000` = 70 Mbit). Examples:

```sh
uci set qos-ex.settings.wan='pppoe-wan'
uci set qos-ex.settings.download_kbps='70000'
uci set qos-ex.settings.upload_kbps='18000'
uci set qos-ex.settings.qdisc='cake'          # cake, hfsc or htb
uci set qos-ex.settings.nft_mode='adaptive'   # adaptive, advanced or simple
uci add_list qos-ex.ips.gaming_mac='aa:bb:cc:dd:ee:ff'
uci add_list qos-ex.ips.lowprio_mac='11:22:33:44:55:66'
uci commit qos-ex
qos-ex.sh reload
```

On a new install, run `qos-ex.sh enable` once instead of `reload`.

**Auto Setup.**

```sh
qos-ex.sh autosetup speedtest   # measure the line (shaping stops while it runs)
qos-ex.sh autosetup suggest     # list the suggested settings
qos-ex.sh autosetup apply all dev=aa:bb:cc:dd:ee:ff
qos-ex.sh enable
```

`apply` with no arguments is `apply all`: every suggestion except packet
steering (`apply steering` applies that one). `dev=<MAC>` (gaming) and
`low=<MAC>` (low priority) can be repeated; with only `dev=` / `low=` and
no `all`, only the devices change. `apply` does not switch QoS-Ex on: that
is `qos-ex.sh enable`. `qos-ex.sh autosetup undo` puts the
settings back, shaping on or off as it was. `qos-ex.sh autosetup` lists
every command.

**Ping Filter.** See [PINGFILTER.md](PINGFILTER.md#7-over-ssh).

**Remove.**

```sh
qos-ex.sh uninstall        # everything; a copy of the settings stays in /tmp/qos-ex.bak until reboot
qos-ex.sh uninstall keep   # keep the settings and server history for a later reinstall
```

---

## 9. Settings reference

**What uses the internet:** the Ping Filter map tiles (loaded by your
browser); server location lookups (new servers together to `get.geojs.io`,
then any it cannot place one by one to `ipwho.is`, `get.geojs.io`,
`freeipapi.com`, `ipapi.co`, then `ip-api.com` over plain HTTP, each asked
only when the one before fails; the server's address is sent); the Auto
Setup speed test (Cloudflare); and the update check on GitHub while the web
app is open. Turn off lookups with `pingfilter.geoip_lookup` and the update
check with `settings.update_check`.

All settings live in `/etc/config/qos-ex`. After a change with `uci`, run
`uci commit qos-ex` and `qos-ex.sh reload`. A value out of range is
replaced when the shaper starts, usually by its default.
The Ping Filter's `pingfilter` section is in
[PINGFILTER.md](PINGFILTER.md#settings-reference).

### `settings` — the line

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `0` | Master switch |
| `wan` | the default-route device, else `eth0` | WAN device: the one `ip route get 1.1.1.1` names (`pppoe-wan`, not the port under it). A switch's CPU port (DSA conduit) is refused |
| `download_kbps` / `upload_kbps` | `100000` | Line speed in kbit/s, as measured. `0` = do not shape that direction |
| `bw_headroom` | `90` | Shaped rate as a % of line speed, 50–100 (`100` = off); out of range = 90. With `hfsc` or `htb` keep it at 90 or lower: they charge a burst of merged packets (GRO) as one, 3–5% under the wire for bulk TCP |
| `qdisc` | `cake` | `cake`, `hfsc` or `htb` |
| `nft_mode` | `adaptive` | Rule set: `adaptive`, `advanced` or `simple` (SGS) |
| `download_on` | `wan` | Where the download is shaped. `wan`: on an IFB device off the WAN, covering every LAN device. `lan`: on the LAN device as traffic leaves it, which saves CPU on a small router but shapes only what leaves through that device (see [Download shaped on](LUCI-GUIDE.md#queue)) |
| `lan` | *(empty)* | The LAN device for `download_on lan`. Setup fills in the `lan` interface's device (`br-lan`); empty = that device, found at each start |
| `live_refresh` | `1` | How often the Live pages (Stats, Flows) poll the router, in seconds: 1, 2, 5 or 10. A browser's own pick on those pages wins. Auto Setup sets 2 on a low-spec router; it has no field on Setup |
| `overhead` | `44` | Per-packet link overhead in bytes, 0–256: Ethernet 38, +8 for PPPoE, +4 for a VLAN; VDSL (PTM) 22; ADSL (ATM) 44. The same for every queue type (on an Ethernet WAN, HFSC / HTB take off the 14-byte header the kernel already counts, as CAKE does) |
| `linklayer` | `ethernet` | `atm` for ADSL: each packet is padded to 53-byte cells (every queue type) |
| `wash_up` / `wash_down` | `yes` | Clear DSCP marks on traffic leaving to the WAN / arriving from it |
| `ack_filter` | `auto` | Thin pure TCP ACKs on very asymmetric lines: `auto` (on when the shaped download is over 14 × the shaped upload), `on`, `off`. A segment carrying data is never thinned |
| `bw_max_ratio` | `auto` | HFSC / HTB: cap download at upload × ratio. `auto`, `off` or 1–99 |
| `mss` | `auto` | TCP MSS clamp on a slow direction: `auto`, `off` or 536–1460 |
| `mss_max_kbps` | `3000` | A direction below this rate is clamped |
| `update_check` | *(unset = on)* | `0` = do not check GitHub for updates when the app is opened |
| `update_branch` | *(unset)* | Where updates come from: `main` (releases) or `dev` (testing). Unset (Reset to defaults clears it) = the branch installed. `QoS-Ex-install.sh -b main` or `-b dev` sets it too |

### `hfsc` — Gaming class and leaf queues (HFSC and HTB)

| Option | Default | Meaning |
|---|---|---|
| `game_pct` | `15` | Gaming class rate, % of each direction (5–50) |
| `game_floor` | `400` | kbit added to that rate (0–10000) |
| `game_burst` | `10` | HFSC: short burst allowance, as a multiple of the gaming rate (1–20) |
| `voice_rt` | `yes` | HFSC only: Voice also gets a small real-time rate (5%, at least 200 kbit), with a short burst at twice that |
| `game_qdisc` | `sfq` | Queue inside the Gaming class: `pfifo`, `bfifo`, `sfq` or `fq_codel`. With sfq each flow gets its turn, so a second stream from a gaming device cannot crowd out the game |
| `max_delay` | `5` | Longest wait in a pfifo or bfifo gaming queue, ms (0–1000) |
| `packet_size` | `576` | Packet size the gaming queue is sized with, bytes (64–9000). Adaptive also uses it for a gaming flow's byte limit (see below) |
| `default_qdisc` | `fq_codel` | Queue inside classes 1:11 to 1:15: `fq_codel` or `sfq` |
| `def_tune_mode` | `auto` | `auto` sizes those queues from your line speed (sfq also gets per-flow RED with ECN marking); `manual` uses the `def_fq_*` / `def_sfq_*` values, which start at the qdisc defaults (fq_codel: limit 10240, target 5 ms, interval 100 ms, memory_limit 4 MB) |

The Gaming class never takes more than 85% of a direction. The remaining
`pfifo_min`, `bfifo_min`, `fq_*`, `sfq_*`, `def_fq_*` and `def_sfq_*`
options are fine tuning for the leaf queues and rarely need changing. A
pfifo or bfifo gaming queue is sized from the gaming rate; `def_fq_*` /
`def_sfq_*` are read only when `def_tune_mode` is `manual`.

**Gaming class (HFSC and HTB).** Gaming (1:10) is inside the shaped rate, as
in SimpleHFSCgamerscript: `game_pct` % of the rate plus `game_floor`, never
more than 85% of it. HFSC gives it a real-time curve, which is served first;
HTB gives it rate = ceil at the highest priority, and the other five classes
share what is left. With the Adaptive rules a gaming flow keeps EF while it
stays under `udp_fast_pps` packets and `udp_fast_pps` × `packet_size` bytes a
second each way (450 × 576 B ≈ 2 Mbit by default); over either it drops to Low
until 5 s after. The gaming rate is at least that, capped at a fifth of the
shaped rate. Gaming never borrows; what it does not use, the others may.

**Class shares.** Classes 1:11 to 1:15 split the shaped rate: Voice 5%, Video
20%, Default 55%, Low 10%, Bulk 10%. A class may use more when the others are
idle. Under HTB each may borrow up to the whole shaped rate, Voice first and
Bulk last, and every class always keeps its own share.

### `cake`

| Option | Default | Meaning |
|---|---|---|
| `priority` | `diffserv4` | CAKE tin layout: `besteffort`, `precedence`, `diffserv3`, `diffserv4` or `diffserv8` |
| `host_isolation` | `yes` | `yes`: share fairly between LAN devices (dual-srchost / dual-dsthost); `no`: triple-isolate |
| `nat_ingress` / `nat_egress` | `yes` | Look through NAT for per-device fairness. `nat_ingress` is not used with `download_on lan`: the LAN device already sees each device's own address |
| `ingress_mode` | `yes` | CAKE ingress mode on the download side |
| `rtt` | `100ms` | CAKE target round-trip time (a tc time such as `100ms`) |
| `mpu` | `84` | Smallest packet size charged, 0–256 (used by every queue type) |
| `extra_ingress` / `extra_egress` | *(empty)* | Extra CAKE arguments |

### `ips` and `ports`

| Option | Default | Meaning |
|---|---|---|
| `ips.gaming_mac` | *(empty)* | Gaming devices by MAC address (`aa:bb:cc:dd:ee:ff`): their UDP goes to the Gaming class. One entry covers every IPv4 and IPv6 address the device uses |
| `ips.gaming_ipv4` / `gaming_ipv6` | *(empty)* | Gaming devices by address, for one whose MAC the router cannot see. LuCI saves typed addresses here |
| `ips.lowprio_mac` | *(empty)* | Low-priority devices by MAC address: their UDP goes to Low (Adaptive: all their traffic). A device in both lists is treated as gaming in Advanced |
| `ips.lowprio_ipv4` / `lowprio_ipv6` | *(empty)* | Low-priority devices by address |
| `ports.http` | `80,443` | Web ports |
| `ports.tcp_bulk` | `51413,6881-6889` | Bulk TCP ports, source or destination (Simple, Adaptive). Empty = off |
| `ports.udp_bulk` | `51413` | Bulk UDP ports, source or destination (Simple, Adaptive). Empty = off |
| `ports.vidconf` | *(common call ports)* | Video-call destination ports (Simple, Adaptive). Empty = off. Adaptive moves call UDP to Low while it is over `udp_fast_pps`, so an IPsec VPN on 500 / 4500 (in the default list for Wi-Fi Calling) cannot ride in Voice. Under CAKE call UDP is marked AF41 (CAKE's Video tin): as CS4 it would share the Voice tin with the game |

The `ips` keys are lists: add entries with `uci add_list` (a single value
set with `uci set` is read too). A device list wins over a port list: a
gaming device's UDP is Gaming even from a bulk port.

### `advanced` and `simple` — rule switches and thresholds

Each rule set has `yes` / `no` switches for its rules: `gaming_ip`,
`lowprio_ip`, `tcp_upgrade`, `tcp_10s`; Simple adds `bulk_ports`, `vidconf`,
`udp_rate` and `tcp_500ms`; Advanced adds `meter_down`. In Advanced the
`tcp_upgrade` and `tcp_10s` rules cover web-port TCP only.

How Advanced classes a packet:

- Gaming devices' UDP not to a web port: EF. Low-priority devices' UDP: CS1.
- Web ports: from a web port CS0; to one, `small_len` bytes or less CS0,
  bigger AF42, and a connection's mid-size packets over `web_pps` AF11.
- Other TCP up to `max_len` bytes: AF41, and CS0 (Default) for a
  connection's packets over `tcp_pps`.
- Other UDP up to `max_len` bytes: CS5, and AF41 for a connection's packets
  over `udp_pps`.
- Bigger packets keep CS0.

Thresholds, all in the `advanced` section:

| Option | Default | Meaning |
|---|---|---|
| `udp_fast_pps` | `450` | Simple and Adaptive: a UDP connection above this packet rate is moved to Low, and stays there 5 s after it drops below (30 s for Adaptive's unlisted UDP; Simple: all UDP except gaming EF and what is already LE / CS1 / AF11). Adaptive moves a gaming flow the same way above this × `packet_size` bytes a second |
| `udp_fast_burst` | `225` | Burst allowed before that rate applies |
| `udp_small_avgpkt` | `576` | Adaptive: steady UDP with packets this small is lifted to Voice |
| `slow_flow_pps` | `150` | A TCP connection slower than this is lifted to Video (Advanced: web TCP); once over it, it stays where it is for 30 s |
| `heavy_flow_pps` | `1000` | Advanced: web TCP faster than this counts as heavy (1–100000) |
| `tcp_new_cap_mbit` | `80` | Simple: line speed (Mbit) at which the size limit for keeping a new connection in Low stops growing (1–1000) |
| `tcp_bulk_cap_mbit` | `400` | Simple and Advanced: the same for moving a heavy connection to Bulk (1–1000) |
| `bulk_timeout` | `120` | Advanced and Adaptive: seconds a device's transfers to the same host stay in Bulk (0 = off, up to 86400) |
| `web_pps` | `200` | Advanced: a web connection's mid-size packets over this rate go to AF11 (1–100000) |
| `tcp_pps` | `200` | Advanced: a non-web TCP connection's packets over this rate go to CS0 (Default) (1–100000) |
| `udp_pps` | `250` | Advanced: a non-web UDP connection's packets over this rate go to AF41 (1–100000) |
| `small_len` | `84` | Advanced: web packets this size or smaller stay CS0 (40 up to below `max_len`) |
| `max_len` | `1256` | Advanced: packets bigger than this are not lifted (128–9000) |
| `reset_pm` | `5` | Advanced: per 1000 over-rate packets, how many are sent the under-rate way instead (0 = off, up to 999) |

### `adaptive` — the Adaptive rule set

Adaptive also reads `udp_fast_pps`, `udp_fast_burst`, `udp_small_avgpkt`,
`slow_flow_pps` and `bulk_timeout` from the `advanced` section.

| Option | Default | Meaning |
|---|---|---|
| `heavy_pct` | `25` | A connection sending over this % of its direction's shaped rate is heavy (1–100), and so are a device's busy connections when together they send over it (a download split over many connections); upload = leaving by the WAN, also for a port-forwarded server |
| `heavy_secs` | `10` | Seconds it must keep that up before it goes to Bulk (1–60) |
| `p2p_rate` | `120` | A device opening more unlisted, non-web connections than this a minute (after a burst of as many) has its non-web traffic in Bulk for 5 minutes; 10–10000, 0 = off |
| `vpn_ports` | `51820,1194` | VPN tunnel ports: Default, never metered or demoted |

### `autosetup` — Auto Setup

| Option | Default | Meaning |
|---|---|---|
| `done` | `0` new, `1` upgraded | `1` once Auto Setup was applied or Manual setup was chosen; the web app's Auto Setup tab shows only while it is `0` |
| `test_secs` | `10` | Seconds each way the speed test measures (after a 2 s start) |
| `test_mb` | `1500` | The speed test stops early after this many MB each way |
| `test_url` | `http://speed.cloudflare.com` | Speed test server (Cloudflare's `__down` / `__up` endpoints); an `http://` or `https://` address |
| `ping_host` | `1.1.1.1` | Pinged idle and during the test; a host name or address |
| `cpu_busy_pct` | `90` | A core this busy in the test means the router, not the line, set the speed |
| `low_ram_mb` | `128` | At or under this RAM the router is low-spec (as with one core or a MIPS CPU): HTB with sfq leaves, the Simple rule set, the download shaped on the LAN device (when it is the only one), a 2 s Live refresh, Ping Filter Lite and a shorter server list are suggested |
| `small_flash_mb` | `16` | At or under this writable flash, fewer saves of the server list are suggested |
| `high_cores` / `high_mhz` / `high_ram_mb` | `4` / `1500` / `1024` | At or over all three (or any x86 router) the router is high-end; between low and high it is mid-range |
| `rules_low` / `rules_mid` / `rules_high` | `simple` / `adaptive` / `advanced` | The rule set suggested for each kind of router (the low-spec one, with HTB and sfq, whenever the speed test found the CPU at its limit) |
