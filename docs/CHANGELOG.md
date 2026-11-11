# Changelog

The three QoS-Ex scripts are versioned independently. The first digit names
the script — `1.x` LuCI app (`QoS-Ex-luci-app.sh`), `2.x` Ping Filter
(`QoS-Ex-PF.sh`), `3.x` shaper (`QoS-Ex.sh`) — and only a script that changed
is bumped.

Current: **LuCI app 1.3.9.9 · Ping Filter 2.0.9.4 · shaper 3.2.1.7**

## LuCI app 1.3.9.9

- Fixed: the device lists on **Setup → Devices & Ports** and in Auto Setup's **② Devices** showed the router itself (`OpenWrt.lan` and its WAN address) and, on an Ethernet WAN, hosts on the WAN side such as the ISP's gateway. They now list only the devices on your network.

## LuCI app 1.3.9.8 and the installer

- Fixed: an install or update without a GitHub token could stop with `HTTP error 403`. GitHub allows 60 anonymous API calls an hour per internet address, shared by every device behind it, and one install uses about ten. Without a token, the installer, the update check and **Update now** now download from raw.githubusercontent.com, which has no such limit; a token still goes through the API.
- Changed: the one-line install is shorter (README, SETUP). For up to 5 minutes after an update is published, raw.githubusercontent.com can still serve some old files; an install then stops with "an update is probably being published" and changes nothing.

## LuCI app 1.3.9.7

- Fixed: after **Undo last Auto Setup** (System → Maintenance) the Auto Setup tab showed only from the second page you opened after it. Undo now opens the Auto Setup tab, as **Run Auto Setup** does.

## Shaper 3.2.1.7

- Fixed: **Undo last Auto Setup** (System → Maintenance) after a first setup left the shaper running with the settings it had just undone, while the Overview showed shaping as off. Undo puts back the settings from before Apply, and shaping was switched on after Apply; the shaper now follows the settings put back, so after a first setup it stops. Undo after a later run of Auto Setup goes on shaping with your earlier settings, as before.
- Fixed: after that Undo the Auto Setup tab did not come back, and the Overview's **Auto Setup** button opened "No page is registered" until a reboot or **Run Auto Setup**: LuCI kept the menu it had built while setup was done. Undo now makes LuCI build its menu again, as Apply does.
- Fixed: after QoS-Ex started with the Ping Filter on, the next start, stop or reload of the service (a redial, Restart, Save & Apply) could wait up to 25 s, and a Save & Apply then held up the reload of other settings too. The Ping Filter's check of the location services, which goes on in the background after a start, kept the service locked until it finished.
- Fixed: uninstall also removes the speed test's files and the update and LuCI installer locks from /var/run.

## Shaper 3.2.1.6

- Changed: with HFSC or HTB and Leaf tuning on Auto (the default), the memory limit of the class queues (fq_codel) is rounded to the nearest whole MB, so `tc qdisc show` lists it as `memory_limit 21Mb`, as it does for OpenWrt's own queues, not as a byte count such as `21756150b`. The limit moves by half a MB at most.

## LuCI app 1.3.9.6

- Fixed: the device table on Setup → Devices & Ports spans its card in every theme. It was only as wide as its longest device, with the Normal / Gaming / Low priority buttons in the middle of the card.

## LuCI app 1.3.9.5

- Fixed: with the Footstrap theme (OpenWrt 25.12 and later), a QoS-Ex page opened from LuCI's Status → Overview had none of its own styling, and the QoS-Ex box on Status → Overview had none after a QoS-Ex page. Footstrap changes pages without loading a new one and switches an app's stylesheet off outside the app that loaded it; each QoS-Ex page and the Status box now carry their own copy.
- Fixed: with Footstrap, the QoS-Ex banner above the tabs went away after the first click to another QoS-Ex page, and the "update available" note showed on the first QoS-Ex page only.
- Fixed: with Footstrap, the column titles of Overview → Gaming flow sat one top-bar height too low and covered the game's row.
- Fixed: with Footstrap, Live → Flows went on asking the router for its connection list every second after you left the page.
- Changed: with Footstrap, the active tab on QoS-Ex pages takes the QoS-Ex accent as a tint, instead of teal text on Footstrap's blue tab.

## Shaper 3.2.1.5

- Changed: an update from an older shaper moves a saved pfifo gaming queue (HFSC and HTB) to the new default, sfq, once. If you want pfifo, pick it again under Setup → Queue → Gaming class → Advanced: later updates leave it.

## LuCI app 1.3.9.4, shaper 3.2.1.4

- Changed: the queue inside the Gaming class (HFSC and HTB) is sfq by default, was pfifo. In pfifo, one more stream from a gaming device over the gaming rate (a screen share, Remote Play, a VPN) filled the queue: on a 10 Mbit upload with a 4 Mbit stream the game lost four packets in five and waited 28 ms. With sfq each flow gets its turn: no game packets lost, and with the game alone it is as fast as pfifo. New installs and Reset to defaults get sfq; a saved choice stays (Setup → Queue → Gaming class → Advanced → Gaming leaf qdisc).
- Changed: the Adaptive rules keep a gaming flow in EF only while it also stays under `udp_fast_pps` × `packet_size` bytes a second each way (450 × 576 B ≈ 2 Mbit by default), as SETUP already said. A stream of big packets under 450 a second kept EF before and could fill the Gaming class (HFSC, HTB) or CAKE's Voice tin; it now drops to Low, as a fast one does.
- Changed: under CAKE, video-call UDP (the video-call ports, Simple and Adaptive rules) is marked AF41, CAKE's Video tin, not CS4. CS4 shares the Voice tin with the game, and a call over a quarter of the line there made the game wait for the tin's turn: about 5 ms more on a 3 Mbit upload. HFSC and HTB keep CS4 (the Voice class).

## Shaper 3.2.1.3

- Changed: with CAKE and Wash DSCP Down on (the default), download traffic QoS-Ex has not classed, such as the router's own, goes in the Best Effort tin. It used to land in whatever tin its sender's or your ISP's mark picked, Voice included. The download restore now sets every packet's DSCP from its connection's QoS-Ex mark (none = Best Effort); only the first packet of a connection opened from outside still arrives as it was sent. With Wash DSCP Down off nothing changes: an unclassed connection keeps the DSCP it came with.

## Shaper 3.2.1.2

- Fixed: with CAKE and the download shaped on the LAN device, download traffic that leaves by another LAN-side network (a guest network, another VLAN) kept the DSCP it arrived with, though Wash DSCP Down (`wash_down`) was on: CAKE's wash only covers the device it shapes. The firewall now clears it, as it already did with HFSC and HTB.

## Shaper 3.2.1.1

- Changed: simpler code for giving download packets their class back from the connection mark. The WAN's IFB and the LAN device share one setup, and the chains that set the DSCP and the Adaptive rule set's replay map are built from the one list of marks. Classes, washing and every rule set work as before.
- Removed: the fallbacks for a kernel without ctinfo's mark copy (`cpmark`) or the `fw` filter. Every OpenWrt 24.10 and 25.12 build has both. On a router without them QoS-Ex now stops with an error, where it used to class downloads by the DSCP they arrive with.

## LuCI app 1.3.9.3, shaper 3.2.1.0

- Removed: multi-queue CAKE (`cake.mq`, Setup → Queue → CAKE → Advanced → Multi-queue), tested on OpenWrt 25.12. A packet a LAN device marks itself goes in a tin picked from that mark, not from QoS-Ex's; the 25.12 kernel lacks a later fix for long delays under load in every mode with fewer than eight tins (`diffserv4` included); and the tins and host fairness only hold within each queue. CAKE runs with one queue again everywhere, the download's IFB included, and an update removes `cake.mq` from the settings. It may come back once an OpenWrt release has the kernel fix.
- Changed: Auto Setup no longer turns on multi-queue CAKE. When the speed test finds the CPU is the limit, it suggests HTB with sfq and the Simple rule set on every router, as before shaper 3.2.0.5.

## LuCI app 1.3.9.2, shaper 3.2.0.9 (and the installer)

