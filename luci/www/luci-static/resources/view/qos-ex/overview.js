'use strict';
'require view';
'require uci';
'require ui';
'require poll';
'require dom';
'require view.qos-ex._helpers as h';

// Overview: what a player wants at a glance. The match being played (Now
// Playing, with a small version of the Dashboard chart), one switch each for
// the shaper and Ping Filter, the line and the gaming traffic, the game
// stream itself (EF UDP flows), the gaming queue as the shaper runs it, and
// one line per area linking to where it is set. Health and updates sit in
// their own card at the bottom; problems show at the top only when there is
// one.

function listCount(v) {
	if (Array.isArray(v)) return v.filter(function(x) { return String(x || '').trim(); }).length;
	return (v && String(v).trim()) ? 1 : 0;
}

// A card is replaced only when its inputs changed, so an idle page makes no
// DOM writes. `build` runs only on a change.
function fill(box, sig, build) {
	if (!box || box.__qosExSig === sig) return;
	box.__qosExSig = sig;
	dom.content(box, build());
}

// Live line: the Stats figures, sampled on this page's own poll. Same
// arithmetic as Stats: rate from counter deltas, delay of the highest
// priority class (CAKE tin average, else backlog / drain rate), drops +
// ECN marks over the window. The highest priority class is the gaming one
// (HFSC/HTB 1:10; CAKE's Voice tin, where EF lands).
var WIN = 300;
var RANK = [ 'Gaming', 'Voice', 'Video', 'Default', 'Best Effort', 'Low', 'Bulk' ];
function rank(n) {
	var k = RANK.indexOf(n), m = /^Tin (\d+)$/.exec(n || '');
	return k >= 0 ? k : m ? 20 - +m[1] : 3.5;
}
function fmtMs(v) {
	return v == null ? '—' : (v < 10 ? v.toFixed(1) : String(Math.round(v))) + ' ms';
}
function fmtUs(us) {
	us = +us || 0;
	return us < 1000 ? us + ' µs' : (us / 1000).toFixed(us < 10000 ? 2 : 1) + ' ms';
}
// Short rate: "120.4 Mbit".
function rShort(v) {
	v = +v || 0;
	var u = v >= 1e9 ? [ 1e9, 'Gbit' ] : v >= 1e6 ? [ 1e6, 'Mbit' ] : v >= 1e3 ? [ 1e3, 'kbit' ] : [ 1, 'bit' ];
	return (+(v / u[0]).toFixed(1)) + ' ' + u[1];
}
// A fill fraction 0..1 as a meter with a good / ok / poor band.
function meter(frac, band) {
	var i = E('i', { 'class': band || '' });
	i.style.width = Math.max(0, Math.min(100, (frac || 0) * 100)).toFixed(1) + '%';
	return E('div', { 'class': 'qx-meter' }, i);
}

// Health checks: the dots from the light `state` every tick; the warnings
// need the full report (status).
var CHECKS = [
	[ 'root_qdisc',    _('Root qdisc on WAN') ],
	[ 'ingress_qdisc', _('Download hook (ingress or clsact)') ],
	[ 'ifb_up',        _('Download device present') ],
	[ 'ctinfo',        _('ctinfo DSCP restore') ],
	[ 'nft_table',     _('nftables table loaded') ],
	[ 'init',          _('procd init installed') ],
	[ 'hotplug',       _('Hotplug (ifup) hook') ]
];

// The Ping Filter mode in use, from the live settings (as the Dashboard).
function pfProfile(j) {
	return h.pfModeText(j, true);
}
// The limit the chart draws: the ping limit, or the catch in distance mode.
function pfLimit(j) {
	return j.block_mode === 'distance' ? (j.ping_catch | 0) : (j.threshold | 0);
}

// Gaming traffic sparkline: the EF game flows' rate (both directions) over
// the window (ctIngest).
function rateSpark(G) {
	var v = (G || []).map(function(x) { return x.dn + x.up; });
	if (v.length < 2) return E('div', { 'class': 'qx-spark qx-spark-empty' });
	var hi = Math.max.apply(null, v.concat([ 1 ]));
	var W = 300, H = 36, pts = v.map(function(x, i) {
		return (i * W / (v.length - 1)).toFixed(1) + ',' + (H - 2 - x * (H - 6) / hi).toFixed(1);
	});
	var ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
	svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
	svg.setAttribute('preserveAspectRatio', 'none');
	svg.setAttribute('class', 'qx-spark');
	svg.setAttribute('role', 'img');
	svg.setAttribute('aria-label', _('Gaming traffic over the last %d minutes, peak %s').format(WIN / 60, h.fmtRate(hi)));
	var area = document.createElementNS(ns, 'polygon'), line = document.createElementNS(ns, 'polyline');
	area.setAttribute('points', '0,' + H + ' ' + pts.join(' ') + ' ' + W + ',' + H);
	line.setAttribute('points', pts.join(' '));
	svg.appendChild(area); svg.appendChild(line);
	return svg;
}

// Game stream rows: the Flows table's columns, no detail row.
function fmtBits(n) { return n ? h.fmtRate(n * 8) : '0'; }
function updn(up, dn, fmt) {
	var f = fmt || String;
	return E('div', {}, [
		E('span', { 'class': up ? '' : 'qos-ex-muted' }, '↑ ' + f(up)), E('br'),
		E('span', { 'class': dn ? '' : 'qos-ex-muted' }, '↓ ' + f(dn)) ]);
}
var FCOLS = [ [ _('Class'), 0, '11ch' ], [ _('Proto'), 0, '6ch' ], [ _('Source'), 0, '15ch' ],
	[ _('Sport'), 1, '7ch' ], [ _('Destination'), 0, '15ch' ], [ _('Dport'), 1, '7ch' ],
	[ _('Rate'), 1, '14ch' ], [ _('pps'), 1, '8ch' ], [ _('Total'), 1, '12ch' ] ];
var FLOW_MAX = 6, CT_CAP = 50;

