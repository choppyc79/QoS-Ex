'use strict';
'require view';
'require uci';
'require ui';
'require poll';
'require view.qos-ex._helpers as h';

/* Ping Filter → Dashboard: the On/Off switch and runtime controls, the
 * summary tiles, the mode cards (the setup card while Ping Filter is
 * off), the Now playing card with its live chart, and the quality ladder
 * of graded servers.
 *
 * Connection score, display only. The implementation lives in
 * _helpers.js (v1.7.8) so the dashboard, the Servers page and the map
 * popup cannot drift apart. score() was this view's only caller of the
 * local haversine wrapper, so the wrapper goes with it. */

function score(s) {
	return h.score(s);
}

// Live this session, for the header's "N live" count: not cached, and
// connected or not yet expired.
function pfIsLive(s) {
	if (!s) return false;
	if (s.state === 'cached') return false;
	if (s.connected) return true;
	return (s.expiry_remaining_sec | 0) > 0;
}
// The live latency chart is shared with the Overview (h.pfChart).
var C_LAT = h.PFC.lat, C_JIT = h.PFC.jit, C_PPS = h.PFC.pps;
function makeChart() { return h.pfChart(); }
function paintChart(ch, tele, basePing, limit) { h.pfChartPaint(ch, tele, basePing, limit); }

// The game stream is the DOMINANT connected flow: highest pps wins, score
// only breaks ties. Picking by score alone let a nearby low-rate side flow
// (voice / PSN telemetry) out-score the real game server, so refresh()
// fetched telemetry for one IP while paint() carded another and the
// sparkline never drew. Card gate = HALF the daemon's active_pps (JSON
// header; default 20 -> enter 10) with a quarter exit hysteresis, so
// low-tick games (10-15 pps inbound) get the card while lobby keepalives
// (<5 pps) still age it out fast. Shared by refresh() and paint() so the
// telemetry fetch and the card ALWAYS agree on the server.
function pickLive(servers, prevIp, cfgPps) {
	return h.pickLive(servers, prevIp, cfgPps);
}

