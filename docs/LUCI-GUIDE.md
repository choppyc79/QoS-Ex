# QoS-Ex — Web App Guide

This guide goes through the QoS-Ex web app (**Network → QoS-Ex** in LuCI)
page by page, in menu order: what each page tells you, and what each setting
changes. It is written for LuCI app **1.3.9.3**. For installing and first
setup see [SETUP.md](SETUP.md); for how the Ping Filter judges servers see
[PINGFILTER.md](PINGFILTER.md).

---

## Finding your way around

| Tab | Pages | Use it to |
|---|---|---|
| [Auto Setup](#auto-setup) | | Set QoS-Ex up. Shown only until it is set up |
| [Overview](#overview) | | See whether shaping and the Ping Filter are working, and turn them on or off |
| [Ping Filter](#ping-filter) | Dashboard · Map · Servers · Settings | Watch and filter the game servers your devices connect to |
| [Live](#live) | Stats · Flows | See what the shaper is doing right now |
| [Setup](#setup) | Line · Devices & Ports · Queue · Rules | Change how your line is shaped |
| [System](#system) | Status · Logs · Maintenance | Check health, read logs, update, back up and reset |

Changes take effect in one of two ways:

- **Setup** and **Ping Filter → Settings** are normal LuCI forms: make your
  changes, then press **Save & Apply**.
- The on / off switches, the action buttons, and the Ping Filter's mode
  cards and Map sliders act straight away, with no Save & Apply.

The Overview and the Live pages keep themselves up to date. The other live
pages follow LuCI's refresh, which the **REFRESHING** switch at the top of
LuCI pauses; the two Live pages have their own refresh selector.

The banner above the tabs shows whether the shaper and the Ping Filter are
on, whether a game is being played, the main figures for the tab you are
on, and the branch and versions installed, for example
`main · app v1.3.9.3 · PF v2.0.9.4 · shaper v3.2.1.0`.

Colours follow your LuCI theme: green is on or healthy, red is off or a
fault, yellow is a warning, and blue is a match being played.

LuCI's own **Status → Overview** page also gets a small QoS-Ex box with the
same state and headline figures, and a link to Maintenance when an update is
available. Its Ping Filter figures refresh every 30 seconds.

---

## How QoS-Ex sorts traffic

Most pages talk about classes and DSCP marks, so it helps to know them
first. The QoS-Ex firewall rules (the *rule set*) give each connection or
packet one of nine DSCP marks. The queue (CAKE, HFSC or HTB) then serves
each mark in its class.

| Class (HFSC / HTB) | Marks | Typical traffic | CAKE tin (diffserv4) |
|---|---|---|---|
| **Gaming** (1:10) | EF | The game itself: UDP from your gaming devices | Voice |
| **Voice** (1:11) | CS5, CS4 | Small, steady UDP such as voice chat; video calls | Voice |
| **Video** (1:12) | AF41, AF42 | Light, interactive TCP and mid-size web traffic | Video |
| **Default** (1:13) | CS0 | Everything not singled out, including most browsing and streaming | Best Effort |
| **Low** (1:14) | AF11, CS1 | Busy UDP and traffic moved down for a while (AF11); low-priority devices (CS1) | Best Effort (AF11), Bulk (CS1) |
| **Bulk** (1:15) | LE | Heavy downloads, torrents and the bulk ports | Bulk |

Exactly what lands where depends on the rule set (see [Rules](#rules)).

Under **HFSC** and **HTB**, Gaming has its own rate inside the shaped rate
and is always served first. It never borrows from the other classes, but
they may use what it leaves. The other five classes share the rest (Voice
5%, Video 20%, Default 55%, Low 10%, Bulk 10%), and each may take more while
the others are idle.

**CAKE** has four tins instead of six classes. EF still goes to its top tin,
Voice. Video calls are marked AF41 under CAKE and go to Video: in Voice a
busy call would make the game wait. CAKE also shares the line fairly between
your devices, so one busy device cannot crowd out another.

---

## Auto Setup

Auto Setup checks your router, measures your line, and suggests a full set
of shaper settings for both. Nothing changes until you apply, and **System →
Maintenance → Undo last Auto Setup** puts your old settings back, shaping on
or off as it was. It sets up the shaper only: the Ping Filter is optional and
has its own setup.

The tab is there after a fresh install, after **Reset to defaults**, and
after **Run Auto Setup** or **Undo last Auto Setup** on Maintenance. Once setup
is done it goes away.

### Getting started

The **Set up QoS-Ex** card offers three choices:

- **Auto Setup** — runs the router check and the speed test, then takes you
  through the steps below.
- **Manual setup** — keeps the defaults (CAKE, Adaptive rules) and opens
  **Setup → Line**. If QoS-Ex was set up before, this reads **Keep current
  settings** and changes nothing.
- **Restore a settings file** — loads a `QoS-Ex Settings.cfg` saved earlier
  from Maintenance, and restarts QoS-Ex with it.

### Your router

What the router check found:

- the model, and how it rates the router (below);
- CPU cores and speed, memory and free flash;
- the WAN device, and the port under it (driver, link speed, queues);
- DSL sync rates, on a router with a DSL modem.

Anything QoS-Ex needs that is missing (a kernel module or a package), and
any other shaper already on the WAN, is shown in red.

The rating decides most of what Auto Setup suggests:

| Rating | Which routers | Suggested |
|---|---|---|
| Low-spec | One CPU core, a MIPS CPU, or 128 MB of RAM or less | HTB with sfq queues and the Simple rule set; the download shaped on the LAN device when there is only one; Live pages refreshed every 2 s; Ping Filter Lite with a smaller server list |
| Mid-range | Everything between the two | HFSC with fq_codel queues and the Adaptive rule set |
| High-end | Any x86 router, or 4 or more cores at 1500 MHz or more with 1024 MB of RAM or more | CAKE with the Adaptive rule set (HFSC on a router that is not x86 when the line is faster than 500 Mbit) |

The router's own figures count: a router sold with 1 GB of RAM reports a
little under 1024 MB, and some CPUs report no speed, so both are rated
mid-range. The limits, and the queue and rule set for each rating, can be
changed in the `autosetup` section
([SETUP.md](SETUP.md#autosetup--auto-setup)).

### ① Line speed

The speed test downloads and uploads from Cloudflare's speed servers for
about 30 seconds (up to 1500 MB each way). Shaping and the Ping Filter are
paused while it runs. It then shows each speed against the WAN port's, and
what held it back:

- **the line**: the result is your line speed;
- **the WAN port**: the result is the port's top speed, and the line may be
  faster;
- **the router's CPU**: the router could not go faster, so the result may
  be under your line's speed. Step ③ says so on the speed rows: type the
  line's speeds if you know them. The test runs with shaping off, and
  shaping takes CPU too, so step ③ suggests a queue one step lighter than
  your router's rating (CAKE → HFSC, HFSC → HTB). The rule set stays the
  rating's.

**Bufferbloat, unshaped** grades how far your ping rose under load with
shaping off, alongside the idle and loaded pings. This delay under load is
what QoS-Ex is there to remove.

| Grade | Ping rise under load |
|---|---|
| A+ | under 5 ms |
| A | under 30 ms |
| B | under 60 ms |
| C | under 200 ms |
| D | under 400 ms |
| F | 400 ms or more |

Cloudflare limits how many tests one address can run in a short time. If
the test cannot run (it answers HTTP 429), the reason is shown here: type
your line's speeds in Mbit and press **Use these speeds**, or try again
later.

### ② Devices

Every device on your network that the router knows (not the router itself,
nor anything on the WAN side), each set to **Normal**, **Gaming** or **Low
priority**. It is the same list as **Setup → Devices & Ports**. A gaming
device's game traffic goes to the Gaming class, and low-priority devices give
way to everything else.

If no gaming device is set yet, consoles are set to Gaming from the names
they give the network (PlayStation, Xbox, Nintendo, Steam Deck). Check the
list, then press **Next**. Devices are saved by MAC address. A device added
by its address on Setup is left as it is.

### ③ Settings to apply

Each suggested change is a row with its reason. Untick any you do not want.

- **Line** — the WAN device (only when Setup has the wrong one), the line
  speeds, the link layer and the overhead. The speed row also shows the rate
  QoS-Ex will shape at once **Headroom** is taken off.
- **Queue and rules** — the queue type, its leaf queue and the rule set for
  your router's rating. The queue is one step lighter (never two) when the
  speed test was held by the router's CPU, and HFSC replaces CAKE on a
  router that is not x86 when the line is faster than 500 Mbit
  (`cake_max_mbit`). HTB is suggested instead when the queue's kernel
  module is missing. On a router that is already set up, the rating's queue
  is a row like any other: untick it to keep yours.
- **This router** — how often the Live pages refresh.
- **Ping Filter, if you use it** — sizing for the router: Lite on a low-spec
  router, how many servers are kept, and how often the list is saved. These
  rows do nothing while the Ping Filter is off.

Settings Auto Setup leaves unchanged are folded under **Settings that
stay**, each with the reason.

Press **Apply and start** to apply the ticked rows and the devices, and turn
the shaper on. The button reads **Finish and start** when nothing needs to
change, and just **Apply** or **Finish** while the shaper is already
running. The Overview opens when it is done.

**Packet steering** spreads the work of receiving packets over the CPU
cores. If it is off on a router with more than one core, Auto Setup offers a
separate **Turn on** button. Packet steering is an OpenWrt network setting,
not part of QoS-Ex, so it is never applied with the other rows.

---

## Overview

The page to keep open: whether everything is working, what you are playing,
and a switch each for the shaper and the Ping Filter.

Some cards show only when they are needed:

- **Set up QoS-Ex** — QoS-Ex is not set up yet. Links to the Auto Setup tab.
- **Get started** — the shaper is not on, or no gaming device is set yet.
  Lists the steps that are left, with a link to each.
- **Needs attention** — something is wrong, for example:
  - a health check failing;
  - a WAN interface that is not your internet line;
  - flow offloading turned on;
  - settings made by Auto Setup on other hardware (a backup restored onto a
    new router).

  Each item links to where it is fixed (**System → Status** or
  **Maintenance**).
- **Installed copy is out of date** — a script in `/root` differs from the
  copy QoS-Ex runs. Update from **System → Maintenance**.

The other cards are always there:

- **Now playing** — the game server you are on: where it is, its ping
  (by ping or handshake, or an estimate), its grade, whether the Ping
  Filter allows it, and a small chart of latency, jitter and packet rate.
  It links to the Map. With no game on it reads **Waiting for a match** or **Matchmaking**, or says the
  Ping Filter is off.
- **Shaper** — the switch:
  - **On** starts shaping now and at every boot. It also turns flow
    offloading off, because offloaded traffic would skip the shaper.
  - **Off** stops shaping, turns the Ping Filter off too, and puts flow
    offloading back as it was.

  Under the switch: the queue type and rule set, how long the shaper has been
  running, and the rates it shapes at. **Restart** stops and starts the
  shaper. **Reload rules** reloads the rules, and restarts the shaper only if
  a queue setting has changed. **Settings** opens Setup.
- **Ping Filter** — the switch, the mode in words (`Ping ≤ 40 ms`,
  `Distance ≤ 1000 km · Ping Catch ≤ 40 ms`, `Watch only`), and what it is
  doing:
  - **In match**: you are playing.
  - **Matchmaking**: a gaming device is looking for a game (UDP to game
    ports, never a download or a web page).
  - **Watching**: on, with no game traffic.
  - **Armed**: on, waiting for the shaper to run.

  It can be turned on once a gaming device is watched and your home is set.
  Until then it says what is missing.
- **Download** and **Upload** gauges — the rate now, against the rate
  QoS-Ex shapes at.
- **Gaming traffic** — the rate of the game itself over the last 5 minutes:
  the EF-marked UDP from your gaming devices, for every queue type. With
  **Wash DSCP Down** off, UDP that a device marks EF itself is counted too.
- **Gaming flow** — each game connection now, with the Ping Filter's verdict
  on its server. Opens **Flows**.
- **Gaming queue** — how the Gaming class is coping, in each direction.
  Under CAKE: the Voice tin's delay against its target, drops and ECN marks,
  and flows. Under HFSC / HTB: class 1:10 and the queue inside it (packets
  waiting against its limit, delay, drops, packets sent). Low delay and no
  drops mean your game is not waiting behind other traffic.
- **At a glance** — your gaming devices, each with a dot: green when the
  router hears the device now, red when it has not lately. Also the Ping
  Filter setup, and how many servers are allowed and blocked.
- **Health & updates** — whether every health check passes, and whether an
  update is available.

---

## Ping Filter

The Ping Filter finds the game servers your watched devices connect to,
measures their ping, and can block the ones that are too slow or too far
away, so matchmaking puts you on a better one. A block stops game (UDP)
traffic only: logins, the store and web pages on the same address still
work. How servers are judged is in [PINGFILTER.md](PINGFILTER.md).

It is off until you switch it on. While it is off, each Ping Filter page
shows the **Set up the Ping Filter** card with two steps:

1. **Gaming devices to watch** — tick them under **Settings → Devices**.
   Only Gaming devices are offered, and none are ticked for you. With no
   gaming device yet, the link goes to **Setup → Devices & Ports** first.
2. **Your home on the map** — right-click your home on the Map, or zoom in
   until it is under the cross and press **Pin home here**.

Then turn the switch on. It starts in **Watch only** (a mode picked before
is kept), which lists and grades servers but blocks nothing.

### Dashboard

The Ping Filter's main page. Along the top:

- the **switch**;
- **Restart**, which restarts the Ping Filter;
- **New game**, which clears the server list for a new game and keeps
  locations;
- **Clear cache**, a fresh start that removes everything except the Always
  allow and Always block lists.

The figure tiles (**Mode**, **Servers**, **Always allow / block**,
**Watched devices**, **Allowed / blocked**) each link to where that is set.

**Mode cards.** Click one to switch mode. Each mode keeps its own number.

- **Ping** — block servers whose ping is over a limit: **40 ms**, **80 ms**,
  or your own **Ping limit** (1 to 5000 ms).
- **Distance** — block servers further from home than your **Radius** (50 to
  20,000 km). **Ping Catch** (0 to 250 ms, 0 = off) also lets in servers
  outside the radius whose ping is at or under it.
- **Watch only** — find and grade servers. Only the Always block list and a
  country list block anything.

Mode changes apply at once, even to the server you are playing on. While a
match is on, the Dashboard warns: **A game is on: this may block the server
you're playing**. Which mode to choose: [Pick a
mode](PINGFILTER.md#pick-a-mode).

**Now playing** — the server you are on, with:

- the company name, when it is on a game company's own network;
- its grade, ping and jitter;
- **Allow**, **Block** and **×**, as on the Servers page;
- a graph of the pings taken while you play.

A ping is shown as **measured** (by ping, or by timing the game's first
exchange with the server, the handshake) or as an **estimate**, for a
server measured neither way yet.

**Played servers** — every server you have played on, with its grade, play
time and when you last played on it. Click one for the detail:

- how its score is made up, its verdict, and where its ping came from;
- its distance from home, jitter, stutter, packet rate and time played;
- its last five matches.

**×** clears a server's history.

| Grade | Score |
|---|---|
| S | 90 and over |
| A | 80 to 89 |
| B | 70 to 79 |
| C | 60 to 69 |
| D | under 60 |

Two warnings can appear:

- A watched device has a public IPv6 address. The Ping Filter checks IPv4
  servers only, so a game that connects over IPv6 is not filtered.
- **Matchmaking looks stuck**: servers keep being blocked and no game
  starts. Its button loosens the filter one step: the ping limit 10 ms
  higher, Ping Catch 10 ms higher (up to 250), or, without Ping Catch, the
  radius a quarter wider.

### Map

The servers your devices have used recently, plus the Always allow and
Always block entries, around your home and its radius. These are the same
servers as on the Servers page. A server with no location yet is counted
under the map, and listed on Servers only.

| Pin | Meaning |
|---|---|
| Green | Allowed |
| Red | Blocked |
| Grey | Known from earlier, no verdict in force now |
| White ring | Always allowed |
| Black ring | Always blocked |
| Large, pulsing | The server you are playing on now |

The radius ring is in the accent colour in distance mode. In ping mode it
is dashed grey, for reference only. Click a pin for the server's grade,
details and actions.

While the Ping Filter is on, the controls above the map are **New game**,
**Re-check cache**, the **Mode**, and sliders for whichever of the **Ping
limit**, **Radius** and **Ping Catch** the mode uses. Like the mode cards,
they apply at once. The legend under the map shows or hides each kind of
pin.

To set your home, right-click the map; right-click the home pin to remove
it. While the Ping Filter is off you can also zoom in until your home is
under the cross and press **Pin home here**, which works on a phone too.

Map tiles are loaded by your browser, so the device you are browsing from
needs internet access. The rest of the app works without it.

### Servers

Every server the Ping Filter knows, in one table, plus every Always allow
and Always block entry, including one not seen yet. With `max_servers` set
above 800, the table shows the first 800 and the servers in use.

- The chips show only allowed, blocked, always allowed, always blocked or
  cached (known from earlier) servers.
- The list starts grouped by country, best ping first. **Sort** changes
  that, and the search box finds an address, country, city or owner.
- A server on a game company's own network shows the company after its
  address (Riot Games, Valve, Blizzard, …).

On each row:

- **Allow** or **Block** pins the server either way. Press the lit one again
  to unpin it, so it is judged by ping or distance again.
- **×** forgets the server: everything except its location.
- A click opens its detail, as on the Dashboard.

**Add a server** takes an address or a range such as `1.2.3.0/24`, as
**Always allow** or **Always block**. **Clear always allowed** and **Clear
always blocked** empty a list.

### Settings

Two tabs. **Settings** holds the options, saved with **Save & Apply**.
Unlike the Dashboard and Map controls, a change saved here does not cut the
server you are playing on: a block waits until that game is over.

- **Devices** — **Watched devices**: which gaming devices the Ping Filter
  follows. Only you tick them. A device that stops being Gaming on Setup is
  dropped. If none is ticked, the Ping Filter watches nothing.
- **Mode** — **Block by** ping or distance, then the **Ping limit** (0 =
  Watch only) or the **Radius** and **Ping Catch**. **Only these countries**
  blocks servers in every other country.
- **Home** — latitude and longitude, or **Set on the Map**.
- **Advanced options** — tuning you rarely need:
  - **Grading**:
    - **Ping tolerance**: a margin over the limit (5% lets an 80 ms limit
      pass 84 ms).
    - **Auto-list /24 after**: how many Always allow (or Always block)
      servers in one /24 network it takes before new ones there join the
      same list. With Ping Catch, it is also how many measured servers
      nearby decide a new one.
    - **Area lower by**: how much to lower the estimate for a server that
      does not answer ping.
    - The **in-game rate**: lower it for games that send few packets.
    - **Grade from gameplay**: judge servers by the ping during real games.
    - **Lite (small routers)**.
  - **Network**:
    - **Ignore UDP ports**: ports that are never game servers. Add your
      voice chat's, for example Discord `50000-65535`.
    - **Look up locations**.
  - **Memory** — how many servers are kept, for how long, and how often the
    list is saved to flash.

**Tools** — actions and checks, with their output in the Result box:

- **Run scan now**.
- **Re-check cache**: judge every known server against the current settings
  again.
- **New game** and **Clear cache**, as on the Dashboard.
- **Show status**, **Live capture (10s)**, **Verify rules** (the filter's
  firewall rules are in place) and **Rule errors**.

---

## Live

What the shaper is doing right now. Both pages have a **refresh** selector
(1, 2, 5 or 10 seconds, or paused). It starts at the router's setting, and
the one you pick is remembered in that browser.

### Stats

Throughput and queue health, with a tab each for Download and Upload. While
the shaper is not running, the page says so and offers the switch or
**Restart**.

- **Class cards** — one per class, or per tin under CAKE: the rate now,
  drops and backlog. A class that is dropping packets or holding a backlog
  is outlined in red.
- **Throughput** — the last 5 minutes, stacked by class, with a dashed line
  at the shaped rate.
- **Queue delay** — how long packets wait in each class. This is the chart
  that shows shaping working: start a big download, and Bulk or Default
  rises while Gaming stays flat. Under HFSC / HTB the delay is estimated
  from the backlog.
- **Per-class counters** — rate, peak, share, drops, backlog and totals,
  with the delay (CAKE) or ECN marks (HFSC / HTB).
- **CAKE tins** or **Queue details** — the full table from the queue for
  that direction. The raw output is `qos-ex.sh stats` over SSH.

The charts start again when the page is reloaded.

### Flows

Every active connection, one row each, with its DSCP mark and class. This is
the quickest way to check that your game is in Gaming.

- Connections are grouped by device. Untick **By device** for one flat
  list. A gaming device is marked **GAME**, and its group opens with the
  page.
- Click a device to open it, and a connection for its detail.
- The strip under the banner shows the connections and rate in each class.
  Click a class to show only that one.
- The search box filters by address, port, protocol, DSCP, class or device
  name.
- Idle connections (no traffic now, or two packets or fewer) are hidden, and
  the count says how many.
- **Max rows** keeps the busiest connections (50 to 1000; 200 to start).
  **Reset** puts the search, filter, grouping and sort back as they were.

A connection to a server the Ping Filter knows also shows its verdict, ping
and country.

---

## Setup

Everything about how the line is shaped and which traffic goes in which
class, on four tabs (**Line · Devices & Ports · Queue · Rules**) with one
**Save & Apply** for all of them.

**Save & Apply** restarts the shaper when a change affects the queues it
builds: the WAN, the rates, the overhead, the queue type or one of its
values. Under Adaptive with HFSC / HTB, the UDP fast-flow rate also counts,
because it sets the Gaming class's floor. Any other change only reloads the
rules.

### Line

- **WAN interface** — the device your internet line is on. The note under
  it names the one in use now (for example `pppoe-wan`). A device that does
  not exist, or a switch's CPU port, stops QoS-Ex from starting and says
  so. One that exists but is not your line is flagged as a WAN mismatch.
- **Download rate (Mbps)** and **Upload rate (Mbps)** — your line speed as a
  speed test measures it. `0` leaves that direction unshaped.
- **Headroom** — how far under the line speed to shape: 100% (off), or 95%
  down to 70%; 90% by default. Shaping a little under the line keeps the
  queue on the router, where QoS-Ex controls it, rather than in the modem or
  at your ISP. With HFSC or HTB keep it at 90% or lower: they undercount
  bursts of merged packets (GRO) by 3–5%.
- **Link layer** — **Ethernet** for VDSL, cable, fibre and Ethernet lines;
  **ATM** for ADSL, which pads every packet into 53-byte cells.
- **Overhead (bytes)** — the bytes each packet adds on the line, so QoS-Ex
  charges what the line really carries. The value for each kind of line is
  in [SETUP.md](SETUP.md#set-your-line-speeds).
- **MPU (bytes)** — the smallest size any packet is charged at; 84 on
  Ethernet.

### Devices & Ports

- **Devices** — every device on your network that the router knows (name,
  address and MAC; not the router itself, nor anything on the WAN side),
  each set to one of:
  - **Normal**;
  - **Gaming**: the device's game traffic goes to the Gaming class;
  - **Low priority**: the device's UDP goes to Low (all its traffic, under
    the Adaptive rules).

  Gaming and low-priority devices are listed first, and the filter box finds
  a device by name, address or MAC. Devices are saved by MAC, so one choice
  covers every IPv4 and IPv6 address the device uses, through new DHCP
  leases too. A saved device that is offline shows as *not on the network
  now*.

  A device the router cannot see the MAC of (one behind another router) can
  be added under the table by its address. It shows as *by address*.

  The Ping Filter watches gaming devices only once you tick them on **Ping
  Filter → Settings → Devices**. A device that stops being Gaming is dropped
  from that list.
- **Port lists** — **Web**, **Bulk TCP**, **Bulk UDP** and **Video-call**
  ports. Under the Simple and Adaptive rules, traffic on the bulk ports goes
  to Bulk and calls go to Voice (Video under CAKE). An empty list turns that
  rule off.

### Queue

- **Root qdisc** — the queue that does the shaping. Each choice keeps its
  own settings, so you can switch back and forth. Which to choose: [Pick the
  queue type and rule set](SETUP.md#pick-the-queue-type-and-rule-set).
  - **CAKE** (default): one queue that also shares the line fairly between
    devices; the least to tune.
  - **HFSC** and **HTB**: the six classes above, with Gaming served first.
- **Download shaped on** — where the download is shaped:
  - **IFB off the WAN** (default): incoming traffic is passed through a
    virtual device and shaped there, before it is routed. This covers every
    device on every LAN network.
  - **LAN device**: the download is shaped as it leaves your LAN device
    (usually `br-lan`). This skips the redirect, which saves CPU on a small
    router. But only what leaves through that one device is shaped: a guest
    network on another device, and internet traffic to the router itself,
    are not. Traffic from the router to your devices (LuCI, a file share on
    the router) and traffic routed in from another network are shaped too,
    at the download rate.

  **LAN device** names the device; the note under it shows the one found.
  Empty = found at each start.
- **CAKE**:
  - **Diffserv mode**: how CAKE groups the marks into tins. **diffserv4**
    (default) has Bulk, Best Effort, Video and Voice. **besteffort** has a
    single tin.
  - **Host isolation**: shares the line fairly between LAN devices first,
    then between each device's connections. Off uses CAKE's triple-isolate.
  - **Ingress mode**: on the download side, counts the packets CAKE drops
    against the rate too, since they have already crossed the line.
  - **RTT**: how quickly CAKE reacts to a queue building. 100ms suits most
    internet traffic.
  - Under **Advanced**:
    - **NAT lookup**, per direction: lets CAKE see each device behind NAT,
      for fair sharing. The download one applies only with the IFB.
    - Extra CAKE arguments per direction (for example `docsis` or `ptm`).
- **Gaming class — 1:10** (HFSC / HTB):
  - **Gaming rate (%)** of each direction (15%) plus the **Gaming rate
    floor** (400 kbit), never more than 85% of the line.
  - **RT burst** (HFSC): how far the class may burst briefly over its rate.
  - Under **Advanced**: the **Gaming leaf qdisc** (sfq by default: each flow
    gets its turn, so a second stream from a gaming device, such as a screen
    share, cannot crowd out the game), **Max delay** (pfifo / bfifo), the
    **Packet size** the queue is sized for, and each leaf queue's own values.
- **Classes 1:11 to 1:15** (HFSC / HTB):
  - **Voice RT curve** (HFSC): gives Voice a small guaranteed rate too.
  - The leaf queue: fq_codel (default) or sfq.
  - **Leaf tuning**: **Auto** sizes the queues from your line speed;
    **Manual** opens every value.
- **Tweaks**:
  - **ACK filter**: thins out TCP acknowledgements on the upload. **Auto**
    turns it on when the download is more than 14 times the upload, where
    ACKs alone can fill a slow upload.
  - **Download ratio cap** (HFSC / HTB): caps the download at the upload ×
    a ratio, so the upload always has room for the download's ACKs.
  - **TCP MSS clamp**: on a slow direction, makes TCP packets smaller, so a
    game packet waits less behind a full-size one. The **MSS gate** sets
    what counts as slow, and shows only while the clamp is in use.

The rates and queue values in force are on **System → Status**; the
counters are on **Live → Stats**.

### Rules

- **nft ruleset** — how traffic is given its mark:
  - **Adaptive** (default) decides each connection once, at its first
    packet. Traffic you have listed (gaming and low-priority devices, the
    bulk, video-call and VPN ports, DNS, ping) keeps its class for the life
    of the connection, except that a gaming flow as busy as a stream (over
    the UDP fast-flow rate, or about 2 Mbit) drops to Low while it stays
    that busy. Everything else moves as its behaviour changes:
    - a slow TCP connection goes up to Video;
    - steady small UDP goes up to Voice;
    - a busy UDP flow drops to Low;
    - a connection that takes a large share of the line for 10 seconds goes
      to Bulk. So do a device's connections that do so together, as with a
      download split over many connections.
  - **Advanced** marks every packet by its port, its size and its
    connection's packet rate.
  - **Simple (SGS)** is the SimpleHFSCgamerscript rules QoS-Ex grew from. It
    gives each connection one class, held for 30 s (TCP) or 5 s (UDP), and
    runs the fewest rules per packet.
- **Wash DSCP Down** — clears DSCP marks on download traffic, and ignores
  marks your devices set themselves, so only QoS-Ex's marks count. The
  download is classed by QoS-Ex's own mark, so a mark set by a remote
  server or your ISP cannot lift traffic into the Gaming class or CAKE's
  Voice tin: traffic QoS-Ex has not classed, such as the router's own, goes
  in the default class (HFSC / HTB) or the Best Effort tin (CAKE). Under
  CAKE the first packet of a connection opened from outside is the
  exception.
- **Wash DSCP Up** — clears DSCP marks on traffic leaving to the internet,
  after QoS-Ex has used them.
- **DSCP rules** — one switch per rule, named for the mark it sets, and the
  thresholds those rules use. Under Adaptive also: the Bulk share and time,
  the P2P connection rate and the VPN ports.
- **Active ruleset** — the rules as loaded, folded away until you open it.

---

## System

### Status

The page to open when something is wrong. It shows:

- the service state, the versions and the interfaces;
- **Health**, one check for each part of the setup, in the order a fault
  spreads: root queue → download queue → mirror device → DSCP restore →
  ruleset → service → interface hook. A fault in one part breaks the parts
  after it, so **the first red check is the cause**.
- warnings for a WAN interface that is not your line, flow offloading left
  on, conntrack accounting off, and mwan3 or pbr enabled (they use the same
  connection mark as QoS-Ex);
- the rates in force, the installed files, each class's queue (the CAKE
  settings under CAKE), the class rates (HFSC / HTB), and the gaming and
  low-priority devices by name.

Rows that do not apply to your queue type or rule set are left out. Missing
packages are listed with the command that installs them. The same report as
text is `qos-ex.sh status` over SSH.

### Logs

The shaper log, the Ping Filter log and the last update's log, each with a
**Last 50 / 200 / 1000 lines** choice, plus any rule set load error. Errors
are red and warnings amber. **Refresh** reads them again. **Clear logs**
empties them and removes the rule set error files; the update log is left
alone while an update runs.

### Maintenance

**Versions & updates** — the installed versions against the latest on
GitHub: LuCI app, Ping Filter, shaper.

- **Check now** looks again. **Check automatically** (on by default) looks
  at most once an hour, when QoS-Ex is opened.
- **Update now** installs only the parts that changed, and keeps your
  settings:
  - an update of the shaper pauses shaping for a few seconds;
  - an update of the web app logs you out, and you log in again to load the
    new app.

  The update's output is on **System → Logs** (Update log). A failed check
  or update is written there with its reason, and the card links to it. Only
  one update runs at a time: a page opened during an update, from LuCI or
  over SSH, shows it running.
- **Advanced → Update branch** — `main` (releases, the default) or `dev`
  (testing builds). When the branch picked is not the one installed, **Update
  now** becomes **Switch to main** or **Switch to dev**, and installs that
  branch's files, older or newer. A router whose branch was never picked
  stays on the branch it was installed from.

**Diagnostics** — **Generate debug report**, then **Copy report**, **Copy
for forum** or **Save .txt**.

- The report leaves out your home location, the router's name (unless it is
  the stock OpenWrt), its public addresses and IPv6 prefixes, your LAN and
  private addresses, your gaming and low-priority devices' addresses, and
  every MAC address. The addresses of the servers your devices talk to stay
  in.
- To report a problem on a forum, press **Copy for forum**, paste it into a
  new post and fill in the two lines at the top. For GitHub, copy the
  report, follow **Report an issue** and paste it into the form's Debug
  report box.

**Disable flow offloading** is here too, for when Status says it is on.

**Auto Setup** — **Run Auto Setup** brings the Auto Setup tab back. Your
settings stay as they are until you apply new ones. **Undo last Auto Setup**
puts back the settings from before the last Apply, shaping on or off as it
was then (off again after a first setup), and opens the Auto Setup tab again.

**Settings backup**:

- **Download settings** saves every QoS-Ex setting in one file, `QoS-Ex
  Settings.cfg`.
- **Restore from file…** checks the file first. One that was edited, cut
  short or is not a QoS-Ex settings file is refused; older `.qosex` and
  `.txt` backups are still accepted. It then puts the settings back and turns
  QoS-Ex on or off as the file says. If the file was saved before setup was
  finished, QoS-Ex opens on Auto Setup.

The settings from before a restore are kept as `/etc/qos-ex/config.bak`.
Server history is not in the file.

**Danger zone**

- **Reset to defaults** — erases the settings and turns QoS-Ex off: shaping
  stops, the Ping Filter is turned off, QoS-Ex no longer starts at boot, and
  flow offloading goes back to how it was. The old settings are kept as
  `/etc/qos-ex/config.bak`. QoS-Ex then opens on **Auto Setup**. The
  settings Auto Setup picks are left empty for it to fill; **Manual setup**
  fills them with the defaults instead.
- **Uninstall QoS-Ex** — removes the shaper, the Ping Filter, this app, the
  settings, the saved server history and the scripts in `/root`. Installed
  packages stay, and flow offloading goes back to how it was before QoS-Ex.
  LuCI then logs you out; when you log back in, QoS-Ex is gone from the
  menu.