- Changed: System → Maintenance follows the new installer lines on its update progress bar, and an older installer's too.
- Changed: installing or updating over SSH (`QoS-Ex-install.sh`, `qos-ex.sh install`) reads more plainly. One heading names the branch, every step is an `ok`, `..`, `!!` or `XX` line, and versions are listed by module (app, Ping Filter, shaper). An update shows each part as unchanged or with its old and new version. The result line is followed by what to do next: run Auto Setup in LuCI on a new install (with the router's address), turn shaping on when it is off, or log in to LuCI again after the app was reinstalled.
- Changed: the installer mentions flow offloading only when it is on; it said "flow offload off" even where it had never been on.

## LuCI app 1.3.9.1

- Changed: Overview → Now playing names how the ping was measured: icmp, handshake or est (it said icmp for a handshake too).

## Ping Filter 2.0.9.4

- Fixed: in Watch only and distance mode without Ping Catch, a server that ignores ping stayed on its estimate for the whole match: the game's first exchange, timed on one connect, was not used while it read higher than the estimate, and a match is one connect. An estimate is now the last resort: that reading replaces it unless it is more than twice the estimate plus 50 ms (a first reply that slow is the server's own delay; it still lands on a second connect). With a ping limit or Ping Catch nothing changes: one connect over the limit still does not replace an estimate under it.
- Changed: the log line for a handshake not used yet says why in every mode (it said "over the limit" in Watch only, which has no limit).

## LuCI app 1.3.9.0

- Changed: no Reload button either once an update has finished on System → Maintenance: the page reloads by itself. Only a failed update shows a button.

## LuCI app 1.3.8.9

- Changed: System → Maintenance no longer shows a Log in button once an update that reinstalled the LuCI app has finished: the page goes to the login page by itself. A failed update keeps its button.

## LuCI app 1.3.8.8

- Changed: the QoS-Ex tile on Status → Overview, refreshed every few seconds while that page is open, and the first load of Live → Stats read the counters the light way, as the Live pages' refreshes already do, instead of running the whole shaper script each time. While the shaper is stopped they read them as before.

## LuCI app 1.3.8.7

- Fixed: the QoS-Ex tile on Status → Overview read Stopped or Off, with no rates and Ping Filter off, on a router running multi-queue CAKE (`cake.mq`). It now reads Shaping, as Live → Stats does.

## Ping Filter 2.0.9.3

- Fixed: the `matchmaking` command (command line only) printed a server's byte total past 2 GiB as -2147483648; it now prints the real figure.

## Shaper 3.2.0.8

- Fixed: an ifup of the WAN device that came while QoS-Ex was restarting after an earlier one was dropped. When it was a second PPPoE redial, the new `pppoe-wan` could stay unshaped until the next redial or restart. The ifup hook now runs that ifup through its checks once the restart is done: a device that lost its queues is shaped again, one still shaping is left alone (wan6 coming up just after wan still restarts QoS-Ex only once).

## Ping Filter 2.0.9.2

- Fixed: two clean-ups kept the wrong rows on a router, as BusyBox sort on OpenWrt ignores the column it is told to sort on. Past 2000 remembered /24 blocks, the clean-up kept the first ones by name instead of the newest; past the server limit (plus 50), the play history kept the lowest addresses instead of the servers played last, so a server just played could lose its history. Both now keep the newest.

## LuCI app 1.3.8.6