return view.extend({
	handleSaveApply: null, handleSave: null, handleReset: null,

	load: function() {
		var view = this;
		// Fresh UCI every visit so cross-tab edits (a Settings save) are
		// reflected in the dashboard's prerequisite/toggle reads too.
		uci.unload('qos-ex');
		return Promise.all([
			uci.load('qos-ex'),
			h.loadC('pf_servers', h.callPfServers, { servers: [] })
		]).then(function(r) { return view.syncSide(true).then(function() { return r; }); });
	},

	// Play history: small, slow-moving, so fetched on load and at most
	// twice a minute otherwise.
	syncSide: function(force) {
		var view = this;
		if (!force && Date.now() - (view._sideAt || 0) < 30000) return Promise.resolve();
		view._sideAt = Date.now();
		return Promise.all([
			h.callPfSessions().catch(function() { return null; }),
			h.callPfStatus().catch(function() { return null; }),
			h.callHostHints().catch(function() { return null; })
		]).then(function(r) {
			if (r[1]) view.macMap = h.pfMacMap(h.parseState(r[1].output || '').state);
			if (r[2]) view.hints = r[2];
			if (r[0] && r[0].sessions) view.hist = r[0].sessions;
		});
	},

	// Servers plus a fresh UCI (the device and home prerequisites are read
	// from it), then telemetry. A failed call keeps the last payload and
	// says so once (rpcSafe) -- it used to be swallowed without a word.
	refresh: function() {
		var view = this;
		return Promise.all([
			h.uciReload(),
			h.rpcSafe(h.callPfServers(), { servers: [] })
		]).then(function(r) {
			if (h.pfReal(r[1])) view.payload = r[1];
			return view.syncSide(false);
		}).then(function() {
			return view.syncTele();
		});
	},

	syncTele: function() {
		var view = this, j = view.payload || {};
		return Promise.resolve().then(function() {
			// Pull the live ring for the SAME server paint() will card (shared
			// pickLive; see its comment) so the sparkline's telemetry always
			// matches the card. One extra rpc, only when actually connected;
			// soft-fails to the static card otherwise.
			var servers = (j && j.servers) || [];
			var cfgPps = parseInt(j.active_pps, 10) || 20;
			servers.forEach(function(s) { s._score = score(s); });
			var live = pickLive(servers, view._liveIp, cfgPps);
			if (live) view._liveIp = live.ip;
			else if (!(view._teleBuf && (Date.now() - view._teleBuf.when) < 8000))
				view._liveIp = null;
			if (live && h.callPfTelemetry) {
				return h.callPfTelemetry(live.ip).then(function(t) {
					view.tele = (t && t.ip) ? t : null;
					// Buffer ONLY during real gameplay (high pps) so a lobby's
					// low-rate keepalives age out fast instead of pinning the card.
					if (t && t.samples && t.samples.length >= 2 && (t.pps | 0) >= Math.max(3, cfgPps >> 2))
						view._teleBuf = { ip: t.ip, samples: t.samples.slice(), gaps: t.gaps || 0, when: Date.now() };
					view.paint();
				}).catch(function() { view.tele = null; view.paint(); });
			}
			view.tele = null; view.paint();
		});
	},

	paint: function() {
		// The refresh is reading the config again: its own paint, at its
		// end, draws (this one would show the setup card and Watch only).
		if (h.uciBusy()) return;
		var view = this, j = view.payload || {};
		// Live node first (SPA re-renders detach old refs); the render-time
		// root covers the first paint, which runs before LuCI has attached
		// the view -- without it the tab stayed blank until a poll tick
		// landed, and for good if that RPC failed or auto-refresh was paused.
		var box = document.getElementById('pf2-root') || view._root;
		if (!box) return;
		// A number being typed or a list open (mode cards):
		// this poll leaves the page alone, as a rebuild would take the focus.
		var fx = document.activeElement;
		if (fx && box.contains(fx) && /^(INPUT|SELECT)$/.test(fx.tagName)) return;
		// The Watched devices box is still rebuilt each poll: while the user
		// is scrolling it, skip the repaint -- restoring an offset
		// mid-gesture fights the wheel. Checked first: the cards kept
		// across paints must not be moved into a page that is then dropped.
		var oldDev = box.querySelector('.pf-devbox');
		if (oldDev && h.scrollBusy(oldDev)) return;
		// cached rows stay VISIBLE (grey, ranked by their stale data) — when
		// every row is cached, hiding them made the dashboard read "empty"
		// while the user was mid-game.
		var servers = (j.servers || []).slice();
		servers.forEach(function(s) { s._score = score(s); });
		// Ties keep a fixed order (lower ping, then IP) so rows don't swap per poll.
		servers.sort(function(a, b) {
			return (b._score - a._score) || ((a.ping | 0) - (b.ping | 0)) || (a.ip < b.ip ? -1 : 1);
		});

		var cnt = h.pfCounts(j);
		// Watch only: ping mode with no limit.
		var watch = (j.block_mode !== 'distance' && (j.threshold | 0) === 0);

		// On/Off toggle (moved here from Settings per 2.1 layout). Prereqs
		// (gaming IP + home) gate turning ON, mirroring the old Settings rule.
		var pfOn = (j.enabled === 1 || j.enabled === '1');
		// v1.5.2 — the readiness gate follows the Watched devices tick
		// (pf_devices ∩ the gaming devices on Setup → Devices & Ports),
		// because PF cannot run without at least one ticked device that is
		// still a gaming device.
		// The devices PF actually watches. pf_apply_device_filter() drops a
		// ticked entry that is no longer a gaming device, and an empty
		// intersection means PF has NO sources -- it does not fall back to
		// monitoring everything. Computed once here and reused by both the
		// readiness gate and the "Devices watched" tile, so the tile can never
		// claim something the gate disagrees with.
		var devIps = h.pfDevIps();
		var haveGaming = devIps.length > 0;

		// Cap the visible list: a long selection must not push the quality
		// ladder off the page. Ten rows in a short scrollable box, then a
		// muted remainder.
		var DEV_MAX = 10;
		var devCell;
		if (!devIps.length) {
			devCell = E('span', {
				'class': 'qos-ex-muted', 'style': 'font-size:12px',
				'title': _('Ping Filter \u2192 Settings \u2192 Devices')
			}, _('none ticked'));
		} else {
			var devKids = devIps.slice(0, DEV_MAX).map(function(ip) {
				return E('div', {}, E('code', {}, [ h.pfDevLabel(ip, view.macMap) ]));
			});
			if (devIps.length > DEV_MAX)
				devKids.push(E('div', { 'class': 'qos-ex-muted' },
					'+' + (devIps.length - DEV_MAX) + ' ' + _('more')));
			devCell = E('div', { 'class': 'pf-devbox' }, devKids);
		}
		var haveHome = !!(uci.get('qos-ex', 'pingfilter', 'home_lat') &&
			uci.get('qos-ex', 'pingfilter', 'home_lon'));
		// On/off: one switch, kept across paints (view.sw, made in render).
		// Turning it on needs a watched device and a home location: the
		// setup card shows both while Ping Filter is off.
		view.sw.qxSet(pfOn, !(haveGaming && haveHome), (!pfOn && !(haveGaming && haveHome))
			? _('Pick a gaming device and set your home first') : '');

		// Master-off warning. With the QoS-Ex master switch off (Overview),
		// PF can be toggled 'enabled' (armed) but the daemon is gated off by
		// pf_reload/pf_start; say so instead of looking broken.
		var masterOn = (j.master_enabled === 1 || j.master_enabled === '1');
		// Ping Filter holds and grades IPv4 servers only: a monitored device
		// with a public IPv6 address can reach game servers over IPv6 and
		// skip the filter. Matched by MAC, by its IPv4 in the host hints, or
		// an IPv6 entry of its own; link-local and ULA do not count.
		var v6Devs = devIps.filter(function(d) {
			var g = function(a) { return /^[23][0-9a-f]{0,3}:/i.test(String(a)); };
			if (/:/.test(d) && !/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(d)) return g(d);
			return Object.keys(view.hints || {}).some(function(mac) {
				var x = view.hints[mac] || {};
				return (String(mac).toLowerCase() === String(d).toLowerCase() ||
					[].concat(x.ipaddrs || x.ipv4 || []).indexOf(d) >= 0) &&
					[].concat(x.ip6addrs || x.ipv6 || []).some(g);
			});
		});
		var v6Note = !(pfOn && v6Devs.length) ? E([]) :
			E('div', { 'class': 'qos-ex-warn-text', 'style': 'margin:6px 0 0;font-size:12px' }, [
				v6Devs.map(function(d) { return h.pfDevLabel(d, view.macMap); }).join('; '),
				_(' has a public IPv6 address: games over IPv6 are not filtered.') ]);
		var masterNote = masterOn ? E([]) :
			E('div', { 'class': 'qos-ex-warn-text', 'style': 'margin:6px 0 0;font-size:12px' }, [
				_('QoS-Ex is disabled, so Ping Filter will not run \u2014 '),
				E('a', { 'href': L.url('admin', 'network', 'qos-ex', 'overview') }, _('Overview'))
			]);

		// The mode as the daemon runs it (its ping limit reads 0 in distance
		// mode). The mode cards (view.modes) read UCI, where each mode keeps
		// its own number.
		var curThr = (j.threshold | 0);
		var curMode = j.block_mode || 'ping';
		var curCatch = (j.ping_catch | 0);
		view.modes.qxPaint();
		view.warn.qxSet(pfOn && j.activity === 'active');

		var home = (j.home_lat != null && j.home_lon != null &&
			!(parseFloat(j.home_lat) === 0 && parseFloat(j.home_lon) === 0))
			? [ parseFloat(j.home_lat), parseFloat(j.home_lon) ] : null;
		// Same card components as the rest of QoS-Ex (pf-stats / pf-card /
		// pf-label / pf-value) so the dashboard inherits the app theme 1:1.
		// Each tile links to the page (and Settings section) that holds its
		// figures.
		function tile(label, value, path, link) {
			return E('div', { 'class': 'pf-card' }, [
				E('div', { 'class': 'pf-label' }, label),
				E('div', { 'class': 'pf-value' }, [ value ]),
				E('a', { 'class': 'qx-go pf-go', 'href': h.tabUrl([ 'pingfilter' ].concat(path)) }, link + ' \u2192')
			]);
		}
		var tiles = E('div', { 'class': 'pf-stats', 'style': 'margin:12px 0' }, [
			tile(_('Mode'), h.pfModeText(j, true), [ 'settings', '#mode' ], _('Settings')),
			tile(_('Servers (+cached)'), cnt.live + (cnt.cached ? ' +' + cnt.cached : ''), [ 'servers' ], _('Servers')),
			tile(_('Always allow / block'), String(cnt.manual), [ 'servers' ], _('Servers')),
			tile(_('Watched devices'), devCell, [ 'settings', '#devices' ], _('Settings')),
			tile(_('Allowed / blocked'), cnt.allowed + ' / ' + cnt.blocked, [ 'map' ], _('Map'))
		]);

		// Already sorted by score, so the first graded row is the best
		// connection.
		// Quality ladder = servers we have actually PLAYED ON: graded rows
		// (a finalized game-rate session, hist_sessions>0) PLUS servers
		// being played on RIGHT NOW (connected at game-rate pps \u2014 the
		// pfPlaying gate, same threshold as the Now-playing card). Merely
		// "carrying telemetry" was too loose: keepalive / presence / voice
		// side flows all have telemetry rows and flooded the ladder with
		// servers never played on. Graded rows are saved until clear
		// cache; live rows drop off when play stops (and return graded
		// once the session finalizes).
		var ladderRows = servers.filter(function(s) {
			return (s.hist_sessions | 0) > 0 || h.pfPlaying(s, j.active_pps);
		});
		// "best" needs a grade: a live row has no session behind its score.
		var best = ladderRows.filter(function(s) { return (s.hist_sessions | 0) > 0 && s._score >= 0; })[0];
		var bestIp = best ? best.ip : null;
		// When each server was last played and its last five matches, each
		// graded on its own figures (play history, newest first).
		var lastAt = {}, matches = {};
		(view.hist || []).forEach(function(x) {
			if (!lastAt[x.ip]) lastAt[x.ip] = x.ts | 0;
			var m = matches[x.ip] = matches[x.ip] || [];
			if (m.length < 5) m.push([ _('Match') + ' ' + h.fmtAge(x.ts | 0),
				(x.ping > 0 ? x.ping + ' ms' : '\u2014') + ' \u00b7 \u00b1' + (x.jitter | 0) + ' ms \u00b7 ' +
				_('grade') + ' ' + h.grade(h.score({ ping: x.ping, hist_jitter: x.jitter, hist_dur: x.dur, hist_gaps: x.gaps })) +
				' \u00b7 ' + Math.max(1, Math.round((x.dur | 0) / 60)) + ' min' + (x.gname ? ' \u00b7 ' + x.gname : '') ]);
		});
		function ladDet(s) { return h.pfDetRow(s, 8, { home: home, liveIp: view._liveIp, extra: matches[s.ip] }); }
		var rows = [];
		ladderRows.forEach(function(s) {
			// Prefer the live rate while the server is actually being played;
			// fall back to hist_pps (history field 9, EWMA of graded sessions)
			// so a row that has stopped playing still shows what it ran at.
			var pfLive = h.pfPlaying(s, j.active_pps);
			var pfRate = pfLive ? (s.pps | 0) : (s.hist_pps | 0);
			var when = pfLive ? _('now') : (lastAt[s.ip] ? h.fmtAge(lastAt[s.ip]) : '');
			var rcls = 'pf2-row' + (s.connected ? ' pf2-connected' : '') + (view._ladOpen === s.ip ? ' open' : '');
			// Keyed by IP, cells rebuilt only when something shown changed;
			// the row node and its buttons (bound to this IP) persist.
			rows.push({ k: s.ip, cls: rcls, sig: [ rcls, s._score, s.ip === view._liveIp, s.ip === bestIp,
				s.hist_sessions | 0, Math.round((s.hist_dur | 0) / 60), s.fam, s.city, s.country, s.ping, s.hist_jitter, s.jitter,
				pfLive, pfRate, when, s.gname || '' ].join('|'), cells: function() { return [
				E('td', {}, h.gradePill(s._score)),
				E('td', { 'class': 'pf2-mono' }, [
					s.connected ? E('span', { 'class': 'pf-badge-connected' + (s.ip === view._liveIp ? ' pf-live' : ''),
						'title': s.ip === view._liveIp ? _('Playing on this server now') : _('Connected now') }) : '',
					s.ip,
					s.gname ? E('span', { 'class': 'qos-ex-muted' }, [ ' \u00b7 ' + s.gname ]) : '',
					(s.ip === bestIp) ? E('span', { 'class': 'label notice pf2-best', 'title': _('Best graded connection') }, _('best')) : '',
					((s.hist_sessions | 0) === 0) ? E('span', { 'class': 'label notice pf2-best', 'title': _('Measured live; graded after enough play') }, _('live')) : '',
					s.fam === 'v6' ? E('span', { 'class': 'label pf-fam6', 'title': _('IPv6 server') }, 'v6') : ''
				]),
				E('td', {}, [ [s.city, s.country].filter(Boolean).join(', ') || '\u2014' ]),
				E('td', {}, s.ping > 0 ? s.ping + ' ms' : _('pending')),
				E('td', {}, (s.hist_jitter > 0 ? s.hist_jitter : (s.jitter || 0)) + ' ms'),
				// Packet rate -- DISPLAY ONLY, deliberately not part of the score
				// (100 - ping - jitter - stutter). It is a tick-rate fingerprint:
				// it tells you which flow is the game and roughly what cadence the
				// server runs, not whether the connection is good. Live pps while
				// playing, else the graded session average from history.
				E('td', { 'title': pfLive ? _('Live packet rate') : _('Average packet rate across graded sessions') },
					pfRate > 0 ? pfRate + ' pps' : '\u2014'),
				// How much play is behind the grade: total graded time, segments.
				E('td', { 'title': _('Graded play time \u00b7 segments \u00b7 last played') }, (s.hist_sessions | 0) > 0
					? Math.max(1, Math.round((s.hist_dur | 0) / 60)) + ' min \u00b7 ' + (s.hist_sessions | 0) + (when ? ' \u00b7 ' + when : '')
					: E('span', { 'class': 'qos-ex-muted' }, _('live'))),
				E('td', { 'style': 'text-align:right' }, E('button', {
					'class': 'cbi-button cbi-button-negative pf2-rmbtn',
					'title': _('Remove from the ladder (drops its grade, keeps its verdict)'),
					'click': ui.createHandlerFn(view, function() {
						if (!confirm(_('Remove %s from the ladder? Its grade history is dropped.').format(s.ip))) return;
						return h.callPfAction('ungrade', s.ip, 0).then(function(r) { if (!(r && r.ok)) h.notifyErr(_('Action failed')); return view.refresh(); }).catch(function() { h.notifyErr(_('Action failed')); });
					}) }, '\u00d7'))
			]; } });
			if (view._ladOpen === s.ip) rows.push(ladDet(s));
		});

		// Page controls for h.pageHead (below): the On/Off switch, Restart,
		// New game and Clear cache; the live count goes to the banner.
		var liveServers = servers.filter(pfIsLive);
		var sessionChip = pfOn
			? E('span', { 'class': 'label pf-pill', 'title': _('Servers with live traffic this game') }, liveServers.length + _(' live'))
			: E([]);
		var newGameBtn = E('button', {
			'class': 'btn cbi-button-action',
			'title': _('Clear the ladder and found servers, then rescan. Lists stay.'),
			'click': ui.createHandlerFn(view, function() {
				if (!confirm(_('Start a new game? The ladder and found servers are cleared. Lists stay.'))) return;
				return h.callPfAction('session_reset', '', 0).then(function(r) { if (!(r && r.ok)) h.notifyErr(_('Action failed')); return view.refresh(); }).catch(function() { h.notifyErr(_('Action failed')); });
			})
		}, '\u21bb ' + _('New game'));
		// Clear cache: fresh start -- servers, grades, locations, /24 memory and
		// both sets. Only the whitelist / blacklist survive (re-seeded from UCI).
		// "New game" (session_reset) is the partial one and keeps locations.
		var clearCacheBtn = E('button', {
			'class': 'btn cbi-button-action',
			'title': _('Forget every server, grade and location. Lists stay.'),
			'click': ui.createHandlerFn(view, function() {
				if (!confirm(_('Clear cache? Every server, grade, location and /24 memory goes. Lists stay.\n\nThe server you are on may be cut until it is graded again.'))) return;
				return h.callPfAction('clear', '', 0).then(function(r) { if (!(r && r.ok)) h.notifyErr(_('Action failed')); return view.refresh(); }).catch(function() { h.notifyErr(_('Action failed')); });
			})
		}, '\u2715 ' + _('Clear cache'));
		// Runtime controls after the On/Off switch, as the Overview has
		// Restart under its shaper switch; usable while Ping Filter is on.
		function pfSvc(label, verb) {
			return E('button', {
				'class': 'btn cbi-button-action',
				'disabled': pfOn ? null : 'disabled',
				'title': pfOn ? '' : _('Enable Ping Filter first'),
				'click': ui.createHandlerFn(view, function() {
					return h.callPfAction(verb, '', 0)
						.then(function(r) { if (r && r.ok) h.notifyOk(_('Ping Filter: ') + verb); else h.notifyErr(_('Ping Filter: ') + verb + ' ' + _('failed')); return view.refresh(); })
						.catch(function() { h.notifyErr(_('Action failed')); });
				})
			}, label);
		}
		// The controls; the live count joins the banner above the tabs.
		var hdrRow = h.pageHead(_('Ping Filter Dashboard'), 'pf', {
			pills: E('span', { 'class': 'qos-ex-hdr-pills' }, [ sessionChip ]),
			tools: E('div', { 'class': 'qos-ex-svc' }, [
				view.sw, pfSvc(_('Restart'), 'restart'), newGameBtn, clearCacheBtn ]) });

		// Off: the setup card in place of the tiles and the mode card; the
		// switch stays in the tool row above.
		if (!pfOn) { view.setupO.macMap = view.macMap; view.setup.qxPaint(); }
		var els = pfOn ? [
			hdrRow,
			tiles,
			E('div', { 'class': 'cbi-section qos-ex-card pf2-hero' }, [
				E('div', { 'class': 'pf2-state' }, [
					E('div', {}, [ h.pfModeText(j) ]),
					masterNote,
					v6Note,
					view.warn
				]),
				view.modes
			])
		] : [ hdrRow, view.setup, masterNote ];
		// Blocked servers keep turning up and nothing is being played: the
		// limit is probably too tight for this game or time of day. Under
		// Ping Catch the catch lets far servers in, so it is raised first.
		if (pfOn && !watch && (j.stuck | 0) >= 3) {
			var km = parseInt(j.home_radius_km, 10) || 500;
			var relax = curMode !== 'distance' ? [ 'threshold', Math.min(5000, curThr + 10), _('Relax limit to %d ms') ]
				: curCatch > 0 && curCatch < 250 ? [ 'catch', Math.min(250, curCatch + 10), _('Relax Ping Catch to %d ms') ]
				: [ 'radius', Math.min(20000, Math.round(km * 1.25)), _('Relax radius to %d km') ];
			els.push(E('div', { 'class': 'pf2-learn' }, [
				_('Matchmaking looks stuck: servers blocked, no game started.') + ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(view, function() {
					return h.callPfAction(relax[0], '', relax[1]).then(function(r) {
						if (!(r && r.ok)) h.notifyErr(_('Action failed'));
						return view.refresh();
					}).catch(function() { h.notifyErr(_('Action failed')); });
				}) }, relax[2].format(relax[1]))
			]));
		}
		if (pfOn && (j.geo_down | 0))
			els.push(E('div', { 'class': 'pf2-learn' },
				_('No location service answers; an ad blocker may be blocking it.')));

		// "Now playing" — the single server we are actively gaming on: the
		// connected server carrying CONTINUOUS game UDP right now (pickLive:
		// highest pps wins, score only breaks ties), not merely a recent
		// connection — so sitting in a lobby (low-rate keepalives) clears the
		// card instead of pinning the last server you were on.
		var live = pickLive(servers, view._liveIp, parseInt(j.active_pps, 10) || 20);
		// Bridge only brief in-GAME packet gaps (short window). A lobby never
		// refreshes the buffer (pps stays low), so it ages out within seconds.
		if (!live && view._teleBuf && (Date.now() - view._teleBuf.when) < 8000)
			live = servers.filter(function(s) { return s.ip === view._teleBuf.ip; })[0];
		var chSlot = null, chArgs = null;
		if (live) {
			var graphTele = (view.tele && view.tele.ip === live.ip && view.tele.samples && view.tele.samples.length >= 2)
				? view.tele
				: ((view._teleBuf && view._teleBuf.ip === live.ip && (Date.now() - view._teleBuf.when) < 25000) ? view._teleBuf : null);
			chSlot = E('div', {});
			// The graph's base is the last in-play reading (lv) when there
			// is one: the server's figure only ever moves down.
			chArgs = [ graphTele, live.lv > 0 ? live.lv : live.ping, watch ? 0 : (curMode === 'distance' ? curCatch : curThr) ];
			// The server as its Servers-list row: state, pins, click for details.
			var nowOpen = (view._nowOpen === live.ip);
			var nowBody = E('tbody', { 'click': function(ev) {
				if (ev.target.closest('button, a') || String(window.getSelection() || '')) return;
				var tr = ev.target.closest('tr');
				if (!tr || String(tr.getAttribute('data-k') || '').indexOf('det:') === 0) return;
				view._nowOpen = nowOpen ? null : live.ip;
				view.paint();
			} });
			h.syncRows(nowBody, [ h.pfSrvRow(live, { playIp: view._liveIp, open: nowOpen, home: home,
				blockMode: curMode, pingCatch: curCatch, pingVarPct: j.ping_var_pct, homeRadiusKm: j.home_radius_km,
				act: function(verb, ip) {
					return h.callPfAction(verb, ip, 0).then(function(r) {
						if (!(r && r.ok)) h.notifyErr(_('Action failed'));
						return view.refresh();
					}).catch(function() { h.notifyErr(_('Action failed')); });
				} }) ].concat(nowOpen ? [ h.pfDetRow(live, 8, { home: home, liveIp: view._liveIp }) ] : []));
			var nowTbl = E('div', { 'class': 'pf2-now-wrap' },
				E('table', { 'class': 'qos-ex-tbl pf-rows' }, [ h.pfSrvHead(), nowBody ]));
			els.push(E('div', { 'class': 'cbi-section qos-ex-card pf2-now' }, [
				E('h3', { 'class': 'qos-ex-card-title' },
					[ E('span', { 'class': 'pf-badge-connected pf-live' }), _('Now playing'),
						live.gname ? ' \u00b7 ' + live.gname : '' ]),
				E('div', { 'class': 'pf2-now-grid' }, [
					E('div', {}, [
						E('div', { 'class': 'pf2-now-ip' }, [ live.ip ]),
						E('div', { 'class': 'qos-ex-muted' },
							[ [live.city, live.country].filter(Boolean).join(', ') || _('location unknown') ])
					]),
					E('div', { 'class': 'pf2-now-score' }, [
						E('div', { 'class': 'qx-grade ' + (h.scoreBand(live._score) || 'none'), 'title': _('Score %s').format(h.scoreTxt(live._score)) }, h.grade(live._score)),
						E('div', { 'class': 'qos-ex-muted' }, _('grade'))
					]),
					E('div', { 'class': 'pf2-now-stats' }, [
						E('div', [ E('b', {}, live.ping > 0 ? live.ping + ' ms' : '\u2014'), ' ',
							E('span', { 'class': 'qos-ex-muted' }, _('ping') + (/^(real|icmp)$/.test(live.ping_source || '') ? ' \u00b7 icmp' : ' \u00b7 est')) ]),
						E('div', [ E('b', {}, '\u00b1' + (live.jitter || 0) + ' ms'), ' ',
							E('span', { 'class': 'qos-ex-muted' }, _('jitter')) ])
					])
				]),
				nowTbl,
				chSlot,
				E('div', { 'class': 'pf2-spark-legend qos-ex-muted' }, [
					E('span', { 'class': 'pf2-spark-key', 'style': 'background:' + C_LAT }), _('latency'),
					E('span', { 'class': 'pf2-spark-key', 'style': 'background:' + C_JIT }), _('jitter'),
					E('span', { 'class': 'pf2-spark-key', 'style': 'background:' + C_PPS }), _('packets/s (relative)'),
					(view.tele && view.tele.ip === live.ip && view.tele.gaps) ? E('span', { 'class': 'pf2-spark-gaps' }, ' \u00b7 ' + view.tele.gaps + _(' stutters')) : '',
					(live.hist_sessions > 0) ? E('span', {}, ' \u00b7 ' + _('graded over ') + live.hist_sessions + _(' segment(s): ') + '\u00b1' + live.hist_jitter + _('ms avg')) : ''
				])
			]));
		} else if (pfOn) {
			els.push(E('div', { 'class': 'cbi-section qos-ex-card pf2-now qos-ex-muted' },
				_('No game server right now. Start a match.')));
		}

		function ladderHead() {
			return E('tr', {},
				[ _('Grade'), _('Server'), _('Location'), _('Ping'), _('Jitter'), _('Rate'), _('Played'), '' ].map(function(t) {
					return E('th', {}, t);
				}));
		}
		var scoreLegend = E('div', { 'class': 'pf2-legend qos-ex-muted' }, [
			_('Grade: '),
			E('span', { 'class': 'label pf-score qx-gp good' }, 'S'), ' ', E('span', { 'class': 'label pf-score qx-gp good' }, 'A'), _(' great'), '  ',
			E('span', { 'class': 'label pf-score qx-gp ok' }, 'B'), ' ', E('span', { 'class': 'label pf-score qx-gp ok' }, 'C'), _(' ok'), '  ',
			E('span', { 'class': 'label pf-score qx-gp poor' }, 'D'), _(' poor'), ' \u00b7 ', _('hover a grade for its score')
		]);
		// The ladder card is built ONCE and kept: its collapsible scroll box
		// (h.sboxTable, as the Server list) is never detached, and its
		// rows are synced in place by IP. A box rebuilt every poll lost its
		// scrollbar and offset on each refresh.
		var lad = view._lad;
		if (!lad) {
			lad = view._lad = h.sboxTable(_('Graded servers'), 'pf2-ladder', ladderHead(), false);
			lad.box.classList.add('pf2-ladder-scroll');
			// One delegated listener (rows are synced in place): a server row
			// opens or closes its detail row, one at a time.
			lad.body.addEventListener('click', function(ev) {
				if (ev.target.closest('button, a') || String(window.getSelection() || '')) return;
				var tr = ev.target.closest('tr'), k = tr && tr.getAttribute('data-k');
				if (!k || k === '-' || k.indexOf('det:') === 0) return;
				view._ladOpen = (view._ladOpen === k) ? null : k;
				view.paint();
			});
			lad.card = E('div', { 'class': 'cbi-section qos-ex-card' }, [
				E('h3', { 'class': 'qos-ex-card-title' }, _('Quality ladder')), scoreLegend, lad.node ]);
		}
		h.syncRows(lad.body, rows.length ? rows : [ { k: '-', sig: '-', cells: function() {
			return [ E('td', { 'colspan': 8, 'class': 'qos-ex-muted' },
				_('No graded servers yet. Play a match.')) ];
		} } ]);
		els.push(lad.card);

		// Everything but the kept ladder card is replaced; the ladder card
		// never leaves the document (detaching a scroll box resets it).
		h.scrollKeepAll(box, [ '.pf-devbox' ], function() {
			Array.prototype.slice.call(box.childNodes).forEach(function(n) {
				if (n !== lad.card) box.removeChild(n);
			});
			els.forEach(function(e, i) {
				if (box.childNodes[i] !== e) box.insertBefore(e, box.childNodes[i] || null);
			});
		});
		// The chart node is kept and moved into the fresh card only now, so
		// a repaint skipped above leaves it where it was.
		view._chArgs = chArgs;
		if (chArgs) {
			chSlot.appendChild((view._ch || (view._ch = makeChart())).node);
			view.drawChart();
		}
	},

	// Drawn at the box's pixel width, so it runs after the card is in the
	// document and again when the window is resized.
	drawChart: function() {
		var a = this._chArgs;
		if (a && this._ch) paintChart(this._ch, a[0], a[1], a[2]);
	},

	render: function(loaded) {
		var view = this;
		view.payload = loaded[1] || {};
		// 2.1: no disabled-gate here — the On/Off switch LIVES on this tab,
		// so the dashboard must render (with the toggle) even when off.
		var root = E('div', { 'id': 'pf2-root' });
		view._root = root;
		var j0 = view.payload;
		view.sw = h.qxSwitch({ label: _('Ping Filter'), on: j0.enabled === 1 || j0.enabled === '1',
			change: function(want) {
				return h.callPfAction(want ? 'enable' : 'disable', '', 0).then(function(r) {
					var ok = !!(r && r.ok);
					if (!ok) h.notifyErr(_('Action failed'));
					return view.refresh().then(function() { return ok; });
				}).catch(function() { h.notifyErr(_('Action failed')); return false; });
			} });
		// Kept across paints too: the mode cards (a change refreshes the
		// page), the in-match warning and the setup card shown while off.
		view.modes = h.pfModes({ done: function() { return view.refresh(); } });
		view.warn = h.pfMatchWarn();
		view.setupO = { macMap: view.macMap };
		view.setup = h.pfSetup(view.setupO);
		// Anchored: a bare poll.add outlives the view in LuCI's SPA and keeps
		// forking the backend every interval for the rest of the session.
		h.pollWhile(root, function() { return view.refresh(); },
			!!(loaded[1] && loaded[1]._cached));
		// The page controls and the banner's live count (h.pageHead) are
		// built inside paint() so they track live state — see paint().
		var out = E([], [root]);
		view.paint();
		window.addEventListener('resize', function rz() {
			if (!document.body.contains(root)) { window.removeEventListener('resize', rz); return; }
			view.drawChart();
		});
		// Mid-game, load() has the servers but not the live ring, so fetch
		// just the telemetry now rather than leaving the graph empty until
		// the first poll. (A cached load leads with a full refresh instead.)
		if (!(loaded[1] && loaded[1]._cached))
			window.setTimeout(function() { view.syncTele(); }, 0);
		return out;
	}
});