return view.extend({
	// load() answers from the last-known replies when this browser tab has
	// them (h.loadC), so the page paints at once and the first poll brings
	// it up to date.
	load: function() {
		return Promise.all([
			uci.load('qos-ex'),
			h.loadC('state', h.callState),
			h.loadC('pf_servers', h.callPfServers, { servers: [] })
		]);
	},

	render: function(loaded) {
		var view = this;
		view.stOut = (loaded[1] && loaded[1].output) || '';
		view.pf    = loaded[2] || {};
		view.pfV   = '';
		view.full  = {};
		view.names = {};
		view.macMap = {};
		view.ct = { prev: {}, t: 0, rows: [] };

		var head = h.pageHead(_('Overview'), null, { fed: true });
		h.barFeed(loaded[1]);

		view.boxes = {
			stale: E('div'),
			alert: E('div'),
			setup: E('div'),
			now:   E('div', { 'class': 'cbi-section qos-ex-card qx-now' }),
			flows: E('div', { 'class': 'cbi-section qos-ex-card qx-gflow' }),
			queue: E('div', { 'class': 'cbi-section qos-ex-card qx-gq' }),
			glance: E('div', { 'class': 'cbi-section qos-ex-card qx-glance' }),
			health: E('div', { 'class': 'cbi-section qos-ex-card qx-health' })
		};
		view.ch = h.pfChart(true);

		// ---- Controls: one switch each, restart / reload under the shaper.
		function after(p) { return Promise.resolve(p).then(function(v) { view.poll(); return v; }); }
		var st0 = h.parseState(view.stOut).state;
		view.swQ = h.qxSwitch({
			label: _('Shaper'),
			on: (st0.enabled || uci.get('qos-ex', 'settings', 'enabled')) === '1',
			change: function(want) {
				return after(h.callAction(want ? 'enable' : 'disable').then(function(r) {
					var ok = !!(r && r.ok);
					if (ok && r.pending) h.notifyOk(_('Still working \u2014 the state below updates when it is done'));
					else if (ok) h.notifyOk(want ? _('Shaper on') : _('Shaper off — Ping Filter off too'));
					else h.notifyErr(want ? _('Could not start — check the WAN and speeds on Setup') : _('Could not stop'));
					return ok;
				}));
			}
		});
		view.swP = h.qxSwitch({
			label: _('Ping Filter'),
			on: view.pf.enabled === 1 || view.pf.enabled === '1',
			change: function(want) {
				return after(h.callPfAction(want ? 'enable' : 'disable', '', 0).then(function(r) {
					var ok = !!(r && r.ok);
					if (!ok) h.notifyErr(_('Action failed'));
					return ok;
				}));
			}
		});
		function small(label, verb, okMsg) {
			return E('button', { 'type': 'button', 'class': 'btn cbi-button qx-mini',
				'click': ui.createHandlerFn(view, function() {
					return after(h.callAction(verb).then(function(r) {
						(r && r.ok) ? h.notifyOk(r.pending ? _('Still working \u2014 the state below updates when it is done') : okMsg)
							: h.notifyErr(_('Action failed'));
					}));
				}) }, label);
		}
		view.cq = { sub: E('div', { 'class': 'qx-ctl-sub' }), stat: E('div', { 'class': 'qx-ctl-stat' }),
			btns: E('div', { 'class': 'qx-ctl-btns' }, [
				small(_('Restart'), 'restart', _('Shaper restarted')),
				small(_('Reload rules'), 'reload', _('nft rules reloaded')) ]) };
		view.cp = { sub: E('div', { 'class': 'qx-ctl-sub' }), stat: E('div', { 'class': 'qx-ctl-stat' }) };
		var ctl = E('div', { 'class': 'cbi-section qos-ex-card qx-ctl' }, [
			E('div', { 'class': 'qx-ctl-row' }, [
				E('div', { 'class': 'qx-ctl-txt' }, [ E('div', { 'class': 'qx-label' }, [ _('Shaper'), E('span', { 'class': 'qx-right' }, h.go([ 'setup' ], _('Settings'))) ]), view.cq.sub, view.cq.stat ]),
				view.swQ ]),
			view.cq.btns,
			E('div', { 'class': 'qx-ctl-row' }, [
				E('div', { 'class': 'qx-ctl-txt' }, [ E('div', { 'class': 'qx-label' }, [ _('Ping Filter'), E('span', { 'class': 'qx-right' }, h.go([ 'pingfilter', 'dashboard' ], _('Dashboard'))) ]), view.cp.sub, view.cp.stat ]),
				view.swP ])
		]);

		// ---- Live tiles: static nodes, values written in place each paint.
		// Download / Upload are arc gauges (rate against the shaped rate,
		// h.qxGauge) with the figure inside the arc; the wide Gaming tile
		// keeps its sparkline.
		view.tv = {};
		view.gq = {};
		function tile(id, label, wide) {
			view.tv[id] = E('div', { 'class': 'qx-big' }, '—');
			view.tv[id + 's'] = E('div', { 'class': 'qx-sub' });
			if (wide) {
				view.tv[id + 'm'] = E('div', { 'class': 'qx-tile-spark' });
				return E('div', { 'class': 'qx-tile qx-wide', 'data-k': id }, [
					E('div', { 'class': 'qx-label' }, label),
					view.tv[id], view.tv[id + 's'], view.tv[id + 'm'] ]);
			}
			view.gq[id] = h.qxGauge();
			return E('div', { 'class': 'qx-tile qx-gtile', 'data-k': id }, [
				E('div', { 'class': 'qx-label' }, label),
				E('div', { 'class': 'qx-gauge-wrap' }, [ view.gq[id].svg, view.tv[id] ]),
				view.tv[id + 's'] ]);
		}
		var tiles = E('div', { 'class': 'qx-tiles' }, [
			tile('dn', _('Download')), tile('up', _('Upload')), tile('gm', _('Gaming traffic'), true) ]);

		view.lt = { prev: null, pe: {}, S: { up: [], down: [] }, G: [], meta: {}, est: false, tc: null };
		// A rate needs two samples: take the first now, the poll brings the second.
		view.sample().then(function() { view.paint(); });

		// After the page is up: PF version + the addresses its MAC devices
		// hold, device names, GitHub versions (router's 1 h cache), and the
		// full report (health warnings).
		h.rpcSafe(h.callPfStatus(), {}).then(function(r) {
			var s = h.parseState((r && r.output) || '').state;
			view.pfV = s.version || '';
			Object.assign(view.macMap, h.pfMacMap(s));
			view.paint();
		});
		h.callHostHints().then(function(r) {
			Object.keys(r || {}).forEach(function(mac) {
				if (r[mac] && r[mac].name) view.names[String(mac).toLowerCase()] = r[mac].name;
			});
			view.macMap = Object.assign(h.hintMacMap(r), view.macMap);
			view.paint();
		}).catch(function() {});
		h.callUpdateCheck(0).then(function(r) { view.upd = r || null; view.paint(); }).catch(function() {});
		// Set up on other hardware (a config restored onto a new router),
		// only when Auto Setup recorded the hardware. The router's own
		// fingerprint is asked once per login (kept in this browser tab), not
		// on every visit: each ask is a run of the backend.
		var hwSet = uci.get('qos-ex', 'autosetup', 'hw'), hwKey = 'qosex:hw:' + (L.env.sessionid || '');
		if (hwSet) {
			var hwNow = null;
			try { hwNow = window.sessionStorage.getItem(hwKey); } catch (e) {}
			(hwNow ? Promise.resolve(hwNow) : h.callAutosetup('hw').then(function(r) {
				var m = /(^|\n)hw=([^\n]*)/.exec((r && r.output) || '');
				if (m) try { window.sessionStorage.setItem(hwKey, m[2]); } catch (e) {}
				return m ? m[2] : null;
			})).then(function(now) {
				view.hwChanged = !!now && now !== hwSet;
				view.paint();
			}).catch(function() {});
		}
		h.loadC('status', h.callStatus).then(function(r) {
			view.full = h.parseState((r && r.output) || '').state;
			view.fullTicks = (r && r._cached) ? 12 : 0;
			view.paint();
		});

		view.paint();
		h.pollWhile(head, function() { return view.poll(); },
			!!((loaded[1] && loaded[1]._cached) || (loaded[2] && loaded[2]._cached)));
		window.addEventListener('resize', function rz() {
			if (!document.body.contains(head)) { window.removeEventListener('resize', rz); return; }
			view.drawChart();
		});

		var b = view.boxes;
		return E([], [ head, b.stale, b.alert, b.setup,
			E('div', { 'class': 'qx-hero' }, [ b.now, ctl ]),
			tiles, b.flows, b.queue, b.glance, b.health ]);
	},

	// One live sample. Counters are cumulative: the first sample, or a
	// direction with no counters (stopped / unshaped), gives no rate.
	sample: function() {
		var view = this, L = view.lt;
		return h.liveSample().then(function(res) {
			if (res[0]._err) return;
			var c = h.parseCounters(res[0].output || ''), tc = res[1];
			var now = Date.now(), dt = L.prev ? (now - L.prev.t) / 1000 : 0, b = {};
			var cake = c.meta.qdisc === 'cake';
			L.meta = c.meta;
			L.est = !cake;
			L.tc = (tc && !tc._err) ? tc : null;
			[ 'down', 'up' ].forEach(function(d) {
				var rows = c.rows[d] || [], S = L.S[d], pe = L.pe[d];
				var td = tc ? (d === 'down' ? tc.ingress : tc.egress) : null;
				var q = h.cakeOf(td && td.qdisc);
				var bytes = 0, drops = 0, ecn = null, g = null, m, re = /\becn_mark:? (\d+)/g;
				rows.forEach(function(x) {
					bytes += x.bytes; drops += x.drops;
					if (!g || rank(x.name) < rank(g.name)) g = x;
				});
				if (!g) { L.S[d] = []; L.pe[d] = null; return; }
				b[d] = bytes; b[d + '|g'] = g.bytes;
				if (cake) {
					if (q) { ecn = 0; (q.tins || []).forEach(function(t) { ecn += +t.ecn_mark || 0; }); }
				} else if (td && td.text) {
					ecn = 0;
					while ((m = re.exec(td.text))) ecn += +m[1];
				}
				if (!L.prev || !(dt > 0.2) || !pe || L.prev.b[d] === undefined) { L.pe[d] = { drops: drops, ecn: ecn }; return; }
				var r = Math.max(0, bytes - L.prev.b[d]) * 8 / dt, dl = null;
				var gr = Math.max(0, g.bytes - (L.prev.b[d + '|g'] || 0)) * 8 / dt;
				if (cake) {
					if (q && g.tin >= 0 && q.tins && q.tins[g.tin]) dl = (+q.tins[g.tin].avg_delay_us || 0) / 1000;
				} else {
					var drain = gr > 0 ? gr : (+(d === 'up' ? c.meta.ul_kbps : c.meta.dl_kbps) || 0) * 1000;
					dl = (g.backlog > 0 && drain > 0) ? Math.min(1000, g.backlog * 8000 / drain) : 0;
				}
				var ev = Math.max(0, drops - pe.drops) +
					((ecn != null && pe.ecn != null) ? Math.max(0, ecn - pe.ecn) : 0);
				L.pe[d] = { drops: drops, ecn: ecn != null ? ecn : pe.ecn };
				S.push({ t: now, r: r, dl: dl, ev: ev });
				while (S.length > 1 && S[0].t < now - WIN * 1000) S.shift();
			});
			L.prev = { t: now, b: b };
		});
	},

	// The game stream: EF-marked UDP rows of the connection table, with
	// rates from the change since the last read, each the way the LAN
	// device sees it (a flow opened from outside, a port forward, has its
	// original direction coming in). Their sum is the Gaming traffic tile,
	// whatever the queue type.
	ctIngest: function(text) {
		var C = this.ct, L = this.lt, now = Date.now() / 1000, dt = C.t ? now - C.t : 0, next = {}, rows = [], ub = 0, db = 0;
		String(text || '').split(/\n/).forEach(function(line) {
			var r = h.ctRow(line);
			if (!r || r.proto !== 'udp' || r.dscp !== 'ef') return;
			r.key = r.fam + ':' + r.src + '/' + r.sport + '->' + r.dst + '/' + r.dport;
			var p = C.prev[r.key];
			next[r.key] = { up: r.upPkts, dn: r.dnPkts, ub: r.upBytes, db: r.dnBytes };
			if (!p || !(dt > 0)) return;
			r.upPps = Math.max(0, Math.round((r.upPkts - p.up) / dt));
			r.dnPps = Math.max(0, Math.round((r.dnPkts - p.dn) / dt));
			r.upBps = Math.max(0, Math.round((r.upBytes - p.ub) / dt));
			r.dnBps = Math.max(0, Math.round((r.dnBytes - p.db) / dt));
			if (!h.isLan(r.src) && h.isLan(r.rsrc)) [ 'Pps', 'Bps', 'Pkts', 'Bytes' ].forEach(function(k) {
				var x = r['up' + k]; r['up' + k] = r['dn' + k]; r['dn' + k] = x;
			});
			ub += r.upBps; db += r.dnBps;
			if (r.upPps + r.dnPps > 0) rows.push(r);
		});
		C.prev = next; C.t = now;
		if (dt > 0) {
			L.G.push({ t: now * 1000, dn: db * 8, up: ub * 8 });
			while (L.G.length > 1 && L.G[0].t < (now - WIN) * 1000) L.G.shift();
		}
		C.rows = rows.sort(function(a, z) { return (z.upPps + z.dnPps) - (a.upPps + a.dnPps); });
		C.n = (C.n || 0) + 1;
	},

	// One tick: shaper state, the PF snapshot, a fresh copy of UCI (edits on
	// other tabs or over SSH show without a reload), a live sample, the
	// connection table while the shaper runs, and the live server's
	// telemetry while a match is on. While PF is off its snapshot is re-read
	// every sixth tick only.
	poll: function() {
		var view = this, j = view.pf || {};
		var pfDue = !h.pfReal(j) || (j.enabled === 1 || j.enabled === '1') ||
			!(view.pfSkip = ((view.pfSkip || 0) + 1) % 6);
		var old = h.parseState(view.stOut).state;
		return Promise.all([
			h.uciReload(),
			h.rpcSafe(h.callState()),
			pfDue ? h.rpcSafe(h.callPfServers(), { servers: [] }) : null,
			view.sample(),
			view.liveIp ? h.callPfTelemetry(view.liveIp).catch(function() { return null; }) : null,
			h.running(old) ? h.rpcSafe(h.callConntrack(CT_CAP)) : null
		]).then(function(r) {
			if (!r[1]._err) { view.stOut = r[1].output || ''; h.barFeed(r[1]); }
			if (h.pfReal(r[2])) view.pf = r[2];
			view.tele = (r[4] && r[4].ip === view.liveIp) ? r[4] : null;
			if (r[5] && !r[5]._err) view.ctIngest(r[5].output);
			else if (!r[5]) view.ct = { prev: {}, t: 0, rows: [] };
			// The full report only when the shaper moved (a restart, a UCI
			// commit, a component flag) and once a minute regardless.
			var ns = h.parseState(view.stOut).state, moved = false;
			[ 'cfg_sum', 'root_qdisc', 'ingress_qdisc', 'ifb_up', 'ctinfo', 'nft_table',
			  'init', 'hotplug', 'wan' ].forEach(function(k) { if (ns[k] !== old[k]) moved = true; });
			view.fullTicks = (view.fullTicks || 0) + 1;
			if (!moved && view.fullTicks < 12) return;
			view.fullTicks = 0;
			return h.rpcSafe(h.callStatus()).then(function(s) {
				if (!s._err) view.full = h.parseState(s.output || '').state;
			});
		}).then(function() { view.paint(); });
	},

	// The Now playing chart is drawn at its box width: after the card is in
	// the document, and again on a window resize.
	drawChart: function() {
		var a = this.chArgs;
		if (a && this.ch.node.isConnected) h.pfChartPaint(this.ch, a[0], a[1], a[2]);
	},

	// The gaming class of one direction, as the shaper runs it.
	queuePanel: function(d, running, eff) {
		var view = this, L = view.lt, tc = L.tc, label = d === 'down' ? _('Download') : _('Upload');
		var td = tc ? (d === 'down' ? tc.ingress : tc.egress) : null;
		function panel(title, sub, rows, m) {
			return E('div', { 'class': 'qx-qp' }, [
				E('div', { 'class': 'qx-label' }, label),
				E('div', { 'class': 'qx-qp-title' }, title),
				sub ? E('div', { 'class': 'qx-sub' }, sub) : '',
				m || '',
				E('div', { 'class': 'qx-qp-rows' }, [].concat.apply([], rows.map(function(x) {
					return [ E('div', {}, x[0]), E('div', {}, x[1]) ];
				})))
			]);
		}
		function quiet(t) { return panel(E('span', { 'class': 'qos-ex-muted' }, t), '', []); }
		if (!running) return quiet(_('shaper off'));
		if (eff === '0') return quiet(_('not shaped'));
		var S = L.S[d] || [], a = 0, k = 0;
		S.forEach(function(s) { if (s.dl != null) { a += s.dl; k++; } });
		var avg = k ? a / k : null;
		var cake = h.cakeOf(td && td.qdisc);
		if (cake) {
			var names = h.cakeTins(cake.options && cake.options.diffserv), i = names.indexOf('Voice');
			if (i < 0) i = names.length - 1;
			var t = (cake.tins || [])[i];
			if (!t) return quiet(_('measuring…'));
			var tgt = +t.target_us || 0, av = +t.avg_delay_us || 0, fr = tgt ? av / tgt : 0;
			return panel('CAKE · ' + names[i] + ' ' + _('tin'),
				_('EF lands here · threshold %s').format(rShort((+t.threshold_rate || 0) * 8)), [
				[ _('Avg delay'), fmtUs(av) + ' / ' + _('target') + ' ' + fmtUs(tgt) ],
				[ _('Peak · sparse'), fmtUs(t.peak_delay_us) + ' · ' + fmtUs(t.base_delay_us) ],
				[ _('Drops · ECN'), (t.drops | 0) + ' · ' + (t.ecn_mark | 0) ],
				[ _('Flows'), _('%d sparse · %d bulk').format(t.sparse_flows | 0, t.bulk_flows | 0) ],
				[ _('Sent'), h.fmtBytes(t.sent_bytes) + ' · ' + (t.sent_packets | 0) + ' ' + _('pkts') ]
			], meter(fr, fr < 0.5 ? 'good' : fr < 1 ? 'ok' : 'poor'));
		}
		var p = h.parseTcText(td && td.text), cls = p['class'].filter(function(x) { return x.handle === '1:10'; })[0];
		if (!cls) return quiet(p['class'].length ? _('no gaming class (1:10)') : _('measuring…'));
		var q = p.qdisc.filter(function(x) { return x.handle === cls.leaf || x.parent === '1:10'; })[0] || {};
		var htb = cls.kind === 'htb', rows = [], lim = q.limit_p ? q.limit_p + ' ' + _('pkts') : q.limit_b ? h.fmtBytes(q.limit_b) : '';
		var fr2 = q.limit_p ? (q.qlen || 0) / q.limit_p : q.limit_b ? (q.backlog || 0) / q.limit_b : 0;
		rows.push([ _('Queue'), (q.qlen | 0) + ' ' + _('pkts') + ' · ' + h.fmtBytes(q.backlog) + (lim ? ' / ' + lim : '') ]);
		rows.push([ _('Delay'), fmtMs(avg) + ' · ' + _('%d min avg').format(WIN / 60) ]);
		if (htb) rows.push([ _('Lended · borrowed'), (cls.lended | 0) + ' · ' + (cls.borrowed | 0) ]);
		else if (cls.work > 0) rows.push([ _('Real-time share'), Math.round((cls.rtwork || 0) * 100 / cls.work) + '% ' + _('sent') ]);
		rows.push([ _('Drops · overlimits'), ((q.dropped != null ? q.dropped : cls.dropped) | 0) + ' · ' + ((q.overlimits != null ? q.overlimits : cls.overlimits) | 0) ]);
		rows.push([ _('Sent'), h.fmtBytes(q.sent_bytes != null ? q.sent_bytes : cls.sent_bytes) + ' · ' +
			((q.sent_pkts != null ? q.sent_pkts : cls.sent_pkts) | 0) + ' ' + _('pkts') ]);
		var rt = cls.sc && cls.sc.rt;
		var sub = htb ? _('rate %s · prio 0').format(rShort(cls.rate))
			: rt ? _('real-time %s').format(rShort(rt.m2)) + (rt.m1 ? ' · ' + _('burst %s / %s').format(rShort(rt.m1), rt.d) : '') : '';
		return panel((htb ? 'HTB' : 'HFSC') + ' 1:10 · ' + (q.kind || '?'), sub, rows,
			meter(fr2, fr2 < 0.5 ? 'good' : fr2 < 0.9 ? 'ok' : 'poor'));
	},

	paint: function() {
		// The poll is reading the config again: its own paint, at its end,
		// draws (this one would show the cards' empty states for a moment).
		if (h.uciBusy()) return;
		var view = this, b = view.boxes, tv = view.tv;
		var st = h.parseState(view.stOut).state, fu = view.full || {};
		var enabled = (st.enabled || uci.get('qos-ex', 'settings', 'enabled') || '0') === '1';
		var running = h.running(st);
		var j = view.pf || {};
		var pfOn = j.enabled === 1 || j.enabled === '1';
		var act = (pfOn && running) ? (j.activity || 'idle') : 'off';
		var cnt = h.pfCounts(j);

		// ---- Installed copy out of date (every control is affected). -----
		var staleWho = [];
		if (st.backend_stale === '1') staleWho.push([ '/root/QoS-Ex.sh', '/usr/sbin/qos-ex.sh' ]);
		if (st.pf_stale      === '1') staleWho.push([ '/root/QoS-Ex-PF.sh', '/usr/sbin/qos-ex-pf.sh' ]);
		fill(b.stale, JSON.stringify(staleWho), function() { return staleWho.length ? E('div', { 'class': 'cbi-section qos-ex-card qx-alert' }, [
			E('h3', { 'class': 'qos-ex-card-title' }, _('Installed copy is out of date')),
			E('div', {}, staleWho.map(function(w) {
				return E('div', {}, [ E('code', {}, [ w[0] ]), ' ≠ ', E('code', {}, [ w[1] ]), ' — ',
					_('update from System → Maintenance') ]);
			}))
		]) : []; });

		// ---- Needs attention: only when a check fails or a warning holds. -
		var warns = [];
		if (fu.wan_match === '0')
			warns.push([ _('WAN mismatch: set '), E('code', {}, [ fu.wan || '?' ]),
				_(', line is on '), E('code', {}, [ fu.wan_live || '?' ]) ]);
		if (fu.offload_sw === '1' || fu.offload_hw === '1')
			warns.push([ _('Flow offloading is on — classification bypassed. '),
				h.go([ 'system', 'maintenance' ], _('Turn it off')) ]);
		if (fu.ct_acct === '0')
			warns.push([ E('code', {}, 'nf_conntrack_acct'), _(' is off — restart the shaper') ]);
		if (view.hwChanged)
			warns.push([ _('These settings were made on other hardware. '), h.go([ 'system', 'maintenance' ], _('Run Auto Setup')) ]);
		var bad = !enabled ? [] : CHECKS.filter(function(c) { return !h.compOff(st, c[0]) && st[c[0]] !== '1'; });
		fill(b.alert, JSON.stringify([ bad.map(function(c) { return c[0]; }), fu.wan_match, fu.wan, fu.wan_live,
			fu.offload_sw, fu.offload_hw, fu.ct_acct, !!view.hwChanged ]), function() {
			if (!bad.length && !warns.length) return [];
			return E('div', { 'class': 'cbi-section qos-ex-card qx-alert' }, [
				E('h3', { 'class': 'qos-ex-card-title' }, [ _('Needs attention'),
					E('span', { 'class': 'qos-ex-tools' }, h.go([ 'system', 'status' ], _('Status'))) ]),
				bad.length ? E('div', { 'class': 'qos-ex-checks' }, bad.map(function(c) {
					return E('div', { 'class': 'qos-ex-check bad' }, [ E('span', { 'class': 'dot' }), c[1] ]);
				})) : '',
				E('div', {}, warns.map(function(w) { return E('div', { 'class': 'qos-ex-warn-text qx-warn' }, w); }))
			]);
		});

		// ---- Get started: until the shaper is on and a device is picked. --
		var nGame = listCount(uci.get('qos-ex', 'ips', 'gaming_mac')) +
			listCount(uci.get('qos-ex', 'ips', 'gaming_ipv4')) + listCount(uci.get('qos-ex', 'ips', 'gaming_ipv6'));
		var haveHome = !!(uci.get('qos-ex', 'pingfilter', 'home_lat') && uci.get('qos-ex', 'pingfilter', 'home_lon'));
		var todo = [
			[ enabled, _('Set your line speeds, then turn the shaper on'), [ 'setup', '#line' ] ],
			[ nGame > 0, _('Pick your console or gaming PC'), [ 'setup', '#dev' ] ],
			[ haveHome, _('Optional: set your home on the map for the Ping Filter'), [ 'pingfilter', 'map' ] ]
		];
		// autosetup.done 0 (a fresh install, a reset, Maintenance -> Run Auto
		// Setup): the Auto Setup tab does the setup; this card points there.
		var asNew = uci.get('qos-ex', 'autosetup', 'done') === '0';
		fill(b.setup, asNew ? 'auto' : JSON.stringify(todo.map(function(t) { return t[0]; })), function() {
			if (asNew) return E('div', { 'class': 'cbi-section qos-ex-card qx-pfoff' }, [
				E('div', { 'class': 'qx-ctl-row' }, [
					E('div', { 'class': 'qx-ctl-txt' }, [
						E('div', { 'class': 'qx-now-title' }, _('Set up QoS-Ex')),
						E('div', { 'class': 'qx-sub' }, _('Auto Setup tests the line and suggests the settings.')) ]),
					E('a', { 'class': 'btn cbi-button cbi-button-action', 'href': h.tabUrl([ 'autosetup' ]) }, _('Auto Setup')) ]) ]);
			if (todo[0][0] && todo[1][0]) return [];
			return E('div', { 'class': 'cbi-section qos-ex-card qx-setup' }, [
				E('h3', { 'class': 'qos-ex-card-title' }, _('Get started')),
				E('ol', {}, todo.map(function(t) {
					return E('li', { 'class': t[0] ? 'done' : '' }, E('a', { 'href': h.tabUrl(t[2]) }, t[1]));
				}))
			]);
		});

		// ---- Now playing: the server the Dashboard shows (h.liveIp, the
		// shared picker with its hysteresis), scored and graded the same way,
		// with a small version of the Dashboard's chart.
		var liveIp = pfOn ? h.liveIp(view, j.servers || [], j.active_pps) : null;
		var lv = liveIp ? (j.servers || []).filter(function(r) { return r.ip === liveIp; })[0] : null;
		view.liveIp = lv ? lv.ip : null;
		var sc = lv ? h.score(lv) : -1, band = h.scoreBand(sc) || 'none';
		var tele = (lv && view.tele && view.tele.ip === lv.ip) ? view.tele : null;
		var spk = tele ? (tele.samples || []).length + ':' + ((tele.samples || []).slice(-1)[0] || {}).ts : '';
		// The chart's base: the last in-play reading (lv) when there is one.
		view.chArgs = lv ? [ tele, lv.lv > 0 ? lv.lv : lv.ping, pfLimit(j) ] : null;
		b.now.classList.toggle('playing', !!lv);
		fill(b.now, JSON.stringify([ pfOn, act, lv ? [ lv.ip, lv.city, lv.country, lv.ping, lv.ping_source, lv.jitter,
			lv.pps, lv.state, sc, lv.km, lv.gname ] : null, cnt.live, spk ]), function() {
			var hd = E('div', { 'class': 'qx-label' }, [ lv ? E('span', { 'class': 'pf-badge-connected pf-live' }) : '',
				_('Now playing'), E('span', { 'class': 'qx-right' }, h.go([ 'pingfilter', 'map' ], _('Map'))) ]);
			if (!pfOn) return [ hd, E('div', { 'class': 'qx-now-empty' }, [
				E('div', { 'class': 'qx-now-title' }, _('Ping Filter is off')),
				E('div', { 'class': 'qx-sub' }, _('Turn it on to see your game server and block bad ones.')) ]) ];
			if (!lv) return [ hd, E('div', { 'class': 'qx-now-empty' }, [
				E('div', { 'class': 'qx-now-title' }, act === 'matchmaking' ? _('Matchmaking…') : _('Waiting for a match')),
				E('div', { 'class': 'qx-sub' }, cnt.live
					? _('%d server(s) graded this session.').format(cnt.live)
					: _('Start a game: its server shows here.')) ]) ];
			var where = [ lv.city, lv.country ].filter(Boolean).join(', ') || _('Unknown location');
			if (lv.gname) where = lv.gname + ' \u00b7 ' + where;
			var ok = /^(allowed|whitelist)$/.test(lv.state);
			var meas = /^(real|icmp)$/.test(lv.ping_source || '');
			function stat(v, k) { return E('span', {}, [ E('b', {}, v), ' ', E('span', { 'class': 'qos-ex-muted' }, k) ]); }
			return [ hd,
				E('div', { 'class': 'qx-now-main' }, [
					E('div', { 'class': 'qx-grade ' + band, 'title': _('Score %s').format(h.scoreTxt(sc)) }, h.grade(sc)),
					E('div', { 'class': 'qx-now-where' }, [
						E('div', { 'class': 'qx-now-title' }, [ where ]),
						E('div', { 'class': 'qx-sub' }, [ E('code', {}, [ lv.ip ]), ' ',
							E('span', { 'class': 'label pf-pill ' + (ok ? 'on' : 'off') }, [ lv.state || '?' ]) ]) ]),
					E('div', { 'class': 'qx-now-ping' }, [
						E('div', { 'class': 'qx-big ' + band }, lv.ping > 0 ? [ String(lv.ping), E('small', {}, ' ms') ] : '—'),
						E('div', { 'class': 'qx-sub' }, meas ? _('measured') : _('estimate')) ])
				]),
				view.ch.node,
				E('div', { 'class': 'qx-nowstats' }, [
					stat(lv.ping > 0 ? lv.ping + ' ms' : '—', _('ping') + ' · ' + (!meas ? 'est' : lv.ping_source === 'real' ? 'handshake' : 'icmp')),
					stat('±' + (lv.jitter || 0) + ' ms', _('jitter')),
					stat(String(lv.pps | 0), _('pps')),
					stat(h.grade(sc) + (sc >= 0 ? ' · ' + sc : ''), _('grade')),
					E('span', { 'class': 'qx-nowkey' }, [
						E('i', { 'style': 'background:' + h.PFC.lat }), _('latency'),
						E('i', { 'style': 'background:' + h.PFC.jit }), _('jitter'),
						E('i', { 'style': 'background:' + h.PFC.pps }), _('pps') ])
				])
			];
		});
		view.drawChart();

		// ---- Controls --------------------------------------------------
		var qd = String(h.qdiscDisplay(h.qdiscCfg())).toUpperCase(), nm = h.nftModeDisplay(uci.get('qos-ex', 'settings', 'nft_mode') || st.nft_mode || 'adaptive');
		var dlEff = st.dl_kbps_eff || '', ulEff = st.ul_kbps_eff || '', sr = h.shapedRates();
		function rate(eff, cfg) { return eff === '0' ? _('unshaped') : h.fmtMbps(eff || cfg) + ''; }
		h.setText(view.cq.sub, qd + ' · ' + nm);
		view.cq.stat.className = 'qx-ctl-stat ' + (running ? 'on' : enabled ? 'warn' : 'off');
		h.setText(view.cq.stat, running ? '● ' + _('Running') + (st.uptime_s ? ' · ' + h.fmtUptime(st.uptime_s) : '') +
				' · ↓ ' + rate(dlEff, sr.dn) + ' ↑ ' + rate(ulEff, sr.up) + ' Mbps'
			: enabled ? '● ' + _('On, but not running — Restart') : '○ ' + _('Off'));
		view.cq.btns.hidden = !enabled;
		view.swQ.qxSet(enabled, false);

		var devs = h.pfDevIps();
		var ready = devs.length > 0 && haveHome;
		h.setText(view.cp.sub, pfProfile(j));
		view.cp.stat.className = 'qx-ctl-stat ' + (!pfOn ? 'off' : !running ? 'warn' : act === 'active' ? 'play' : 'on');
		h.setText(view.cp.stat, !pfOn ? (ready ? '○ ' + _('Off')
				: '○ ' + _('Off — needs %s first').format(!devs.length && !haveHome ? _('a gaming device and your home')
					: !devs.length ? _('a gaming device') : _('your home')))
			: !running ? '● ' + _('Armed — runs when the shaper is on')
			: act === 'active' ? '⦿ ' + _('In match') : act === 'matchmaking' ? '⦾ ' + _('Matchmaking') : '● ' + _('Watching'));
		view.swP.qxSet(pfOn, !ready, ready ? '' : _('Set a gaming device and your home first: Ping Filter → Dashboard'));

		// ---- Live tiles: the line, and the EF game flows over the window.
		var LT = view.lt;
		[ [ 'down', 'dn', 'dl_kbps', dlEff ], [ 'up', 'up', 'ul_kbps', ulEff ] ].forEach(function(p) {
			var S = LT.S[p[0]], s = S[S.length - 1], sh = (+LT.meta[p[2]] || 0) * 1000;
			h.setText(tv[p[1]], s ? h.fmtRate(s.r) : '—');
			h.setText(tv[p[1] + 's'], !running ? _('shaper off') : p[3] === '0' ? _('not shaped')
				: sh ? _('of %s Mbps').format(h.fmtMbps(sh / 1000)) : '');
			view.gq[p[1]].set(s && sh ? s.r / sh : 0);
		});
		var G = LT.G, gl = G[G.length - 1];
		h.setText(tv.gm, gl ? h.fmtRate(gl.dn + gl.up) : '—');
		h.setText(tv.gms, !running ? _('shaper off') : !gl ? _('measuring…')
			: '↓ ' + h.fmtRate(gl.dn) + ' · ↑ ' + h.fmtRate(gl.up) + ' · EF');
		var gsig = G.length + ':' + (gl ? gl.t : 0);
		if (tv.gmm.__sig !== gsig) { tv.gmm.__sig = gsig; dom.content(tv.gmm, rateSpark(G)); }

		// ---- Game stream: EF-marked UDP flows (the Flows rows, no detail).
		var gset = {};
		[].concat(uci.get('qos-ex', 'ips', 'gaming_ipv4') || [], uci.get('qos-ex', 'ips', 'gaming_ipv6') || [])
			.forEach(function(x) { x = String(x || '').trim().toLowerCase(); if (x) gset[x] = true; });
		[].concat(uci.get('qos-ex', 'ips', 'gaming_mac') || []).forEach(function(m) {
			(view.macMap[String(m || '').toLowerCase()] || []).forEach(function(ip) { gset[String(ip).toLowerCase()] = true; });
		});
		var pfm = {};
		(j.servers || []).forEach(function(s) { if (s && s.ip) pfm[s.ip] = s; });
		var C = view.ct, frows = (C.rows || []).slice(0, FLOW_MAX);
		fill(b.flows, JSON.stringify([ running, C.n | 0, frows.map(function(r) {
			var s = pfm[r.dst] || pfm[r.src];
			return [ r.key, r.upPps, r.dnPps, r.upBps, r.dnBps, s ? s.state + s.ping : '' ];
		}), Object.keys(gset).length ]), function() {
			var title = E('h3', { 'class': 'qos-ex-card-title' }, [ _('Gaming flow'),
				E('span', { 'class': 'qos-ex-tools' }, h.go([ 'live', 'flows' ], _('Flows'))) ]);
			if (!frows.length) return [ title, E('div', { 'class': 'qx-sub qx-gflow-empty' },
				!running ? _('Shaper off — the game stream shows here while it runs.')
				: (C.n | 0) < 2 ? _('Measuring…')
				: _('No game traffic right now; it shows once a gaming device plays.')) ];
			// data-title: the theme's phone layout labels each stacked cell.
			function td(i, v) { return E('td', { 'class': 'td' + (FCOLS[i][1] ? ' right' : ''), 'data-title': FCOLS[i][0] }, [ v ]); }
			return [ title, E('div', { 'class': 'qx-hscroll' }, E('table', { 'class': 'table qos-ex-conn' }, [
				E('tr', { 'class': 'tr table-titles' }, FCOLS.map(function(c) {
					return E('th', { 'class': 'th' + (c[1] ? ' right' : ''), 'style': 'width:' + c[2] }, c[0]);
				}))
			].concat(frows.map(function(r) {
				var game = !!(gset[r.src.toLowerCase()] || gset[(r.rsrc || '').toLowerCase()]);
				var s = pfm[r.dst] || pfm[r.src], ping = s ? (s.ping | 0) : 0;
				return E('tr', { 'class': 'tr flow' }, [
					E('td', { 'class': 'td', 'title': '1:10', 'data-title': FCOLS[0][0] }, [
						E('i', { 'class': 'sw', 'style': 'background:' + h.classColor('Gaming') }), 'Gaming', E('br'),
						E('code', {}, [ r.dscp ]) ]),
					td(1, (r.proto || '') + (r.fam === 'ipv6' ? ' v6' : '')),
					E('td', { 'class': 'td qos-ex-ip', 'title': r.src, 'data-title': FCOLS[2][0] }, [ r.src, game ? E('br') : '',
						game ? E('span', { 'class': 'label notice', 'title': _('configured gaming device') }, [ 'GAME' ]) : '' ]),
					td(3, r.sport),
					E('td', { 'class': 'td qos-ex-ip', 'title': r.dst, 'data-title': FCOLS[4][0] }, [ r.dst, s ? E('br') : '',
						s ? E('span', { 'class': 'label pf-badge ' + s.state, 'title': 'Ping Filter: ' + s.state },
							[ ping > 0 ? ping + ' ms' : String(s.state) ]) : '',
						s && s.country ? ' ' + s.country : '' ]),
					td(5, r.dport),
					td(6, updn(r.upBps, r.dnBps, fmtBits)),
					td(7, updn(r.upPps, r.dnPps)),
					td(8, updn(r.upBytes, r.dnBytes, h.fmtBytes))
				]);
			})))) ];
		});

		// ---- Gaming queue: the gaming class as the shaper runs it. -------
		var qsig = [ running, dlEff, ulEff, LT.tc ? JSON.stringify([ LT.tc.ingress, LT.tc.egress ]).length + ':' + (LT.prev ? LT.prev.t : 0) : '' ];
		fill(b.queue, JSON.stringify(qsig), function() {
			return [ E('h3', { 'class': 'qos-ex-card-title' }, [ _('Gaming queue'),
					E('span', { 'class': 'qos-ex-tools' }, h.go([ 'live', 'stats' ], _('Stats'))) ]),
				E('div', { 'class': 'qx-q' }, [ view.queuePanel('down', running, dlEff), view.queuePanel('up', running, ulEff) ]) ];
		});

		// ---- At a glance: one line per area, linking to where it is set. -
		// [ key, label ]: key = the MAC or address as the shaper's
		// gaming_online lists it (lower case).
		var gamers = [].concat(uci.get('qos-ex', 'ips', 'gaming_mac') || []).filter(function(m) { return String(m || '').trim(); })
			.map(function(m) { m = String(m).toLowerCase(); return [ m, view.names[m] || ((view.macMap[m] || [])[0]) || m ]; })
			.concat([].concat(uci.get('qos-ex', 'ips', 'gaming_ipv4') || [], uci.get('qos-ex', 'ips', 'gaming_ipv6') || [])
				.filter(function(x) { return String(x || '').trim(); }).map(function(x) { return [ String(x).toLowerCase(), String(x) ]; }));
		// Green = the router hears the device now, red = it does not. No
		// dots from a shaper without the key.
		var online = st.gaming_online != null ? String(st.gaming_online).split(/\s+/) : null;
		function gamerCell(g, i) {
			var on = online && online.indexOf(g[0]) >= 0;
			return [ i ? ' · ' : '', online ? E('span', { 'class': 'qx-dev-dot ' + (on ? 'on' : 'off'),
				'title': on ? _('online') : _('not heard from lately') }) : '', g[1] ];
		}
		var wl = listCount(uci.get('qos-ex', 'pingfilter', 'whitelist')), bl = listCount(uci.get('qos-ex', 'pingfilter', 'blacklist'));
		// value is passed as children, never as a string: E(tag, attrs,
		// string) is innerHTML, and the gaming list holds UCI values.
		function row(label, value, path, link) {
			return [ E('div', { 'class': 'qx-label' }, label),
				E('div', {}, Array.isArray(value) ? value : [ value ]), E('div', {}, h.go(path, link)) ];
		}
		fill(b.glance, JSON.stringify([ gamers, online, pfOn, pfProfile(j), haveHome, wl, bl, cnt.allowed, cnt.blocked ]), function() {
			return E('div', { 'class': 'qx-rows' }, [].concat(
				row(_('Gaming devices'), gamers.length ? [].concat.apply([], gamers.map(gamerCell))
					: E('span', { 'class': 'qos-ex-warn-text' }, _('none picked yet')), [ 'setup', '#dev' ], _('Devices')),
				row(_('Ping Filter'), [ pfOn ? pfProfile(j) + ' · ' + _('%d allowed / %d blocked').format(cnt.allowed, cnt.blocked)
						: E('span', { 'class': 'qos-ex-muted' }, _('off')),
					E('span', { 'class': 'qos-ex-muted' }, ' · ' + (haveHome ? _('home set') : _('no home set')) +
						' · ' + _('%d always allowed, %d always blocked').format(wl, bl)) ], [ 'pingfilter', 'settings' ], _('Settings'))
			));
		});

		// ---- Health and updates: their own card, at the bottom. ----------
		var upd = view.upd || null, updNew = upd ? h.updNewer(upd, {
			shaper: st.version || '', luci: '__VERSION__'.replace(/^v/, ''), pf: view.pfV || '' }) : [];
		var updKey = upd && upd.off ? 'off' : !upd || upd.error || !upd.checked ? 'none' : updNew.join(',') || 'ok';
		var nBad = bad.length + warns.length;
		fill(b.health, JSON.stringify([ updKey, nBad, enabled ]), function() {
			var updVal = updKey === 'ok' ? E('span', { 'class': 'qos-ex-ok' }, '✔ ' + _('up to date'))
				: updKey === 'none' ? E('span', { 'class': 'qos-ex-muted' }, _('not checked'))
				: updKey === 'off' ? E('span', { 'class': 'qos-ex-muted' }, _('automatic check off'))
				: E('span', { 'class': 'qos-ex-warn-text' }, '⬆ ' + _('update available'));
			return [ E('h3', { 'class': 'qos-ex-card-title' }, _('Health & updates')),
				E('div', { 'class': 'qx-rows' }, [].concat(
					row(_('Health'), !enabled ? E('span', { 'class': 'qos-ex-muted' }, _('shaper off'))
						: nBad ? E('span', { 'class': 'qos-ex-err' }, _('%d issue(s)').format(nBad))
						: E('span', { 'class': 'qos-ex-ok' }, '✔ ' + _('all checks passed')), [ 'system', 'status' ], _('Status')),
					row(_('Updates'), updVal, [ 'system', 'maintenance' ], updNew.length ? _('Update') : _('Maintenance'))
				)) ];
		});
	},

	handleSave:      null,
	handleSaveApply: null,
	handleReset:     null
});