- Changed: Overview → Gaming traffic counts only EF-marked UDP flows (the gaming devices' game traffic), for every queue type. Under CAKE it showed the whole Voice tin, which also holds other traffic; it now reads the game flows from the connection table. A flow opened from outside (a port forward) is counted the right way round, on the Gaming flow card too.

## Shaper 3.2.0.7

- Changed: the connection list the LuCI pages read puts EF-marked UDP flows (the game) first, so a match that has just begun is never cut off by the list's limit on a busy router.
- Fixed: a flow past about 2 billion packets sorted to the bottom of that list (BusyBox sort on OpenWrt reads the number as a 32-bit int).

## LuCI app 1.3.8.5

- Changed: System → Maintenance → Update now shows a spinner, as LuCI's own busy buttons do, from the click until the progress bar reaches 100%, also on a page opened while an update runs; it cannot be pressed meanwhile.

## LuCI app 1.3.8.4

- Changed: Setup → Queue → CAKE → Advanced → Multi-queue (cake_mq) shows only where the WAN device has more than one TX and RX queue; not on PPPoE (`pppoe-wan` has one of each).

## Shaper 3.2.0.6

- Changed: multi-queue CAKE (`cake.mq`) applies only when the WAN device has more than one TX and RX queue (a NIC with RSS). On PPPoE, a switch port or a one-queue NIC the shaper keeps plain CAKE, the download's IFB included, even with `cake.mq` set. Auto Setup suggests it only there, and no longer suggests packet steering on all CPUs for it.

## LuCI app 1.3.8.3 and the installer

- Fixed: a router installed from `dev` could have its updates stuck on `main`. The branch updates follow (`update_branch`) and the branch installed were kept apart: Reset to defaults or a settings file without the branch cleared the first, and an install from SSH with `-b dev` never set it, so System → Maintenance checked and offered `main` while the banner said `dev`. Unset now means the branch installed, and `QoS-Ex-install.sh -b main` or `-b dev` also sets the branch updates follow.
- Fixed: System → Maintenance turned Update now back on as soon as an update had started, so it could be pressed again. It, Check now and the update branch now stay greyed out until the update ends, also on a page opened meanwhile, after a reload or a new login, or while `QoS-Ex-install.sh` runs from SSH; that page follows the update to its end.

## LuCI app 1.3.8.2

- Changed: Setup → Queue → LAN device lists the devices by name only; the note under it shows the device your LAN is on, as WAN interface does since 1.3.8.1 (the list marked it *your LAN*). With no LAN device found, the note says what an empty field does.

## LuCI app 1.3.8.1

- Changed: Setup → Line → WAN interface lists the devices by name only; the note under it shows the device your internet line is on now (it was a fixed example, and the list marked the line).

## LuCI app 1.3.8.0

- New: Setup → Queue → CAKE → Advanced → Multi-queue (cake_mq), shown where the router has it (OpenWrt 25.12 and later). Live → Stats and the Overview add the per-queue CAKEs up, so the tins show the whole line; Auto Setup lists the multi-queue row.

## Shaper 3.2.0.5

- New: `cake.mq` (default `no`): multi-queue CAKE (cake_mq), one CAKE per TX queue sharing one config, the rate split between the queues that are busy, so the shaping spreads over the cores (OpenWrt 25.12 and later; elsewhere plain CAKE goes on and the log says so). The download's IFB gets a TX queue per CPU (at most 16), each fed by its own CPU; the WAN and the LAN device use their NIC's queues and stay plain CAKE with one (`pppoe-wan`). Device fairness and the tins then hold within each queue.
- Changed: Auto Setup keeps CAKE and suggests multi-queue CAKE when the speed test finds the CPU is the limit on a multi-core router that has cake_mq (HTB as before elsewhere), and packet steering on all CPUs when the download comes in on one queue (PPPoE, a one-queue port).

## LuCI app 1.3.7.9

- Changed: System → Status shows the name of a tool that shares the conntrack mark as plain text, like every other value the router reports.

## Ping Filter 2.0.9.1

- Fixed: for a few seconds after a Save, the Ping Filter pages could show the settings from before it. Between scans the daemon wrote its status report before reading the saved config, and that report looked newer than the save. It now writes none until it has read the config; the pages ask the Ping Filter directly meanwhile.

## Shaper 3.2.0.4

- Fixed: with the download shaped on the LAN device, a clsact that another tool had put on that device with filters only on its ingress side was taken for QoS-Ex's own, and start and stop deleted it. QoS-Ex filters only egress there, so an ingress filter now marks the clsact as another tool's: QoS-Ex refuses to start and says why, as it does for one with filters on egress.

## LuCI app 1.3.7.8

- Changed: Setup → Queue → CAKE → Advanced: the help for NAT lookup, ingress says it applies to the IFB only. Since shaper 3.2.0.1 the download on the LAN device never looks up NAT.

## Shaper 3.2.0.3

- Fixed: `qos-ex.sh status` showed `nat_ingress=yes` for CAKE with the download on the LAN device, which does not look up NAT; it now reads `no (LAN device)`.
- Fixed: when the ifb module was not loaded yet, loading it also made ifb0 and ifb1, which nothing used. OpenWrt's modprobe ignores module options, so the `numifbs` QoS-Ex passed never reached the module; it is now loaded as OpenWrt loads it (`insmod ifb numifbs=0`).
- Changed: SETUP and the LuCI guide advise Headroom 90% or lower with HFSC or HTB: they charge a burst of merged packets (GRO) as one, 3–5% under the wire for bulk TCP.

## Shaper 3.2.0.2

- Changed: the Advanced rule set no longer reports its connection-mark changes to conntrack's event listeners. Advanced classes each packet, so a busy connection's mark can change on most of its packets, and every change was sent to each listener, the Ping Filter's handshake timer among them. The timer still gets new connections, first replies and closes.

## Shaper 3.2.0.1

- Fixed: CAKE on the LAN device (Download shaped on: LAN device) no longer looks up NAT. There the lookup returned the router's WAN address for every download, so all LAN devices counted as one and CAKE shared the download per connection, not per device. The IFB keeps the lookup (`nat_ingress`).
- Changed: HFSC and HTB with `wash_down` on (the default): the WAN's download filter copies only the mark the classes go by. The DSCP it also restored was cleared by the firewall straight after, so that header rewrite on every download packet is gone; classes and washing are unchanged.

## LuCI app 1.3.7.7 and the installer

- Changed: version numbers are listed by module wherever they show: the LuCI app (1.x) first, then the Ping Filter (2.x), the shaper (3.x) last. The banner reads `main · app v1.3.7.7 · PF v2.0.9.0 · shaper v3.2.0.0`; System → Maintenance → Versions & updates, the Update confirm, the update log's closing line and the release manifest's first line follow the same order.
- Changed: Auto Setup shows one step at a time. Devices appears once the line speed is known (a speed test, or speeds typed in), and Settings to apply once you press Next under Devices. A step fades in and scrolls into view as it appears; done steps stay, ticked green, so you can go back and change them.

## Shaper 3.2.0.0

- Changed: the debug report lists the versions LuCI app, Ping Filter, shaper. (3.1.9.9 rolls over to 3.2.0.0.)

## LuCI app 1.3.7.6

- Changed: Auto Setup has its own tab, the first one, shown only until QoS-Ex is set up: after a fresh install, a Reset to defaults or System → Maintenance → Run Auto Setup. Network → QoS-Ex opens on it. Apply, Finish, Manual setup or a restored settings file hide it again, and Run Auto Setup brings it back. The Overview's setup card is now one line that links to the tab.
- Changed: the Auto Setup page has the app's look: router tiles (model and how it rates the router, CPU, memory, WAN port), the line speed on the Overview's gauges while the test runs and after, numbered step cards that show what is done and what is next, and the suggested settings grouped as Line, Queue and rules, This router and Ping Filter. A click anywhere on a row ticks or unticks it.
- New: Auto Setup grades the bufferbloat the speed test measured with shaping off (A+ to F, from how far the ping rose under load).
- New: Auto Setup's devices step is the Setup device table: each device Normal, Gaming or Low priority. Low-priority devices can now be set there too. When no gaming device is set yet, consoles (PlayStation, Xbox, Nintendo, Steam Deck) are set to Gaming from the names they give the network; you see them before you apply.
- Changed: when Auto Setup was set up before, Manual setup reads Keep current settings and leaves everything as it is.
- Changed: a speed test that is running, or one under an hour old, opens the steps on it, so a reload or Run Auto Setup does not need a new test.
- Changed: faster. The page runs the backend once to open, not twice (the router check comes with the suggestions), and nothing on it polls the router while the speed test runs, so a small router gives the test all of its CPU. The Auto Setup code left the shared module every page loads. The Overview asks for the hardware fingerprint once per login, not on every visit.
- Fixed: a failed Apply shows its reason beside the button as well as at the top of the page.
- Fixed: the banner named the page Overview when Network → QoS-Ex opened another tab first; it now names the page LuCI opened.

## Shaper 3.1.9.9

- Changed: `autosetup` keeps LuCI's menu in step: a change to `autosetup.done` (apply, skip, again, Reset to defaults, a fresh config) drops LuCI's saved menu, so the Auto Setup tab shows or goes at the next page load. Restoring a settings file does the same.
- New: `autosetup apply low=<MAC>` sets the low-priority devices, as `dev=<MAC>` sets the gaming ones; `dev=` or `low=` alone empties that list. A device is never in both: Gaming wins. A device list that did not change no longer restarts the shaper.
- New: `autosetup suggest [DOWN UP] -p` puts the router check's lines first, so LuCI gets both from one run.
- Changed: Apply and Manual setup run the full config top-up only when Reset to defaults left settings blank, not every time.
- Fixed: turning packet steering on from Auto Setup marked the setup done and hid the rest of it.

## LuCI app 1.3.7.5

- Changed: Setup → Queue → Gaming class: the leaf queue and Max delay moved to Advanced, with the leaf queue first. General keeps the gaming rate, its floor and RT burst.
- Changed: Live → Flows no longer opens a game stream's detail by itself; click a flow to see it.

## Shaper 3.1.9.8

- Fixed: with the download shaped on the LAN device under HFSC or HTB, Wash DSCP Down did not wash. The LAN device's filter put QoS-Ex's mark back into each packet after the firewall's wash, so your devices received EF and the other marks. With the wash on it now copies the mark for the classes only and leaves the packet washed. CAKE and the IFB were not affected.

## LuCI app 1.3.7.4

- Changed: Setup → Queue → LAN device starts with the device your `lan` interface is on and marks it *your LAN* in the list, as the WAN interface list marks the internet line.
- Fixed: Setup's WAN interface list never marked the live line *internet line*: Setup read the poll snapshot, which does not carry it. It now reads the full status report once when the page opens.

## Shaper 3.1.9.7

- Changed: the status report names the LAN device it finds (`lan_live`), for Setup's LAN device field. A code comment on the LAN device's download filter now says the router's own traffic to the LAN is shaped too.

## LuCI app 1.3.7.3

- Changed: the Download shaped on help says that with the LAN device, the router's own traffic to the LAN is shaped too.

## LuCI app 1.3.7.2

- Changed: every option's help is one short line (64 characters at most), and the notes, tooltips and confirm prompts on every page are cut to what you need to know.
- Changed: Setup's tabs are now Line · Devices & Ports · Queue · Rules. Line holds only the connection (WAN, speeds, headroom, link layer, overhead and MPU, which moved from Tweaks). Download shaped on, the LAN device and the Tweaks (ACK filter, ratio cap, MSS clamp) moved to Queue.
- Changed: the Live pages refresh option is gone from Setup. Auto Setup still sets 2 s on a small router, and Stats and Flows each keep their own selector.
- Fixed: the Overhead help named Ethernet 18; it now matches Auto Setup (Ethernet 38, plus 8 for PPPoE).

## Shaper 3.1.9.6

- Changed: a missing LAN device for `download_on lan` points to Setup → Queue, where the option now is.

## Shaper 3.1.9.5

- New: `download_on lan` shapes the download on the LAN device as the traffic leaves it, instead of on an IFB device off the WAN. There is no IFB, so a download packet skips the redirect and the IFB's second pass; it still meets one shaping queue. Only traffic leaving through that LAN device is shaped: a guest or IoT network on another device is not, nor internet traffic to the router itself, while the router's own traffic to the LAN and traffic routed in from another network are shaped at the download rate. Setup → Line → Download shaped on; the default stays the IFB. Auto Setup suggests it on a low-spec router that has one LAN device.
- Changed: Auto Setup's lowest spec is now HTB with sfq leaves and the Simple (SGS) rule set, also when the speed test found the router's CPU at its limit (it suggested HFSC and Adaptive). `rules_low` is `simple` and `rules_mid` `adaptive`; a config still holding the old defaults is moved.
- New: `live_refresh` (Setup → Line → Live pages refresh) is the Stats and Flows poll rate a browser starts with; Auto Setup puts 2 s on a low-spec router. A pick made on the page still wins in that browser.
- Changed: the Live pages' counters no longer run the shaper script every second. Install slices the counters code into `/usr/lib/qos-ex/live.sh`, and the web app's backend reads it with the values the start recorded.

## Ping Filter 2.0.9.0

- Changed: the two firewall chains start with a gate: a packet with no gaming device at either end, and in the verdict chain anything that is not UDP, leaves on the first rule instead of failing a set lookup in every rule. Every forwarded packet passes these chains; game traffic is judged exactly as before.
- Changed: while a Ping Filter page is open, the daemon writes the status report once a loop and the page reads that file; the script is no longer run for every poll.
- Changed: the scan writes the rows of a pass to the server list in one go instead of one rewrite per server.

## LuCI app 1.3.7.1

- New: Setup → Line gains Download shaped on (IFB off the WAN, or the LAN device), the LAN device, and the Live pages refresh default. Status and the Overview name the download hook for either placement.
- Changed: the Live pages start at the router's refresh default when this browser has not picked one.

## Ping Filter 2.0.8.9

- Fixed: Turning the Ping Filter on after a reboot it had been off for ran it on an empty server list, and the next save to flash overwrote the saved servers with that empty list. The saved list is now restored whenever the Ping Filter is turned on or reloaded, not only at service start.
- Fixed: When the firewall was restarted during a game, the Ping Filter rebuilt its rules with the server being played held until every server had been re-graded, which could freeze the game for several seconds. The server being played is let through again the moment the rules are back.
- Fixed: A backslash in a location service's country or city name is dropped with the other unsafe characters, so it can no longer alter a saved /24 memory row.

## Shaper 3.1.9.4

- Fixed: Stopping and starting the firewall (`/etc/init.d/firewall stop`, then `start`) deleted QoS-Ex's classification rules. The queues stayed, but games no longer went to the Gaming class until QoS-Ex was restarted. The firewall now loads the rules again each time it starts. Every firewall reload (a firewall change, or an interface coming up) also loads them again, which clears the per-connection speed checks; a busy download is back in its class within seconds.
- Fixed: When the WAN came up again, QoS-Ex could take the Ping Filter's firewall table for its own and skip the restart that puts its rules back.
- Changed: The speed test only takes an `http://` or `https://` address for `autosetup.test_url` and a host name or address for `autosetup.ping_host`; anything else uses the default.

## LuCI app 1.3.7.0

- Fixed: Maintenance → Disable flow offloading said it had worked when it failed.
- Fixed: Setup → Devices & Ports said a new Gaming device is watched by the Ping Filter. It is not: tick it on Ping Filter → Settings → Devices.
- Changed: System → Logs reads the Ping Filter nft error file directly instead of running the Ping Filter script every few seconds.
- Changed: The QoS-Ex box on Status → Overview asks the Ping Filter for its state every 30 s while it is off, not every 5 s.
- Changed: The update log is read from /var/log only; the old /tmp copy is no longer read.

## Ping Filter 2.0.8.8

- Changed: New servers are located much faster. Their addresses go to GeoJS together, up to 50 in one HTTPS request, instead of one lookup per server two seconds apart, so a burst of servers shows on the Map at once (ten servers: about 20 s before, under a second now). A server GeoJS can only place in its country is still looked up on its own, so no city is lost.
- Changed: The game company tag can now come from GeoJS's answer too.
- Fixed: A lookup service that answered "unknown" for one address was treated as down: it was skipped for a minute, and when it was the last one asked, every lookup paused for a minute. Only a service that does not answer is rested now.

## Shaper 3.1.9.3, Ping Filter 2.0.8.7, LuCI app 1.3.6.9

- Removed: Saved setups — the Dashboard row (Load, Save as, Delete) and the `pingfilter game save|load|delete|list` command. Existing saved setups in `/etc/qos-ex/games` are deleted, and the `pingfilter.game` setting is removed on upgrade. Your current Ping Filter settings are unchanged.

## Ping Filter 2.0.8.6, LuCI app 1.3.6.8

- Changed: A server's first ping more than 25% over its estimate (from its /24, its area or its distance) is no longer taken on its own: the next probe, seconds later, checks it, and the lower of the two is used. A ping taken on a busy line or a slowed echo used to stick, because a figure only comes down. With a ping limit set, a server whose first ping reads over the limit is now blocked after that second look rather than at once. The in-play ping, the game's first exchange and Re-check cache are not affected.
- Added: A ping figure older than three days is measured again while nothing is being played, two servers at a time, so a route that got slower shows instead of the old low figure. A block it causes waits until the game on that server is over, as other automatic re-grades do.
- Changed: The Servers list marks an estimated ping with "~" (hover for where it came from), so a guess never reads as a measurement.

## Ping Filter 2.0.8.5, LuCI app 1.3.6.7

- Fixed: In Watch only and pure distance mode, a server's first reply timed on one connect could become its ping — on a server that ignores echo that reading can be seconds of server think time, and it stuck as the figure, taught the /24 memory and dragged the grade down. With no ping limit to anchor on, such a reading is no longer taken while it is over the server's estimate; it still lands once a second connect confirms it, and a lower reading is always taken.
- Fixed: In Watch only, grading by play never corrected such a figure; the played median now replaces a one-connect handshake figure.
- Added: A Distance column on the Servers list and the Now playing card — km from your home location — and a "Nearest" sort on the Servers page.

## Shaper 3.1.9.2

- Fixed: `autosetup apply dev=<MAC>` now takes a MAC typed in capitals (LuCI always sent lower case).
- Changed: The `autosetup` command help names `dev=<mac>`.

## LuCI app 1.3.6.6

- Changed: The Auto Setup `suggest` call moved from the read to the write ACL group: it saves the file Apply reads, so a read-only LuCI user could change what an administrator's Apply then wrote.

## LuCI app 1.3.6.5

- Fixed: The gauge figure bled into the arc once the rate read in Gbit/s; it is smaller now and stays inside.

## LuCI app 1.3.6.4

- Fixed: The banner's Shaping and Ping Filter pills read "[object HTMLElement]" since 1.3.6.3.
- Fixed: The Overview gauges painted a stray dot at the arc's right end near 0%; an empty gauge no longer leaves a dot at its start either.
- Changed: The Now playing card's link goes to the Map; the controls card keeps the Dashboard link.

## LuCI app 1.3.6.3

- Changed: A visual polish across the app — glass card backgrounds, a glow on active elements on dark themes (light themes keep the clean flat look), fixed-width digits on every headline figure, and the banner drawn as a status hero. Colours, layout and every setting are unchanged, and the look still follows the LuCI theme's own light or dark.
- Changed: The Overview's Download and Upload tiles are gauges: the arc is the rate's share of the shaped rate.
- Added: Class cards on Live → Stats: rate now, drops and backlog per class (per tin under CAKE), in the class's chart colour; a dropping class gets a red edge, and hovering a card picks it out on the charts.
- Nothing new is polled: the gauges and cards draw from the calls the pages already make, and reduced-motion settings are respected.

## Shaper 3.1.9.1, Ping Filter 2.0.8.4, LuCI app 1.3.6.2

- Removed: Game names from DNS lookups: the built-in games, Your games, Name this game, self-named "New game" entries and the `game_name` / `game_known` commands. The DNS tap no longer runs.
- Changed: A server on a game company's own network still shows the company, on the Dashboard, Map, Servers page and in the play history.
- Fixed: That company name never showed on a router: its lower-casing did not work with OpenWrt's BusyBox.
- Changed: Matchmaking shows for game UDP only, not for a game's name looked up.
- Removed: The `game_names` and `game_dns` settings; an update removes them.
- Removed: The Add a game issue form.

## Ping Filter 2.0.8.3

- Fixed: Unnamed play could be named after a host name every game of one publisher looks up (EA's `tnt-ea`); those and labels with 4+ digits are now refused, as when you name a game.
- Fixed: Every Ping Filter stop or restart logged a "Terminated" error in the system log.

## Shaper 3.1.9.0, LuCI app 1.3.6.1

- Changed: Reset to defaults leaves the settings Auto Setup picks blank (WAN, speeds, queue, rule set, overhead, link layer, Ping Filter Lite); Manual setup fills in the defaults.
- Added: `qos-ex.sh autosetup blank`.
- Changed: Ping Filter setup card: two steps (tick gaming devices, pin home on the Map), then on in Watch only; the mode is picked on the Dashboard.
- Changed: Watched devices are no longer ticked for you by Setup or Auto Setup.
- Fixed: A failed speed test showed its error banner several times; the reason now shows once, in the card.
- Changed: Live → Stats and Flows refresh every 1 s to start; the refresh you pick is kept in this browser.

## Shaper 3.1.8.9, LuCI app 1.3.6.0

- Changed: Auto Setup sets up the shaper only, in three steps; the Ping Filter is set up on its own.
- Removed: The Ping Filter choice in Auto Setup (`autosetup apply pf=`).
- Changed: Auto Setup's Ping Filter sizing rows are marked "if you use it".
- Added: A link to the Ping Filter under the Auto Setup card.
- Added: On / Off written inside the on / off switches.

## LuCI app 1.3.5.9

- Changed: Auto Setup Apply and Restore show a progress bar that ends at 100% (Complete) once the shaper runs, then reload.
- Changed: Auto Setup picks gaming devices from a drop-down.
- Changed: Auto Setup card in four numbered steps; settings that stay are folded away.
- Changed: The settings backup is saved as `QoS-Ex Settings.cfg` (older `.qosex` and `.txt` backups still restore).

## Shaper 3.1.8.8, Ping Filter 2.0.8.2, LuCI app 1.3.5.8

- Added: Auto Setup asks for gaming devices and the Ping Filter, rates the router (low / mid / high) and picks the rule set from it.
- Added: Restore a settings file on the first-run card.
- Changed: Settings backups are `.qosex` files with a checksum; edited or foreign files are refused.
- Added: Ping Filter Lite (`pingfilter.lite`) for small routers.
- Fixed: Matchmaking shows only for game UDP or a game lookup, not downloads or the web.
- Added: Seven more built-in games, company names from the server's network, and self-named "New game" entries.

## LuCI app 1.3.5.7

- Fixed: Update now ends at 100% (Update complete) before the page reloads or logs out.
- Changed: The speed test bar ends at 100% before the results show.

## Shaper 3.1.8.7, Ping Filter 2.0.8.1, LuCI app 1.3.5.6

- Fixed: Adaptive: a download split over many connections goes to Bulk (share measured per device).
- Added: Overview: a green / red dot shows whether each gaming device is online.
- Changed: Restore from file opens the Overview when done.
- Fixed: Ping Filter: no more `can't open /proc/<pid>/cmdline` lines in the system log.

## LuCI app 1.3.5.5

- Changed: Ignore UDP ports help suggests adding voice chat ports.

## Ping Filter 2.0.8.0, LuCI app 1.3.5.3, shaper 3.1.8.6

- Changed: Ping Catch adds servers outside the radius; inside the radius is always allowed.
- Changed: New servers pass their first packets (`first_pkts`), then are held until graded.
- Changed: Ping Filter's own re-grades never cut the server being played.
- Changed: Dashboard and Map controls apply at once, with a warning during a match.
- Changed: A reading only lowers a server's figure.
- Added: Servers are graded on the ping measured during play.
- Changed: Ping Catch groups are counted from readings, by majority.
- Changed: Distance with lookups off judges an unlocated server by its ping against the radius.
- Changed: Switching modes keeps both the ping limit and Ping Catch.
- Changed: Mode cards (Ping, Distance, Watch only) replace the five presets and Custom.
- Added: Setup card on the Ping Filter pages while it is off.
- Changed: A device set to Gaming is watched by Ping Filter too.
- Added: Map: Pin home here, and a Ping Catch slider.
- Changed: Settings split into Devices, Mode, Home and Games sections.
- Changed: Matchmaking looks stuck raises Ping Catch when it is set.
- Changed: Renamed: Always allow / Always block, Watched devices, Saved setups, Ping limit.
- Added: Built-in game names for Call of Duty, Valorant and Rocket League.
- Added: Name this game on the Dashboard; learns a game after two named matches.
- Changed: Extra games is now Your games.
- Changed: Game names need Grade from gameplay.
- Added: `pingfilter game_name` and `game_known` commands.
- Removed: `game_suggest` and Suggested games.
- Changed: The Add a game issue form asks for the Your games line.
- Added: `tests/verdict.sh` checks Ping Filter verdicts.
- Removed: The New servers setting (`unknown_ping`, `unknown_distance`, `unknown_policy`).

## Shaper 3.1.8.5

- Changed: The message for an `ifb-<wan>` QoS-Ex did not create names "another shaper, such as qosify".

## Shaper 3.1.8.4, LuCI app 1.3.5.2

- Changed: CAKE Host isolation and Ingress mode are on by default (new installs).
- Changed: Setup → Devices & Ports list fills the card.
- Changed: Live → Flows opens a gaming device with only its game stream's detail.

## LuCI app 1.3.5.1

- Changed: Reset to defaults opens the Overview.
- Changed: Update now shows a progress bar instead of the installer's output.
- Changed: Uninstall ends at the OpenWrt login page.

## Shaper 3.1.8.3, LuCI app 1.3.5.0

- Changed: Auto Setup lives on the Overview only.
- Changed: The setup card offers Auto Setup or Manual setup.
- Changed: Queue and rule set are always shown in the suggestions, with the reason.
- Changed: Applying the settings turns the shaper on.
- Added: `qos-ex.sh autosetup again`.

## Shaper 3.1.8.2

- Fixed: The speed test's download failed after a few tests (HTTP 429).
- Changed: The speed test uses IPv4 only.

## Shaper 3.1.8.1

- Fixed: A failed speed test says why.

## Shaper 3.1.8.0, LuCI app 1.3.4.9

- Fixed: The speed test could measure the wrong device.
- Changed: First install runs Auto Setup in the Overview's Get started card.
- Added: Speed test progress bar.

## Shaper 3.1.7.9, LuCI app 1.3.4.8

- Added: Auto Setup in the web app.
- Added: A fresh install offers Auto setup or Set up by hand.
- Added: Needs attention warns when settings came from Auto Setup on other hardware.
- Fixed: Suggested line speeds are the line's own speed (Headroom applied once).
- Fixed: The busiest-core figure when the test ends in its first 2 s.
- Added: `qos-ex.sh autosetup hw` and `autosetup skip`.

## Shaper 3.1.7.8

- Added: Auto Setup over SSH: `qos-ex.sh autosetup probe | speedtest | suggest | apply | undo`.
- Added: `autosetup` settings section.

## Shaper 3.1.7.7, Ping Filter 2.0.7.9, LuCI app 1.3.4.7

- Changed: Location lookups use HTTPS services first.
- Fixed: `geoip_lookup` reads `1` / `on` / `true` as on.
- Fixed: Overhead and MPU accept 0–256.
- Changed: The debug report hides `geoip_api`.
- Fixed: Copy for forum, Save .txt and Export settings need write access.
- Fixed: Import settings and Reset to defaults drop staged `uci` changes.
- Changed: Uninstall also removes the web app's state cache and update files.

## Ping Filter 2.0.7.8, LuCI app 1.3.4.6

- Added: Suggested games, from the names looked up before each match.
- Added: `game_suggest` command.

## Ping Filter 2.0.7.7

- Fixed: No blocking without the daemon.
- Fixed: `qos-ex-pf.sh uninstall` takes the daemon out of procd first.
- Changed: Stopping is quicker.
- Fixed: The jitter tap no longer holds the probe pipe open.

## Ping Filter 2.0.7.6, LuCI app 1.3.4.5, shaper 3.1.7.6

- Added: Game names: Ping Filter names the game a server is played for.
- Added: Game names and Extra games settings.
- Changed: New game keeps names; Clear cache and forget remove them.
- Changed: `pingfilter status` shows each device's last game.
- Fixed: Changing game settings no longer re-grades every server.
- Added: Add a game issue form.

## Ping Filter 2.0.7.5, LuCI app 1.3.4.4

- Changed: Ping Catch goes by the area first.
- Changed: A handshake time does not block a server its area lets in.
- Changed: Blocks wait until the game on the server is over.
- Changed: The /24 sets count a /24 as over only from ping readings.

## Ping Filter 2.0.7.4, LuCI app 1.3.4.3, shaper 3.1.7.5

- Removed: Settings that did the same job (fewer Ping Filter options).
- Changed: Discovery is ping mode with no limit.
- Changed: One verdict path for every reading.
- Fixed: Command-line help no longer says pinned servers are pinged in a game.

## Ping Filter 2.0.7.3, LuCI app 1.3.4.2

- Added: Ping Catch learns blocks of servers (/24).
- Changed: Faster verdicts; a ping burst ends at 2 s.
- Changed: Location lookups run in the background.
- Changed: Servers not seen for 20 s cost nothing per scan.
- Changed: Unlocatable servers are judged when no lookup can come.
- Changed: The in-play ping backs off after 3 silent bursts.
- Removed: Pinging pinned servers every 30 s during a match.
- Changed: Fewer processes per server while playing.
- Changed: A ping burst is read as its median.

## LuCI app 1.3.4.1, shaper 3.1.7.4

- Added: The banner names the installed branch.

## LuCI app 1.3.4.0 and the installer

- Added: Switch between the main and dev branches.
- Changed: `QoS-Ex-install.sh` without `-b` follows the update branch.

## Ping Filter 2.0.7.2

- Fixed: Forget removes a server everywhere.
- Fixed: Estimates follow the readings around a server.
- Fixed: No block mid-match for a server let in before it had a ping.
- Changed: New servers are held until graded in ping mode too.
- Added: Five location services, and a warning when none answers.

## Shaper 3.1.7.3

- Added: `pingfilter.area_adjust_pct` (default 5).
- Added: Status reports `pf_geo_down` when no location service answers.

## LuCI app 1.3.3.9

- Changed: New servers (ping mode) defaults to Hold until graded.
- Added: Status and the Dashboard warn when no location service answers.
- Added: The Map falls back to CARTO tiles when OpenStreetMap fails.

## Shaper 3.1.7.2

- Fixed: The debug report removes a hostname with an underscore.

## LuCI app 1.3.3.8

- Fixed: Stats no longer polls from a hidden browser tab.
- Added: Setting home on the Map is logged.
- Fixed: An old `…/qos-ex/status` link opens System → Status.
- Fixed: The stylesheet no longer touches other LuCI pages.
- Removed: The unused `tc` RPC method.

## Shaper 3.1.7.1

- Fixed: QoS-Ex no longer breaks another shaper's download path.
- Fixed: Live charts no longer freeze after 2 GB.
- Fixed: A mistyped IPv6 device address no longer stops classification.
- Fixed: A remote sender can no longer fill the Gaming class.
- Fixed: Download classes on big-endian routers (ath79, lantiq).
- Fixed: ACK thinning thins pure ACKs only.
- Fixed: Simple keeps one class per connection.
- Fixed: Adaptive bulk ports match as the source port too.
- Changed: Advanced: busy non-web TCP goes to Default.
- Fixed: HFSC on slow uploads stays inside the shaped rate.
- Added: Link layer ATM (`settings.linklayer`) for ADSL.
- Fixed: Reload after a stop starts through the service.
- Changed: A switch's CPU port is refused as the WAN.
- Fixed: An opkg upgrade of the package no longer uninstalls QoS-Ex first.
- Fixed: Service, ifup and upgrade scripts are written whole or not at all.
- Fixed: Yes / no switches accept `1`, `true`, `on` in any case.

## Ping Filter 2.0.7.1

- Fixed: A mistyped IPv6 gaming address no longer fails the Ping Filter table.
- Fixed: Single-value device options set with `uci set` are read.
- Fixed: Byte counters past 2 GB no longer print negative.
- Changed: Messages name the current pages.

## LuCI app 1.3.3.7

- Changed: Device addresses are checked as the shaper checks them.
- Fixed: The WAN field can no longer be cleared.
- Fixed: Stats with only the download shaped, and a stopped shaper shown as running.
- Added: Link layer field on Setup → Line.
- Changed: Reset to defaults and Restore switch QoS-Ex on or off as the settings say.
- Fixed: The rate preview matches the shaper (ACK auto, headroom).
- Changed: Maintenance says what the debug report removes.
- Fixed: Flows explains a busy Adaptive UDP flow as Low.

## LuCI app 1.3.3.6

- Changed: Servers with no country yet go to the bottom of the list.

## LuCI app 1.3.3.5

- Changed: Ping Filter → Servers lists servers by country.

## Installer · LuCI app 1.3.3.4

- Fixed: A failed update no longer leaves QoS-Ex off.
- Fixed: Closing SSH mid-update no longer stops it.
- Changed: One update at a time.
- Fixed: A full flash no longer leaves a mixed set of files in `/root`.
- Changed: `sh /root/QoS-Ex-install.sh` runs the newest installer.
- Changed: The token is typed hidden.
- Fixed: A missing manifest is told apart from a failed download.

## Ping Filter 2.0.7.0

- Fixed: A server allowed on an estimate is no longer cut mid-match when it ignores ping.
- Fixed: No long freezes when location services cannot be reached.
- Fixed: Locks cannot be taken over.
- Fixed: `max_servers` is a real limit.
- Changed: A block drops game (UDP) traffic only.
- Added: Flow offloading is reported.
- Changed: A custom `geoip_api` is the only service asked.
- Changed: List and ignore-port changes apply without a reload.
- Changed: Run scan now and New game return at once.

## Shaper 3.1.7.0

- Fixed: A whitelist or blacklist change no longer re-grades every server on Save & Apply.

## LuCI app 1.3.3.3

- Fixed: The Status page box shows when an update is out.

## Shaper 3.1.6.9

- Changed: QoS-Ex will not start while SQM shapes the same WAN.
- Fixed: Advanced settings read leading zeros as decimal.
- Fixed: Advanced keeps other firewall marks.
- Fixed: No more stuck lock.
- Fixed: A reload during a start is no longer lost.
- Fixed: A bad CAKE extra option no longer leaves the line unshaped.
- Fixed: The IFB name stays the same when `cksum` is installed later.
- Changed: The debug report hides CGNAT addresses.
- Changed: Removing the `qos-ex` package removes QoS-Ex (settings kept).

## LuCI app 1.3.3.2

- Changed: Overview lists every gaming device.
- Changed: Ping Filter on / off reads the same everywhere.
- Fixed: Maintenance shows the installed versions as they are now.
- Fixed: A failed rpcd reload is reported as a failed install.
- Fixed: Rates shown before saving match the shaper.
- Fixed: A latitude or longitude of 0 is accepted.

## Shaper 3.1.6.8

- Fixed: Uninstall no longer leaves LuCI on a 404.

## Shaper 3.1.6.7 · LuCI app 1.3.3.1

- Changed: Adaptive is the default rule set for new installs.
- Changed: Advanced rewritten as a per-packet split, rates per connection and direction.
- Removed: Bulk and video-call port lists from Advanced.
- Added: `advanced` options `web_pps`, `tcp_pps`, `udp_pps`, `small_len`, `max_len`, `reset_pm`.
- Changed: The gaming-class floor from `udp_fast_pps` applies under Adaptive only.
- Changed: Setup → Rules shows the new Advanced options.

## LuCI app 1.3.3.0

- Changed: The Graded servers box fits its rows, then scrolls.

## LuCI app 1.3.2.9

- Changed: Dashboard figure tiles sit above the mode cards.

## LuCI app 1.3.2.8

- Changed: Graded servers is open by default.
- Removed: The Recently played card (its matches are in the ladder).

## LuCI app 1.3.2.7

- Changed: The Shaper section links to Setup.

## LuCI app 1.3.2.6

- Changed: Dashboard tiles link to their pages.
- Changed: Now playing shows the server as its Servers row.
- Added: Recently played card.

## Shaper 3.1.6.6

- Changed: The install code moved to `lib/install.sh`, checked against the release manifest.

## Shaper 3.1.6.5 · Ping Filter 2.0.6.9

- Removed: Converting upgrades from before 3.1.0.
- Removed: Importing the old ping cache.

## Shaper 3.1.6.4 · Ping Filter 2.0.6.8

- Changed: Code comments trimmed.

## Repo: test harness

- Added: `tests/run.sh` renders and checks generated rule sets, tc plans and configs.

## Shaper 3.1.6.3

- Added: mwan3 / pbr warning.
- Fixed: Leading zeros are read as decimal.
- Changed: Help lists `enable`, `disable` and the Adaptive rule set.

## LuCI app 1.3.2.5

- Fixed: Start, stop and restart no longer time out.
- Added: Status warns when mwan3 or pbr is enabled.
- Added: The Dashboard warns when a watched device has a public IPv6 address.

## Docs

- Fixed: ImmortalWrt is no longer named as supported.

## LuCI app 1.3.2.4

- Changed: Colours back to the old look.

## Ping Filter 2.0.6.7

- Changed: A server that ignores ping takes the average of measured servers in its area.
- Changed: Blocked after the match, not during it.
- Added: New servers setting per mode.
- Changed: Location retry 60 s for live servers.

## Shaper 3.1.6.2

- Added: Seeds `area_min`, `match_end_wait`, `geo_retry`, `unknown_ping`, `unknown_distance`.

## LuCI app 1.3.2.3

- Changed: Switches are green when on, red when off.
- Added: Overview: Now playing chart, Gaming traffic tile, Gaming flow and Gaming queue cards.
- Changed: Health & updates have their own card.
- Changed: Flows opens a gaming device with the page.
- Changed: New servers setting per mode.

## LuCI app 1.3.2.2

- Changed: The banner reads "QoS-Ex / Overview" from the menu.

## LuCI app 1.3.2.1

- Fixed: The Map could stop refreshing.
- Changed: Every page refreshes at LuCI's rate.
- Changed: Stats refresh selector moved into the tab bar.

## LuCI app 1.3.2.0

- Added: Status Health card.
- Changed: Logs show errors red and warnings amber.
- Changed: Save writes only what changed.
- Fixed: The ping limit field on Ping Filter → Settings.
- Changed: Maintenance points to System → Logs.

## LuCI app 1.3.1.9

- Changed: Shaper and Devices & Rules merged into one Setup page with four tabs.
- Added: Links open a Setup tab (`setup#line`, `#queue`, `#dev`, `#rules`).

## LuCI app 1.3.1.8

- Changed: One call per refresh on Stats and the Overview.
- Changed: Stats shows "The shaper is off" with the switch.

## LuCI app 1.3.1.7

- Changed: Ping Filter: one Servers page, Settings gains Advanced, one on / off switch.
- Added: Map popups show the grade.

## LuCI app 1.3.1.6

- Changed: Five tabs: Overview · Ping Filter · Live · Setup · System.
- Changed: New look with its own accent colour.
- Added: New Overview with Now playing.
- Changed: Faster polling on small routers.

## Shaper 3.1.6.1 · LuCI app 1.3.1.5

- Changed: Traffic Rules → Devices is one table.
- Added: The banner shows the Ping Filter version.

## Shaper 3.1.6.0 · Ping Filter 2.0.6.6 · LuCI app 1.3.1.4

- Changed: New-TCP window cap 250 → 80 Mbit (`advanced.tcp_new_cap_mbit`).
- Changed: Ping Filter saves to flash every hour (`persist_interval` 3600).
- Changed: A rate that is not a number leaves that direction unshaped.
- Changed: Defaults reviewed for `ping_var_pct`, `hs_rtt` and `auto_pin`.
- Changed: Connected rate accepts 1–1000 pps.

## Shaper 3.1.5.9 · LuCI app 1.3.1.3

- Changed: One set of nine DSCP marks for all three rule sets.
- Changed: Bulk → LE (was CS1); low-priority devices → CS1 (was AF11).
- Changed: HFSC / HTB: CS1 joins AF11 in Low (1:14), LE is Bulk (1:15).
- Changed: Adaptive slow TCP and QUIC → AF42 (was AF21).
- Changed: Adaptive re-decides live connections on update.

## Shaper 3.1.5.8 · Ping Filter 2.0.6.5 · LuCI app 1.3.1.2

- Removed: Ping Filter relative limit.

## Shaper 3.1.5.7 · LuCI app 1.3.1.1

- Fixed: Adaptive P2P detection works on OpenWrt.
- Changed: `adaptive.p2p_conns` replaced by `adaptive.p2p_rate`.

## Shaper 3.1.5.6 · LuCI app 1.3.1.0

- Added: Adaptive rule set: each connection decided once, kept in the conntrack mark.
- Added: `adaptive` section: `heavy_pct`, `heavy_secs`, `p2p_conns`, `vpn_ports`.
- Changed: Save & Apply re-decides live connections at once.

## Shaper 3.1.5.5 · LuCI app 1.3.0.9

- Changed: Advanced: slow TCP is AF42 again; fast new TCP is AF11, then Default.

## Shaper 3.1.5.4 · LuCI app 1.3.0.8

- Removed: The HTB ceil setting (one borrowing rule).

## Shaper 3.1.5.3 · LuCI app 1.3.0.7

- Fixed: A new config no longer seeds lists with an empty entry.
- Fixed: Filter for lists gaming devices the way Traffic Rules does.
- Changed: Country choices load before the form is drawn.

## Shaper 3.1.5.2 · LuCI app 1.3.0.6

- Changed: Status follows your settings and refreshes after Save & Apply.

## Shaper 3.1.5.1 · LuCI app 1.3.0.5

- Changed: sfq leaves (Auto): per-flow RED with ECN.
- Changed: Stats show sfq's RED marks as ECN marks.

## Shaper 3.1.5.0 · LuCI app 1.3.0.4

- Removed: References to other QoS tools from shaper comments.

## Shaper 3.1.4.9 · LuCI app 1.3.0.3

- Changed: HFSC / HTB: the Gaming class is inside the shaped rate again.

## Shaper 3.1.4.8 · LuCI app 1.3.0.2

- Changed: Auto fq_codel leaves tuned for 10 Mbit to 1 Gbit and above.

## Shaper 3.1.4.7 · LuCI app 1.3.0.1

- Changed: Auto fq_codel leaf memory sized as SimpleHFSCgamerscript.

## LuCI app 1.3.0.0

- Added: Traffic Rules → Thresholds shows the TCP windows.

## Shaper 3.1.4.6 · LuCI app 1.2.9.9

- Fixed: Advanced: new TCP starts in Low again.

## LuCI app 1.2.9.8

- Changed: Stats lists CAKE tins by priority.

## Shaper 3.1.4.5 · LuCI app 1.2.9.7

- Changed: The Gaming class is never smaller than the EF guard allows.

## LuCI app 1.2.9.6

- Changed: Ticked devices one per line.

## LuCI app 1.2.9.5

- Changed: Tidier Stats and Status.

## LuCI app 1.2.9.4

- Changed: One device list per class.
- Fixed: Ticking a device could untick it again.

## LuCI app 1.2.9.3

- Changed: Connections tab renamed Flows.

## Shaper 3.1.4.4 · LuCI app 1.2.9.2

- Removed: The SGS HFSC curves.

## Shaper 3.1.4.3 · LuCI app 1.2.9.1

- Changed: CAKE is the default queue type for new installs.

## Shaper 3.1.4.2 · LuCI app 1.2.9.0

- Added: Pick devices from a list.
- Added: Low-priority devices by MAC (`ips.lowprio_mac`).

## Shaper 3.1.4.1 · Ping Filter 2.0.6.4 · LuCI app 1.2.8.9

- Changed: Logs and runtime files moved out of `/tmp`.
- Fixed: A ping limit with a leading zero works.
- Fixed: Switching off without a reload no longer leaves servers held.
- Fixed: A played server is no longer dropped when the list refresh and scan overlap.
- Fixed: A re-check no longer drops a server the scan just let through.
- Changed: Less work while playing.
- Changed: List entries that are not an address are ignored.

## Shaper 3.1.4.0 · LuCI app 1.2.8.8

- Changed: The 3.1.3.9 Advanced change is reverted.

## Shaper 3.1.3.9 · LuCI app 1.2.8.7

- Changed: Advanced slow and heavy TCP are byte rates.

## Shaper 3.1.3.8

- Changed: Simple: ACK thinning for the WAN only.
- Fixed: Stop after a failed start.
- Changed: The ifup hook keeps its lock in `/var/lock`.

## Shaper 3.1.3.7 · LuCI app 1.2.8.6

- Changed: Gaming on top stops at 95% of the line.

## Shaper 3.1.3.6 · LuCI app 1.2.8.5

- Removed: The SGS rule set.
- Changed: HFSC SGS curves are an option of HFSC (`hfsc.curves`).

## Shaper 3.1.3.5

- Changed: The debug report shows only the settings that matter.

## LuCI app 1.2.8.4

- Fixed: Status page after an update.
- Fixed: The installer's closing line on an rpcd reload.
- Changed: The installer must be run by path, not piped.
- Changed: The map library is stored as a pair or not at all.

## Shaper 3.1.3.4

- Fixed: Uninstall removes the Status-page box under its new file name.

## Shaper 3.1.3.3

- Removed: Simple: sticky bulk sources.

## LuCI app 1.2.8.3

- Changed: Bulk sticky timeout shows under Advanced only.

## Shaper 3.1.3.2

- Changed: Sticky bulk sources are back.
- Changed: Fast UDP goes to AF11 unless gaming or already Low.
- Changed: Slow TCP is lifted to AF41.
- Changed: Gaming and low-priority IPs match as destination too.

## LuCI app 1.2.8.2

- Changed: The Simple switches describe their rules.

## Shaper 3.1.3.1

- Added: Rule set `sgs`: the SimpleHFSCgamerscript rules.

## LuCI app 1.2.8.1

- Added: SGS in the nft ruleset choice.
- Added: Copy for forum.

## Shaper 3.1.3.0

- Changed: Gaming (1:10) sits on top of the shaped rate under HFSC and HTB.
- Fixed: HTB: Gaming no longer borrows.
- Added: Queue type `hfsc_sgs`.

## LuCI app 1.2.8.0

- Added: HFSC SGS in the queue choice.

## LuCI app 1.2.7.9

- Fixed: The banner no longer drops out on a tab change.

## LuCI app 1.2.7.8

- Changed: One banner per page.

## LuCI app 1.2.7.7

- Changed: One layout on every page.
- Changed: Discovered Servers sorted by ping.
- Changed: Connections lists only connections with traffic.
- Added: Gaming devices added by MAC show wherever addresses do.
- Added: Report an issue link beside the debug report.

## Shaper 3.1.2.9

- Added: The debug report shows the LuCI app version.

## LuCI app 1.2.7.6

- Fixed: The Map and Discovered Servers show the same servers and counts.
- Fixed: Chip counts no longer change with the search box.
- Added: Servers not located yet are marked.
- Fixed: A change could take 30 s to show.

## Ping Filter 2.0.6.3

- Added: Every Ping Filter process has its own name in the process list.

## Documentation (no script change)

- Removed: `install.sh` from the repo.

## LuCI app 1.2.7.5

- Fixed: QoS-Ex stayed in the menu after an uninstall.
- Changed: Uninstall from Maintenance goes to LuCI's Status page.

## Shaper 3.1.2.8

- Changed: Uninstall logs LuCI out without the web app's installer.

## LuCI app 1.2.7.4

- Fixed: The Map went blank while the played server pulsed.
- Changed: The fetch-and-install script is now `QoS-Ex-install.sh`.

## Shaper 3.1.2.7

- Changed: `/root/QoS-Ex-install.sh` is kept over a firmware upgrade.

## LuCI app 1.2.7.3

- Changed: The web app is installed from plain files (`qos-ex-luci.tar.gz`).
- Fixed: A failed download can no longer leave the app half-installed.

## Shaper 3.1.2.6

- Changed: `qos-ex-luci.tar.gz` is kept over a firmware upgrade.

## LuCI app 1.2.7.2

- Fixed: Map dots and the home circle flashed while moving or zooming.

## LuCI app 1.2.7.1

- Fixed: The played server did not pulse with reduced motion on.
- Changed: Cleaner Map dots.

## LuCI app 1.2.7.0

- Changed: A device chosen by MAC shows its address, then the MAC.

## LuCI app 1.2.6.9

- Fixed: No pulse with reduced motion on.

## LuCI app 1.2.6.8

- Changed: The played server's dot pulses too.

## LuCI app 1.2.6.7

- Added: The server being played pulses on the Map.
- Removed: Dashboard Play history box (it repeated the ladder).

## Shaper 3.1.2.5

- Fixed: Install reported FAILED with full `tcpdump`.
- Fixed: An update no longer switches autostart back on.
- Fixed: A port with a leading zero was read as octal.
- Fixed: A very long number in a setting shaped at 1 kbit/s.
- Changed: The debug report hides MAC addresses.
- Fixed: Status no longer suggests the MSS clamp for an unshaped direction.

## LuCI app 1.2.6.6

- Fixed: LuCI's Status page showed a 404 for `_helpers.js`.

## LuCI app 1.2.6.5

- Changed: The Status page box matches the Overview.

## LuCI app 1.2.6.4 and install.sh

- Fixed: A failed update is logged and stays on show until the next one.
- Changed: Download order: saved token, then public.
- Added: The installer checks what it installed matches what it downloaded.
- Changed: A failed Ping Filter restart during an update is an error.

## Ping Filter 2.0.6.2

- Fixed: Leftover processes after a stop.

## Ping Filter 2.0.6.1

- Fixed: A device chosen by MAC could switch Ping Filter off.
- Changed: `pingfilter devices` lists MAC devices.

## LuCI app 1.2.6.3

- Fixed: The Map said "No gaming IPs configured" for a MAC device.
- Changed: Gaming devices by MAC listed first, with their address.

## LuCI app 1.2.6.2

- Fixed: Stats drops match tc.
- Removed: Stats "Delay (est.)" under HFSC / HTB.

## Shaper 3.1.2.4

- Added: `counters` reports each class's queue drops and ECN marks.

## Ping Filter 2.0.6.0

- Added: Limit above your best server (`limit_rel_ms`).
- Added: Country list (`allow_country`).
- Added: Ranges in the whitelist and blacklist.
- Added: Ignored ports (`ignore_ports`).
- Added: Game setups: `pingfilter game save|load|delete|list`.
- Added: Play history (`pingfilter sessions`).
- Added: Stuck matchmaking detection.
- Added: Monitored devices by MAC.
- Changed: Own firewall table `inet qos_ex_pf`; one daemon under procd.
- Changed: Lighter while playing.
- Changed: Locations looked up in batches, refreshed after 30 days.
- Changed: IPv6 servers are listed and can be listed always allow / block.
- Removed: 14 timing options and the `readd`, `fill_pings`, `geo_purge`, `cache_audit`, `fw_install`, `fw_uninstall` commands.

## LuCI app 1.2.6.1

- Changed: Share of link counts since the shaper started.

## LuCI app 1.2.6.0

- Added: Dashboard game setups, play history and a stuck-matchmaking notice.
- Added: Settings for the new Ping Filter options.
- Added: Gaming devices by MAC.
- Added: Download and restore the settings as a file.
- Added: Quick setup card and a Status page box.
- Added: The map library is stored on the router.
- Changed: Updates are checked against a release manifest.
- Changed: Reset keeps the old settings as `/etc/qos-ex/config.bak`.

## Shaper 3.1.2.3

- Fixed: Install printed "not found" errors.

## Shaper 3.1.2.2

- Changed: Config upgrade for the Ping Filter 2.0.6.0 options.

## Shaper 3.1.2.1

- Added: Gaming devices by MAC (`ips.gaming_mac`).
- Added: `qos-ex.sh tcplan`.
- Added: `qos-ex.sh uninstall keep`.
- Fixed: CAKE ignored a wash change until a restart.
- Fixed: Status showed MPU as N/A under HFSC and HTB.
- Changed: Flow offloading is turned off when shaping starts, not at install.
- Changed: Save & Apply leaves Ping Filter alone unless its settings changed.
- Changed: A new install takes the WAN from the default route.
- Changed: The debug report hides public IPv6 addresses.
- Added: pbr warning.
- Removed: The Advanced fallback rule set (`advanced.ruleset`).

## Shaper 3.1.2.0 · Ping Filter 2.0.5.2 · LuCI app 1.2.5.7

- Changed: Defaults: `set_timeout` 12 h, `max_servers` 250, `map_keep` 1 h.

## Shaper 3.1.1.9 · Ping Filter 2.0.5.1 · LuCI app 1.2.5.6

- Changed: Forget after defaults to 6 h.

## LuCI app 1.2.5.5

- Changed: Stats Share of link.

## LuCI app 1.2.5.4

- Fixed: Share bars were empty.

## LuCI app 1.2.5.3

- Changed: Stats Trend is a bar with a percentage.

## LuCI app 1.2.5.2

- Added: Connections refresh selector.

## Shaper 3.1.1.8 · LuCI app 1.2.5.1

- Added: A header with live state on every tab.

## LuCI app 1.2.5.0

- Removed: Stats Live Throughput box (on the Overview).

## LuCI app 1.2.4.9

- Changed: Shaper tabs hold settings only.

## Shaper 3.1.1.7 · LuCI app 1.2.4.8

- Changed: Status shows each class's leaf queue.

## Shaper 3.1.1.6

- Changed: Stats: one line per class and direction.

## Shaper 3.1.1.5 · LuCI app 1.2.4.7

- Changed: Auto fq_codel `limit` follows the shaped rate.
- Changed: Auto sfq: `flows` 1024, `headdrop` on.
- Fixed: Manual leaf values take numbers only.

## LuCI app 1.2.4.6

- Added: Click a server for its details.
- Changed: Manage Servers and Advanced split into tabs.

## Ping Filter 2.0.5.0

- Changed: Live capture names the ping source.

## Ping Filter 2.0.4.9

- Fixed: A server judged too far no longer gets a free connect.

## Packaging and docs (no script change)

- Added: OpenWrt package `Makefile` and `files/qos-ex.defaults`.

## LuCI app 1.2.4.5

- Changed: Overview: Live Throughput at the top, Health Checks at the bottom.

## LuCI app 1.2.4.4

- Added: Quality ladder detail on click.

## LuCI app 1.2.4.3

- Changed: Now Playing links to the Map only.

## Shaper 3.1.1.4 · LuCI app 1.2.4.2 · install.sh

- Changed: Updates install by file content, not version number.

## LuCI app 1.2.4.1

- Changed: Overview figures are no longer links.

## Ping Filter 2.0.4.8 · LuCI app 1.2.4.0

- Changed: Clear cache is a fresh start; New game keeps locations.

## Shaper 3.1.1.3

- Changed: Advanced: flat rule layout (replaces 3.1.1.2's).

## Shaper 3.1.1.1

- Changed: A rate of 0 leaves that direction unshaped.
- Changed: Advanced packet-rate thresholds count both directions.
- Fixed: Simple's fast-UDP rule matches SimpleHFSCgamerscript again.
- Fixed: An ICMP error no longer resets a connection's class.

## LuCI app 1.2.3.9

- Fixed: A rate of 0 is accepted and shown as "not shaped".
- Added: Meter download packets switch (Advanced).

## Shaper 3.1.1.0

- Changed: HFSC curves: 50 ms head-start, new first-phase shares, Voice burst.

## LuCI app 1.2.3.8

- Changed: Voice RT curve help follows the new curve.

## Shaper 3.1.0.9

- Changed: HTB holds the shaped rate more tightly under load.

## Shaper 3.1.0.8 · Ping Filter 2.0.4.7 · LuCI app 1.2.3.7

- Removed: Clean-up code for installs from before the rename.

## Shaper 3.1.0.7

- Changed: Source comments tidied.

## LuCI app 1.2.3.6

- Changed: Source comments tidied.

## Documentation

- Changed: README and guides rewritten against the current scripts.

## Shaper 3.1.0.6

- Fixed: `uninstall` leaves nothing behind.

## LuCI app 1.2.3.5

- Added: Uninstall QoS-Ex in Maintenance.

## Shaper 3.1.0.5

- Changed: HTB: Gaming sits outside the class split.
- Changed: `bw_headroom` defaults to 90.

## LuCI app 1.2.3.4

- Changed: Headroom options 100% (off) and 95 down to 70%.
- Changed: MSS gate shown only while the clamp is active.
