# QoS-Ex Ping Filter Guide

Ping Filter finds the game servers your console or PC connects to, measures
their ping, shows them on a map, and can block the ones that are too slow or
too far away so matchmaking picks a better one. A block stops game (UDP)
traffic only; logins, the store and web pages on the same address still work.
SSH commands are at the end.

---

## 1. Before you start

You need:

- QoS-Ex installed and switched on ([SETUP.md](SETUP.md)). Ping Filter is
  installed with it and runs while QoS-Ex does. With both rates at 0
  (**Ping Filter only** in Auto Setup, or on **Setup → Line**) nothing is
  shaped and the Ping Filter runs alone, beside another shaper too.
- At least one device set to **Gaming** (**Setup → Devices & Ports**, or
  Auto Setup's **Devices** step).
- Your home location (latitude and longitude, or a click on the map).
- **Flow offloading off.** QoS-Ex turns it off when it is switched on; it
  hides game flows from Ping Filter if it is turned back on.

Ping Filter is **off** after install, and Auto Setup leaves it off: it is
optional and set up only here. It watches only the devices you tick, and
grades IPv4 servers only (see [Troubleshoot](#5-troubleshoot) for IPv6).

**Small routers:** Ping Filter Lite (**Settings → Advanced options →
Grading → Lite (small routers)**) keeps the ping limit or radius, locations
and the lists, and drops gameplay grading, handshake timing and Ping Catch.
Auto Setup suggests it on a low-spec router.

---

## 2. Set it up in the web app

1. Open **Network → QoS-Ex → Ping Filter**. While it is off, every Ping
   Filter page shows the **Set up the Ping Filter** card with two steps.
2. **Gaming devices to watch**: press **Tick your gaming devices** and tick
   them under **Settings → Devices → Watched devices** (only Gaming devices
   are listed, none ticked to start). Then **Save & Apply**.
3. **Your home on the map**: press **Pin your home on the Map**, then
   right-click your home (or zoom in until it is under the cross and press
   **Pin home here**).
4. Turn the **Ping Filter** switch on (on the card, the Dashboard or the
   Overview). It starts in **Watch only**: it lists and grades servers and
   blocks nothing.
5. Play a few games. Servers appear on the **Dashboard**, **Map** and
   **Servers**.
6. When you are ready, pick a mode card on the **Dashboard**
   ([Pick a mode](#pick-a-mode)).

---

## 3. The pages

Under **Network → QoS-Ex → Ping Filter**, in this order. Each is described
in [LUCI-GUIDE.md](LUCI-GUIDE.md#ping-filter).

| Page | What it is for |
|---|---|
| [Dashboard](LUCI-GUIDE.md#dashboard) | The switch, **Restart**, **New game**, **Clear cache**; the mode cards; **Now playing** and the servers you have played on |
| [Map](LUCI-GUIDE.md#map) | Servers on a map, your home and radius; the live ping limit, radius and Ping Catch sliders |
| [Servers](LUCI-GUIDE.md#servers) | Every server in one table; **Allow** / **Block** / **×** per row; **Add a server** |
| [Settings](LUCI-GUIDE.md#settings) | **Settings** (devices, mode, home, advanced options, saved with Save & Apply) and **Tools** (scans and checks) |

---

## 4. Common tasks

### Pick a mode

Start in **Watch only** for a few sessions, and look at the servers you get
on the Dashboard and the Map: where they are and what they ping. Then click
a mode card on the **Dashboard**:

| Mode | What it does | Good for |
|---|---|---|
| **Ping** | Blocks servers whose ping is over your limit: **Casual** (your base ping + 80 ms), **Competitive** (+ 40 ms) or your own **Ping limit** (1 to 5000 ms) | You know what ping you will accept. The lower the limit, the longer matchmaking may take, and a limit under your region's servers can stop it finding a match at all |
| **Distance** | Blocks servers further from home than your **Radius** (50 to 20,000 km) | Keeping games in your region, including on servers that do not answer ping |
| **Distance** with **Ping Catch** | Lets in every server inside the radius, plus any outside it whose ping is at or under the catch (1 to 250 ms; 0 = off) | A tight radius that should still let in a fast server just outside it |
| **Watch only** | Lists and grades servers; only **Always block** entries and a country list block | Seeing what you connect to before you block anything |

**Casual** and **Competitive** add 80 or 40 ms to your line's base ping, which
the router measures each time you pick one (its ping to 1.1.1.1, the address
Auto Setup's speed test pings); the line above the cards shows the sum.
Competitive shows a warning: a game with few servers that close may find no
match. Clicking **Ping** with no limit set picks Casual.

A change on the Dashboard or the Map applies at once, even to the server you
are playing on; a warning shows while a match is on. Each mode keeps its own
number, so you can switch back and forth.

### Always allow or block a server

On **Servers**, press **Allow** or **Block** on its row (press it again to
unpin), or use **Add a server** with an address or a range such as
`1.2.3.0/24`. **×** forgets a server.

### Only play on servers in some countries

**Settings → Mode → Only these countries**: servers elsewhere are blocked.

### Keep voice chat out of the server list

**Settings → Advanced options → Network → Ignore UDP ports**: ports never
treated as game servers, and a call on them does not count as a game. A
blocked server still gets its traffic on them. The default `3478-3481`
covers STUN and party chat. Add your voice chat's ports, e.g. Discord
`50000-65535`, unless your game uses them.

### Switch to another game

**New game** (Dashboard, Map or **Settings → Tools**) clears the server list
and keeps locations. **Clear cache** is a fresh start: every server, grade,
location and server name goes; only the Always allow / block lists stay.

### Check it is working

1. Play a match. The Dashboard's state line shows **in match** while you
   play, and **matchmaking** while a gaming device is looking for a game
   (UDP to game ports; a download or the web is not matchmaking).
2. **Now playing** on the Dashboard and the Overview shows the server you
   are on, with its ping and grade.
3. **Settings → Tools → Verify rules** checks the firewall rules are in
   place; **Show status** gives the full state.

---

## 5. Troubleshoot

**Ping Filter is on but lists nothing.** No device is watched. Tick one under
**Settings → Devices → Watched devices**.

**It misses a game, or a block does not hold.** Flow offloading is on.
**Settings → Tools → Show status** says so. Turn it off with **System →
Maintenance → Diagnostics → Disable flow offloading**.

**Everything is blocked.** A new server is held until it is graded; in
distance mode without Ping Catch, until its location is known. If location
lookups fail, `qos-ex.sh pingfilter geo_check 1.2.3.4` over SSH says why.

**Matchmaking never finds a game.** The limit is too tight. The Dashboard
shows **Matchmaking looks stuck** with a button that relaxes it one step
(ping limit or Ping Catch 10 ms higher, or the radius a quarter wider).

**Servers that ignore ping stay on estimates (~), even ones you played
on.** The game's first exchange is timed from the router's conntrack
events, and another kernel module can take those: full-cone NAT built
without shared events does, after a firewall stop or restart. The
Dashboard then says **Handshake timing gets no conntrack events**. Over
SSH, `rmmod nf_conntrack_netlink && modprobe nf_conntrack_netlink`, or a
reboot, brings them back.

**The Dashboard says Conntrack on this router prints no usable times.** On
a router with a 32-bit CPU (many MIPS and ARM routers), the conntrack tool
of OpenWrt 24.10 and 25.12 prints the time of each event with no usable
fraction of a second, so the game's first exchange cannot be timed. The
Ping Filter times none on that router and grades servers on their ping
from the router and on estimates; a server that ignores ping keeps its
estimate (~).

**A game over IPv6 is not filtered.** Ping Filter grades IPv4 servers only;
the Dashboard warns when a watched device has a public IPv6 address. Turn
IPv6 off for that device (no IPv6 lease for it on the router).

**A server is in the wrong place.** Forget it with **×** on **Servers**;
its location is looked up again.

**The map is blank.** Map tiles load in your browser from the internet;
check the device you browse from is online.

**Rule errors or the log.** **Settings → Tools → Rule errors**, and the
Ping Filter log on **System → Logs**.

---

## 6. How a server is judged

1. **New server.** With a ping limit or Ping Catch, its first 2 packets pass
   so the game's first exchange is timed, then it waits until graded. A
   server that opens the connection to your device (a port forward, UPnP,
   a peer-to-peer host) is let through until graded: that exchange cannot
   be timed. In distance mode without Ping Catch, or with a country list,
   it waits from its first packet until located. Watch only holds nothing.
2. **Its ping.** A short ICMP ping burst (the median) and the game's first
   exchange. A server that ignores ping gets an estimate from measured
   servers first: the lowest in its /24, then the median of those within
   150 km (ICMP and the game's exchange alike); then earlier readings in its
   /24, then its distance. An estimate is the last resort: the game's first
   exchange replaces it. A first exchange under 2 ms is not a round trip
   and is not used, and no reading under 2 ms goes into an estimate. On a
   router whose conntrack prints no usable times (a 32-bit build) the first
   exchange is not timed.
3. **A reading only lowers the figure.** One slow ping does not block a
   server that measured under the limit. **Re-check cache** and play can
   raise it. The game's first exchange over the limit, on a server whose
   estimate is under it or that has no estimate yet while its location is
   still coming, counts only on two separate connects: a server blocked on
   one slow reply would never be timed again. With Ping Catch that holds
   for every server without a ping of its own: until a second connect
   confirms it, the server stays out of the game. With no limit
   (Watch only, or distance without Ping Catch), one more than twice the
   estimate plus 50 ms waits for a second connect too: a first reply that
   slow is the server's own delay, not the distance. A first ping more
   than 25% over the server's estimate
   is checked again before it is used (the lower of the two counts), and a
   ping figure older than three days is measured again while you are not
   playing, so a route that got slower shows.
4. **Ping Catch** (distance mode): inside the radius every server is let
   in. Outside it, only the server's own ping lets it in: at or under the
   catch it is let in, over it kept out, also while its location is still
   coming (once located inside the radius, it is let in). A server with no
   ping of its own goes with the measured servers in its /24 and area; when
   they do not decide, an estimate over the catch keeps it out, and
   otherwise it waits out of the game (**held** on the Servers list) until
   its own ping is graded. With a country list it is let in on its
   estimate: every new server is held there, so nothing could time it.
5. **While you play on it**, Ping Filter's own re-grades never cut the
   server: a block waits until 30 s after its last game packet. With Ping
   Catch that covers only a server the game was let through to: a held one
   is not being played, and a new one is judged on its own ping even
   mid-match. The Dashboard and Map controls, **Always block**, **New game**
   and **Clear cache** act at once.
6. **Graded by playing**: when you stop playing on a server, the ping
   measured during play becomes its figure and it is graded again. A
   figure from the game's first exchange stays when it is at or under the
   limit or was timed on two connects.

A server on a game company's own network shows the company (Riot Games,
Valve, Blizzard, Ubisoft, Activision, EA, Epic Games, …), from its location
lookup. Servers on hosting networks (cloud providers) show no name.

---

## 7. Over SSH

**Set up.** The device must already be a gaming device (`ips.gaming_mac`,
see [SETUP.md](SETUP.md#8-over-ssh)):

```sh
uci add_list qos-ex.pingfilter.pf_devices='aa:bb:cc:dd:ee:ff'
uci set qos-ex.pingfilter.home_lat='51.50'
uci set qos-ex.pingfilter.home_lon='-0.12'
uci commit qos-ex
qos-ex.sh pingfilter enable
```

`enable` refuses, and says why, until a device is watched and the home is
set. `qos-ex.sh pingfilter disable` turns it off.

**Pick a mode.** A preset, one of `competitive` (your base ping + 40 ms),
`casual` (base ping + 80 ms), `distance` or `observe` (Watch only); or the
values themselves:

```sh
qos-ex.sh pingfilter profile casual
qos-ex.sh pingfilter threshold 60     # ping limit, ms (0 = Watch only)
qos-ex.sh pingfilter mode distance    # ping or distance
qos-ex.sh pingfilter radius 1500      # km
qos-ex.sh pingfilter catch 40         # Ping Catch, ms (0 = off)
```

These apply at once, also to the server being played.

**Check it.**

```sh
qos-ex.sh pingfilter status     # daemon and filter state
qos-ex.sh pingfilter verify     # the firewall rules are in place
qos-ex.sh pingfilter devices    # the watched devices
qos-ex.sh pingfilter servers    # server list (JSON)
qos-ex.sh pingfilter sessions   # play history (JSON)
qos-ex.sh pingfilter version
```

**Lists and resets.**

```sh
qos-ex.sh pingfilter whitelist 1.2.3.4       # always allow (an address or a.b.c.d/len)
qos-ex.sh pingfilter blacklist 1.2.3.4       # always block
qos-ex.sh pingfilter forget 1.2.3.4          # remove everything known about it
qos-ex.sh pingfilter reclassify              # Re-check cache
qos-ex.sh pingfilter session_reset           # New game
qos-ex.sh pingfilter clear                   # Clear cache
```

**Logs and errors.**

```sh
cat /var/log/qos-ex-pf-daemon.log
qos-ex.sh pingfilter nfterr
qos-ex.sh pingfilter geo_check 1.2.3.4   # why a location lookup fails
```

`qos-ex.sh pingfilter` lists every command.

---

## Settings reference

Section `pingfilter` in `/etc/config/qos-ex`. After a change with `uci`, run
`uci commit qos-ex` and `qos-ex.sh pingfilter reload`. The daemon
range-checks every number.

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `0` | Ping Filter master switch |
| `pf_devices` | *(list)* | Which gaming devices are watched (**Watched devices**): a gaming device's MAC or IPv4 address. You tick them; a device that stops being Gaming is dropped. **Empty = none** |
| `block_mode` | `ping` | `ping` or `distance` |
| `threshold_ms` | `0` | Ping limit, 0–5000. `0` = Watch only: only the Always block list and a country list block |
| `base_ms` | *(empty)* | Your base ping as **Casual** / **Competitive** last measured it (the router's ping to `autosetup.ping_host`); their limit is it + 80 / + 40 ms. Written by them; the filter itself does not read it |
| `home_lat` / `home_lon` | *(empty)* | Your location |
| `home_radius_km` | `1000` | Distance-mode radius, 50–20000 |
| `ping_catch_ms` | `0` | Distance mode, 0–250: outside the radius, servers whose ping is at or under this are let in too. Inside the radius every server is. `0` = the radius alone decides |
| `ping_var_pct` | `5` | Margin on both limits, 0–50 (80 ms passes up to 84 ms) |
| `first_pkts` | `2` | With a ping limit or Ping Catch: packets of a new server's flow let through so the game's first exchange is timed; the rest wait until it is graded (0–20). Only flows your device opens are held. `0` = no hold: a new server is let through until graded. Not in the web app |
| `whitelist` / `blacklist` | *(lists)* | **Always allow** / **Always block**: an address or a range (`1.2.3.0/24`) |
| `allow_country` | *(list)* | Country names as the server list shows them (`United Kingdom`). When set, servers elsewhere are blocked |
| `ignore_ports` | `3478-3481` | UDP ports (the server's port) never treated as game servers, not counted as play, and never blocked. Add your voice-chat ports (e.g. Discord 50000-65535) unless your game's servers use them |
| `auto_pin` | `2` | 0–20. Once a /24 holds this many Always allow (or Always block) servers, new ones in it join the list. With Ping Catch, a server without its own ping goes with the measured servers in its /24 and area (150 km): more under the catch than confirmed over, with one of them in its /24 or this many in the area, lets it in; this many confirmed over (the game's exchange over the catch on two connects, or a country not allowed) and none under keeps it out. 0 = off |
| `geoip_lookup` | `yes` | Look up server locations. New servers' addresses go to `get.geojs.io` together, up to 50 in one HTTPS request; any it cannot place to a city are sent one by one to the lookup services, in turn until one answers: `ipwho.is`, `get.geojs.io`, `freeipapi.com`, `ipapi.co` (all HTTPS), then `geoip_api`. `no` = no lookups: servers have no map position, and distance mode has no location to work from |
| `geoip_api` | `http://ip-api.com/json` | The last lookup service (plain HTTP). Set it to a service of your own and only that one is asked |
| `lite` | `0` | `1` = Ping Filter Lite, for small routers (Auto Setup suggests it on a low-spec router): the ping limit or radius, locations, the lists and the new-server hold only. No gameplay grading, handshake timing or Ping Catch; it checks every 2–3 s instead of every second and pings 4 servers at a time, not 20 |
| `telemetry` | `1` | Grade from gameplay: measure jitter and stutter while you play, and grade servers on the ping during play |
| `max_servers` | `250` | Server list size (50–2000). Above it the servers not seen for longest are dropped (Always allow and Always block stay). The pages and `pingfilter servers` show the first 800, plus servers in use |
| `row_ttl` | `604800` | Seconds an unseen server stays in the list (7 days; 43200–2592000) |
| `persist_interval` | `3600` | Seconds between saves of the server list to flash (60–86400; stop and reboot always save) |
| `area_adjust_pct` | `5` | A server that ignores ping is estimated from measured servers near it; that figure is lowered by this many percent (0–50) |
| `active_pps` | `20` | UDP packets a second that count as playing (5–500); lower it for low tick-rate games |

The rest of how the Ping Filter works (echoes per ping, retries, estimate
ranges, telemetry timings) is fixed; `uci show qos-ex` lists nothing else.
