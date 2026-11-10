'use strict';
'require view';
'require uci';
'require view.qos-ex._helpers as h';

// Flows (Network > QoS-Ex > Live > Flows): the connection table, live. One
// row per flow (class and DSCP, addresses, rate, packets/s, totals), grouped
// by LAN device with gaming devices open, a class strip that filters, search
// and sort, and a detail row per flow: NAT, conntrack state, why it is in its
// class, its Ping Filter verdict and its rate trend.

// The shown rate averages the last HISTORY samples: long enough to stop
// flickering, short enough that a flow going idle shows up quickly. TREND
// samples are kept per flow for the trend line in the detail row.
var HISTORY = 10, TREND = 30;

// Polls between Ping Filter server-list refreshes (a fork of the PF script).
var PF_EVERY = 10;

// Row cap sent to the backend. The shaper sorts by cumulative packets before
// truncating, so a lower cap still keeps the busiest flows -- it is a cost
// control, not a filter.
var CAP_DEFAULT = 200;

// Flows with this many packets or fewer are not listed (a lone SYN, a DNS
// query and its answer, a probe): they are what fills the table with zeros.
// Cumulative packets only climb, so a flow crosses once and stays listed.
var MIN_PKTS = 2;

function avgOf(a) {
	if (!a || !a.length) return 0;
	var t = 0, n = Math.min(a.length, HISTORY);
	for (var i = a.length - n; i < a.length; i++) t += a[i];
	return Math.round(t / n);
}

// Two stacked figures in one cell: upload over download. Anything zero is
// muted so a one-directional flow reads at a glance.
function updn(up, dn, fmt) {
	var f = fmt || String;
	return E('div', {}, [
		E('span', { 'class': up ? '' : 'qos-ex-muted' }, '↑ ' + f(up)),
		E('br'),
		E('span', { 'class': dn ? '' : 'qos-ex-muted' }, '↓ ' + f(dn))
	]);
}

// Rates are kept in bytes/s; shown in bits like the Stats tab.
function fmtBits(n) { return n ? h.fmtRate(n * 8) : '0'; }

// The codepoints QoS-Ex's priomap maps to a class (DSCP_SPEC in QoS-Ex.sh,
// which nft_dscp_map() builds @priomap from), in priority order. The backend
// already resolves the connmark to one of these names. Under CAKE these are
// still the markings the classifier writes; CAKE just tins them differently.
var CLASSES = [
	[ 'Gaming',  '1:10', [ 'ef' ] ],
	[ 'Voice',   '1:11', [ 'cs5', 'cs4' ] ],
	[ 'Video',   '1:12', [ 'af41', 'af42' ] ],
	[ 'Default', '1:13', [ 'cs0' ] ],
	[ 'Low',     '1:14', [ 'af11', 'cs1' ] ],
	[ 'Bulk',    '1:15', [ 'le' ] ]
];
var DSCP_CLS = {}, CLS_RANK = {}, CLS_LEAF = {};
CLASSES.forEach(function(c, i) {
	CLS_RANK[c[0]] = i; CLS_LEAF[c[0]] = c[1];
	c[2].forEach(function(d) { DSCP_CLS[d] = c[0]; });
});

function sw(nm) { return E('i', { 'class': 'sw', 'style': 'background:' + h.classColor(nm) }); }

function svgEl(name, attrs) {
	var el = document.createElementNS('http://www.w3.org/2000/svg', name);
	for (var k in attrs) el.setAttribute(k, attrs[k]);
	return el;
}

// Rate trend of one flow (both directions summed) over the kept samples.
function trend(hs, col) {
	var W = 220, H = 30, n = hs.ub.length, v = [], mx = 0, pts = [], i;
	for (i = 0; i < n; i++) { v.push(hs.ub[i] + hs.db[i]); if (v[i] > mx) mx = v[i]; }
	for (i = 0; i < n; i++)
		pts.push((n > 1 ? W * i / (n - 1) : 0).toFixed(1) + ',' +
			(H - 1 - (H - 4) * (mx > 0 ? v[i] / mx : 0)).toFixed(1));
	if (n < 2) pts = [ '0,' + (H - 1), W + ',' + (H - 1) ];
	var svg = svgEl('svg', { 'class': 'qos-ex-conn-spark', 'viewBox': '0 0 ' + W + ' ' + H });
	svg.appendChild(svgEl('polygon', { 'points': pts[0].split(',')[0] + ',' + (H - 1) + ' ' + pts.join(' ') +
		' ' + W + ',' + (H - 1), 'fill': col }));
	svg.appendChild(svgEl('polyline', { 'points': pts.join(' '), 'stroke': col }));
	return { svg: svg, peak: mx };
}

// Host hints (luci-rpc) -> address -> device. One device per MAC, so a
// host's IPv4 and IPv6 flows land in the same group.
function hostMap(hints) {
	var m = {};
	Object.keys(hints || {}).forEach(function(mac) {
		var x = hints[mac];
		if (!x || typeof x !== 'object') return;
		var v4 = [].concat(x.ipaddrs || x.ipv4 || []), v6 = [].concat(x.ip6addrs || x.ipv6 || []);
		var d = { key: mac, name: String(x.name || v4[0] || v6[0] || mac), ip: String(v4[0] || v6[0] || '') };
		v4.concat(v6).forEach(function(ip) { m[String(ip).toLowerCase()] = d; });
	});
	return m;
}
var OTHER = { key: '', name: _('Other'), ip: '' };

function fmtSecs(s) {
	if (s >= 86400) return (s / 86400).toFixed(1) + ' d';
	if (s >= 3600) return (s / 3600).toFixed(1) + ' h';
	return s >= 60 ? Math.round(s / 60) + ' min' : s + ' s';
}
function addr(ip, port) { return (ip.indexOf(':') >= 0 ? '[' + ip + ']' : ip) + ':' + port; }

// Table columns: [ sort key, title, right-aligned, width ]. Fixed widths
// (table-layout: fixed) so a long IPv6 address or a big counter never shifts
// the columns; source and destination are clipped with an ellipsis, full
// value in the tooltip.
var COLS = [
	[ 'rank', _('Class'), 0, '13ch' ], [ 'proto', _('Proto'), 0, '7ch' ],
	[ 'src', _('Source'), 0, '15ch' ], [ 'sport', _('Sport'), 1, '7ch' ],
	[ 'dst', _('Destination'), 0, '15ch' ], [ 'dport', _('Dport'), 1, '7ch' ],
	[ 'avgBps', _('Rate'), 1, '14ch' ], [ 'avgPps', _('pps'), 1, '8ch' ],
	[ 'bytes', _('Total'), 1, '12ch' ]
];

// One request at a time, the next scheduled only when this one has
// answered. The gap is the refresh selector's, as on Stats; 0 = paused.
// It starts at 1 s, or the one picked before (h.liveRate, kept in this
// browser).
var RATES = [ [ 1, _('1s') ], [ 2, _('2s') ], [ 5, _('5s') ], [ 10, _('10s') ], [ 0, _('pause') ] ];

// Search, class filter, sort, row cap, grouping and open groups survive a
// tab change (this browser tab only). Storage can throw; a miss is simply
// the defaults.
var KEEP = 'qosex:conn';
function keepGet() {
	try { return JSON.parse(window.sessionStorage.getItem(KEEP) || '{}') || {}; } catch (e) { return {}; }
}
function keepPut(o) {
	try { window.sessionStorage.setItem(KEEP, JSON.stringify(o)); } catch (e) {}
}

return view.extend({
	rows: [], prev: {}, prevTs: 0,
	hist: {}, gaming: {},
	cap: CAP_DEFAULT, running: true, pollSec: 1, timer: null,
	// Cumulative bytes change slowly, so this default order is steady.
	sortCol: 'bytes', sortDesc: true, cls: '',
	// Grouped by LAN device; a group is open when its entry says so, else
	// when it is a gaming device. One flow at a time shows its detail row,
	// and only once clicked.
	grp: true, open: {}, exp: null,
	hosts: {}, adhoc: {}, pf: {}, polls: 0,

	load: function() {
		var k = keepGet(), n = parseInt(k.cap, 10);
		if (n >= 1) this.cap = n;
		if (k.col) { this.sortCol = k.col; this.sortDesc = k.desc !== false; }
		if (CLS_RANK[k.cls] != null) this.cls = k.cls;
		this.q0 = typeof k.q === 'string' ? k.q : '';
		if (k.grp === false) this.grp = false;
		if (k.open && typeof k.open === 'object') this.open = k.open;
		var view = this;
		return Promise.all([
			h.rpcSafe(h.callConntrack(this.cap)),
			uci.load('qos-ex').catch(function() { return null; }),
			h.callHostHints().catch(function() { return {}; })
		]).then(function(r) {
			// After the config: the router's default refresh is in it.
			view.pollSec = h.liveRate('flows');
			view.running = view.pollSec > 0;
			return r;
		});
	},

	keep: function() {
		keepPut({ q: this.search.value, cls: this.cls, col: this.sortCol, desc: this.sortDesc, cap: this.cap,
			grp: this.grp, open: this.open });
	},

	// The LAN device a flow belongs to: the side that opened it, or for a
	// port forward the host it lands on. Anything else (the router's own
	// flows, an address with no host entry) is "Other".
	devOf: function(r) {
		var d = this.hosts[r.src] || this.hosts[r.rsrc];
		if (d) return d;
		var ip = h.isLan(r.src) ? r.src : (h.isLan(r.rsrc) ? r.rsrc : '');
		return ip ? (this.adhoc[ip] || (this.adhoc[ip] = { key: ip, name: ip, ip: ip })) : OTHER;
	},

	// Ping Filter verdicts for the destination column. Fetched after the
	// page is up (never in load(): it forks the PF script) and then every
	// PF_EVERY polls, only while Ping Filter is on.
	pfLoad: function() {
		var view = this;
		if (uci.get('qos-ex', 'pingfilter', 'enabled') !== '1') return;
		h.callPfServers().then(function(j) {
			var m = {};
			((j && j.servers) || []).forEach(function(s) { if (s && s.ip) m[s.ip] = s; });
			view.pf = m;
			view.paint();
		}).catch(function() {});
	},

	render: function(loaded) {
		var view = this;
		view.hosts = hostMap(loaded[2]);
		view.rows = view.parse((loaded[0] && loaded[0].output) || '');
		view.udpFast = uci.get('qos-ex', 'advanced', 'udp_fast_pps') || '450';
		view.tcpSlow = uci.get('qos-ex', 'advanced', 'slow_flow_pps') || '150';
		view.adaptive = uci.get('qos-ex', 'settings', 'nft_mode') === 'adaptive';

		function setOf(v) {
			var s = {};
			[].concat(v || []).forEach(function(x) { x = String(x || '').trim(); if (x) s[x] = true; });
			return s;
		}
		// Gaming devices by address and by MAC (lower case; a host's group
		// key is its MAC, so a MAC device is matched through its host entry).
		view.gaming = {};
		[ 'gaming_ipv4', 'gaming_ipv6', 'gaming_mac' ].forEach(function(k) {
			Object.keys(setOf(uci.get('qos-ex', 'ips', k))).forEach(function(x) { view.gaming[x.toLowerCase()] = true; });
		});
		// A gaming device's group always opens with the page: a "closed"
		// remembered from an earlier visit is dropped.
		Object.keys(view.open).forEach(function(k) {
			if (view.gaming[String(k).toLowerCase()] && !view.open[k]) delete view.open[k];
		});

		view.search = E('input', { 'type': 'text', 'class': 'cbi-input-text qos-ex-conn-q',
			'placeholder': _('Search: IP, port, proto, DSCP…'),
			'input': function() { view.keep(); view.paint(); } });
		view.search.value = view.q0;

		var capSel = E('select', { 'class': 'cbi-input-select', 'title': _('Max rows'), 'change': function(ev) {
			view.cap = parseInt(ev.target.value, 10) || CAP_DEFAULT;
			view.keep();
			if (view.running) view.schedule(0);
		} }, [ 50, 100, 200, 500, 1000 ].map(function(n) { return E('option', { 'value': String(n) }, String(n)); }));
		capSel.value = String(view.cap);

		var rateSel = E('select', { 'class': 'cbi-input-select', 'change': function(ev) {
			view.pollSec = parseInt(ev.target.value, 10) || 0;
			view.running = view.pollSec > 0;
			h.liveRateSet('flows', view.pollSec);
			if (view.running) view.schedule(0); else { clearTimeout(view.timer); view.timer = null; }
			view.paint();
		} }, RATES.map(function(r) { return E('option', { 'value': String(r[0]) }, r[1]); }));
		rateSel.value = String(view.pollSec);
		var grpChk = E('input', { 'type': 'checkbox', 'change': function(ev) {
			view.grp = ev.target.checked; view.keep(); view.paint();
		} });
		grpChk.checked = view.grp;
		var resetBtn = E('button', { 'class': 'btn cbi-button cbi-button-reset', 'click': function() {
			view.search.value = ''; view.cls = '';
			view.grp = grpChk.checked = true; view.open = {}; view.exp = null;
			capSel.value = String(CAP_DEFAULT); view.cap = CAP_DEFAULT;
			view.sortCol = 'bytes'; view.sortDesc = true;
			view.keep(); view.paint();
		} }, _('Reset'));

		// Live figures for the banner, and this tab's controls.
		view.pills = E('span', { 'class': 'qos-ex-hdr-pills' });
		var head = h.pageHead(_('Flows'), 'none', { pills: view.pills, tools: [ view.search,
			E('label', { 'class': 'qos-ex-conn-tog' }, [ grpChk, ' ', _('By device') ]),
			capSel, E('label', { 'class': 'qos-ex-chart-rate' }, [ _('refresh '), rateSel ]), resetBtn ] });

		// Class strip: flows and rate per class; a click filters the table.
		// One delegated listener -- the chips themselves are morphed in place.
		view.chips = E('div', { 'class': 'qos-ex-chips', 'click': function(ev) {
			var c = ev.target.closest ? ev.target.closest('[data-cls]') : null;
			if (!c) return;
			var nm = c.getAttribute('data-cls');
			view.cls = (view.cls === nm) ? '' : nm;
			view.keep(); view.paint();
		} });

		// Stock LuCI table in a fixed scroll box (h.sboxTable): sticky
		// sortable header, rows brought up to date IN PLACE each sample
		// (h.morphKids), so the page and the box stay put.
		var sbt = h.sboxTable(null, 'table qos-ex-conn',
			E('tr', { 'class': 'tr table-titles' }, COLS.map(function(c) {
				return E('th', { 'class': 'th' + (c[2] ? ' right' : ''), 'style': 'width:' + c[3] }, [
					E('a', { 'href': '#', 'click': function(ev) {
						ev.preventDefault();
						if (view.sortCol === c[0]) view.sortDesc = !view.sortDesc;
						else { view.sortCol = c[0]; view.sortDesc = (c[0] !== 'rank'); }
						view.keep(); view.paint();
					} }, [ c[1], E('span', { 'class': 'qos-ex-sort-ind', 'data-col': c[0] }, '') ])
				]);
			})));
		view.head = sbt.head; view.tbody = sbt.body;

		// One delegated listener (rows are morphed, fresh ones carry none):
		// a device row opens or closes its flows, a flow row its detail.
		sbt.body.addEventListener('click', function(ev) {
			if (ev.target.closest('a') || String(window.getSelection() || '')) return;
			var tr = ev.target.closest('tr');
			if (!tr) return;
			if (tr.hasAttribute('data-dev')) view.open[tr.getAttribute('data-dev')] = !tr.classList.contains('open');
			else if (tr.hasAttribute('data-key'))
				view.exp = tr.classList.contains('exp') ? null : tr.getAttribute('data-key');
			else return;
			view.keep(); view.paint();
		});

		// The box fills the window from its top edge down (min 260px).
		// Sized on mount and on window resize only, never per refresh.
		var box = sbt.box, tries = 0;
		function fit() {
			if (!box.isConnected) {
				if (view.shown) window.removeEventListener('resize', fit);
				else if (++tries < 50) window.setTimeout(fit, 100);
				return;
			}
			view.shown = true;
			var ht = Math.max(260, Math.floor(window.innerHeight - box.getBoundingClientRect().top - window.scrollY - 16)) + 'px';
			if (box.style.height !== ht) box.style.height = ht;
		}
		fit();
		window.addEventListener('resize', fit);

		view.paint();
		view.schedule(view.pollSec * 1000);
		view.pfLoad();
		return E('div', {}, [ head, E('div', { 'class': 'cbi-section qos-ex-card' }, [ view.chips, sbt.node ]) ]);
	},

	// Next sample after `ms`. A hidden browser tab asks nothing and checks
	// again later; Pause stops the chain, and so does the page going: a
	// theme that swaps pages without a page load (footstrap) keeps timers.
	schedule: function(ms) {
		var view = this;
		clearTimeout(view.timer);
		view.timer = setTimeout(function() {
			if (!view.running) return;
			if (view.chips.isConnected) view.shown = true;
			else if (view.shown) return;
			if (document.hidden) return view.schedule(view.pollSec * 1000);
			h.callConntrack(view.cap).then(function(r) {
				view.rows = view.parse((r && r.output) || '');
				view.err = null;
				view.paint();
				if (++view.polls % PF_EVERY === 0) view.pfLoad();
			}).catch(function(e) {
				view.err = _('Could not read the connection table.');
				view.paint();
			}).then(function() {
				if (view.running) view.schedule(view.pollSec * 1000);
			});
		}, ms);
	},

	parse: function(text) {
		var rows = [], lines = (text || '').split(/\n/);
		var now = Date.now() / 1000;
		var elapsed = (this.prevTs && now > this.prevTs) ? (now - this.prevTs) : 0;
		var snap = {}, seen = {}, i;

		for (i = 0; i < lines.length; i++) {
			var r = h.ctRow(lines[i]);
			if (!r) continue;
			var key = r.fam + ':' + r.proto + ':' + r.src + '/' + r.sport +
			          '->' + r.dst + '/' + r.dport;
			seen[key] = true;

			var hs = this.hist[key];
			if (!hs) hs = this.hist[key] = { up: [], dn: [], ub: [], db: [] };

			var p = this.prev[key];
			if (elapsed > 0 && p) {
				// Counters only ever climb for a given conntrack entry, but
				// the key can be reused after an entry expires and a new flow
				// takes the same tuple, which shows up as a negative delta.
				// Clamp at zero rather than emit a nonsense spike.
				hs.up.push(Math.max(0, Math.round((r.upPkts  - p.up) / elapsed)));
				hs.dn.push(Math.max(0, Math.round((r.dnPkts  - p.dn) / elapsed)));
				hs.ub.push(Math.max(0, Math.round((r.upBytes - p.ub) / elapsed)));
				hs.db.push(Math.max(0, Math.round((r.dnBytes - p.db) / elapsed)));
				while (hs.up.length > TREND) {
					hs.up.shift(); hs.dn.shift(); hs.ub.shift(); hs.db.shift();
				}
			}

			r.avgUpPps = avgOf(hs.up); r.avgDnPps = avgOf(hs.dn);
			r.avgUpBps = avgOf(hs.ub); r.avgDnBps = avgOf(hs.db);
			r.avgPps = r.avgUpPps + r.avgDnPps;
			r.avgBps = r.avgUpBps + r.avgDnBps;
			// No rate and no packets/s to show: the flow is left out of the list.
			r.idle = !r.avgPps && !r.avgBps;
			r.cls  = DSCP_CLS[r.dscp] || '';
			r.rank = r.cls ? CLS_RANK[r.cls] : 99;
			r.key  = key;
			r.dev  = this.devOf(r);

			snap[key] = { up: r.upPkts, dn: r.dnPkts, ub: r.upBytes, db: r.dnBytes };
			rows.push(r);
		}

		// Prune history for flows that are gone, or the map grows for the
		// life of the page.
		for (var k in this.hist) if (!seen[k]) delete this.hist[k];

		this.prev = snap;
		this.prevTs = now;
		this.nSamp = (this.nSamp || 0) + 1;
		return rows;
	},

	// Filter, sort and bring pills, chips and table body up to date.
	paint: function() {
		var view = this, gaming = view.gaming || {};
		function isGame(r) {
			return !!(gaming[String(r.dev.key).toLowerCase()] || gaming[r.src.toLowerCase()] ||
				gaming[r.dst.toLowerCase()] || gaming[r.rsrc.toLowerCase()]);
		}
		var fs = (view.search.value || '').toLowerCase().split(/\s+/).filter(function(t) { return t !== ''; });

		// Packet floor, idle flows and search first: the class strip counts
		// what is left, so it stays a menu of what the class filter can pick from.
		var quiet = 0, idle = 0;
		var pool = view.rows.filter(function(r) {
			if (r.pkts <= MIN_PKTS) { quiet++; return false; }
			if (r.idle) { idle++; return false; }
			if (!fs.length) return true;
			// Every token must hit some field: "udp 192.168.1.201 ef" narrows.
			var fields = [ r.proto || '', r.fam || '', (r.src || '') + ':' + (r.sport || ''),
				(r.dst || '') + ':' + (r.dport || ''), r.dscp || '', r.cls, r.dev.name ].map(function(f) { return f.toLowerCase(); });
			return fs.every(function(t) { return fields.some(function(f) { return f.indexOf(t) >= 0; }); });
		});

		var per = {}, up = 0, dn = 0;
		pool.forEach(function(r) {
			var a = per[r.cls] || (per[r.cls] = { n: 0, b: 0 });
			a.n++; a.b += r.avgBps;
			up += r.avgUpBps; dn += r.avgDnBps;
		});
		h.morphKids(view.chips, CLASSES.map(function(c) {
			var a = per[c[0]] || { n: 0, b: 0 };
			return E('span', { 'class': 'qos-ex-chip qos-ex-chip-btn' + (view.cls && view.cls !== c[0] ? ' dim' : '') +
				(view.cls === c[0] ? ' on' : ''), 'data-cls': c[0], 'title': c[1] + ' · ' + c[2].join(', ') }, [
				sw(c[0]), c[0] + ' ', E('b', {}, String(a.n)),
				E('span', { 'class': 'qos-ex-muted' }, ' ' + fmtBits(a.b))
			]);
		}));

		var rows = view.cls ? pool.filter(function(r) { return r.cls === view.cls; }) : pool;

		var col = view.sortCol, desc = view.sortDesc;
		rows.sort(function(a, b) {
			var x = a[col], y = b[col];
			if (col === 'sport' || col === 'dport') { x = +x || 0; y = +y || 0; }
			else if (typeof x === 'string' || typeof y === 'string') {
				x = String(x == null ? '' : x).toLowerCase(); y = String(y == null ? '' : y).toLowerCase();
			} else { x = x || 0; y = y || 0; }
			if (x < y) return desc ? 1 : -1;
			if (x > y) return desc ? -1 : 1;
			return (b.bytes || 0) - (a.bytes || 0);
		});

		view.head.querySelectorAll('.qos-ex-sort-ind').forEach(function(s) {
			s.textContent = s.getAttribute('data-col') === col ? (desc ? ' ▼' : ' ▲') : '';
		});

		h.morphKids(view.pills, [
			E('span', { 'class': 'label pf-pill', 'title': [ idle ? idle + _(' idle hidden') : '',
					quiet ? quiet + _(' with ≤ ') + MIN_PKTS + _(' packets hidden') : '' ].filter(function(t) { return t; }).join(' · ') },
				rows.length + ' / ' + view.rows.length + _(' flows')),
			E('span', { 'class': 'label pf-pill' }, '↓ ' + fmtBits(dn)),
			E('span', { 'class': 'label pf-pill' }, '↑ ' + fmtBits(up)),
			E('span', { 'class': 'qos-ex-muted' }, view.running ? _('every ') + view.pollSec + 's' : _('paused'))
		]);

		var out = [], NC = String(COLS.length);
		function td(v, right) { return E('td', { 'class': 'td' + (right ? ' right' : '') }, [ v ]); }
		function has(r, c) { return r.fl.indexOf(c) >= 0; }

		function shown(r) { return view.exp === r.key; }
		function flowRow(r) {
			var game = isGame(r), s = view.pf[r.dst] || view.pf[r.src];
			var why = has(r, 'b') ? _('sticky') : has(r, 'f') ? _('fast') : '';
			var ping = s ? (s.ping | 0) : 0;
			return E('tr', { 'class': 'tr flow' + (shown(r) ? ' exp' : ''), 'data-key': r.key }, [
				E('td', { 'class': 'td', 'title': r.cls ? CLS_LEAF[r.cls] : '' }, [
					r.cls ? sw(r.cls) : '', r.cls, r.cls ? E('br') : '', E('code', {}, [ r.dscp || '-' ]),
					why ? E('span', { 'class': 'qos-ex-muted' }, [ ' · ' + why ]) : '' ]),
				E('td', { 'class': 'td' }, [ (r.proto || '') + (r.fam === 'ipv6' ? ' v6' : ''), has(r, 'o') ? E('br') : '',
					has(r, 'o') ? E('span', { 'class': 'qos-ex-muted', 'title': _('flow-offloaded: counters arrive in bursts') }, [ _('offload') ]) : '' ]),
				E('td', { 'class': 'td qos-ex-ip', 'title': r.src || '' }, [ r.src || '', game ? E('br') : '',
					game ? E('span', { 'class': 'label notice', 'title': _('configured gaming device') }, [ 'GAME' ]) : '' ]),
				td(r.sport || '', 1),
				E('td', { 'class': 'td qos-ex-ip', 'title': r.dst || '' }, [ r.dst || '', s ? E('br') : '',
					s ? E('span', { 'class': 'label pf-badge ' + s.state, 'title': 'Ping Filter: ' + s.state },
						[ ping > 0 ? ping + ' ms' : String(s.state) ]) : '',
					s && s.country ? ' ' + s.country : '' ]),
				td(r.dport || '', 1),
				td(updn(r.avgUpBps, r.avgDnBps, fmtBits), 1),
				td(updn(r.avgUpPps, r.avgDnPps), 1),
				td(r.hasDir ? updn(r.upBytes, r.dnBytes, h.fmtBytes) : h.fmtBytes(r.bytes), 1)
			]);
		}

		// Detail row under an expanded flow: everything the columns clip or
		// leave out, why the classifier put it there, and its rate trend.
		function detRow(r) {
			var kv = [], s = view.pf[r.dst] || view.pf[r.src], t = trend(view.hist[r.key] || { ub: [], db: [] },
				r.cls ? h.classColor(r.cls) : 'currentColor');
			function add(k, v) { kv.push(E('div', { 'class': 'qos-ex-muted' }, [ k ]), E('div', {}, v)); }
			add(_('Flow'), [ r.proto + ' ' + addr(r.src, r.sport) + ' → ' + addr(r.dst, r.dport) ]);
			if (r.dev !== OTHER) add(_('Device'), [ r.dev.name + (r.dev.ip && r.dev.ip !== r.dev.name ? ' (' + r.dev.ip + ')' : '') ]);
			var nat = [];
			if (r.rdst && r.rdst !== r.src) nat.push(_('leaves as ') + r.rdst);
			if (r.rsrc && r.rsrc !== r.dst) nat.push(_('forwarded to ') + r.rsrc);
			if (nat.length) add(_('NAT'), [ nat.join(' · ') ]);
			var ct = [];
			if (r.state) ct.push(r.state);
			if (r.tmo) ct.push(_('expires in ') + fmtSecs(r.tmo));
			if (has(r, 'u')) ct.push(_('no reply yet'));
			if (has(r, 'o')) ct.push(_('offloaded (counters arrive in bursts)'));
			if (ct.length) add(_('Conntrack'), [ ct.join(' · ') ]);
			var why = [];
			if (has(r, 'b')) why.push(_('this device and server are a bulk pair: its TCP goes to Bulk'));
			// Adaptive: busy TCP drops to Default, any other busy flow (the
			// auto chain's non-TCP, the gaming and video-call guards) to AF11.
			if (has(r, 'f')) why.push(view.adaptive ?
				(r.proto === 'tcp' ?
					_('over %s packets/s, so it is in Default').format(view.tcpSlow) :
					_('over %s packets/s, so it is in Low').format(view.udpFast)) :
				r.proto === 'udp' ?
				_('over %s packets/s, so it is sent to Low').format(view.udpFast) :
				_('over %s packets/s, so it gets no slow-flow lift').format(view.tcpSlow));
			add(_('Class'), [ (r.cls ? r.cls + ' ' + CLS_LEAF[r.cls] + ' · ' : '') + (r.dscp || '-') +
				(why.length ? ' — ' + why.join('; ') : '') ]);
			if (s) add('Ping Filter', [ s.state + ((s.ping | 0) > 0 ? ' · ' + (s.ping | 0) + ' ms' : '') +
				(s.city || s.country ? ' · ' + [ s.city, s.country ].filter(function(x) { return x; }).join(', ') : '') + ' · ',
				E('a', { 'href': L.url('admin', 'network', 'qos-ex', 'pingfilter', 'servers') }, [ _('Servers') + ' →' ]) ]);
			add(_('Counters'), [ r.hasDir ? '↑ ' + r.upPkts + _(' pkts') + ' / ' + h.fmtBytes(r.upBytes) + '   ↓ ' +
				r.dnPkts + _(' pkts') + ' / ' + h.fmtBytes(r.dnBytes) : r.pkts + _(' pkts') + ' / ' + h.fmtBytes(r.bytes) ]);
			add(_('Rate'), [ t.svg, E('span', { 'class': 'qos-ex-muted' }, [ ' ' + _('peak ') + fmtBits(t.peak) ]) ]);
			return E('tr', { 'class': 'tr det' }, [ E('td', { 'class': 'td', 'colspan': NC }, [
				E('div', { 'class': 'qos-ex-conn-det' }, kv) ]) ]);
		}

		function flows(list) {
			list.forEach(function(r) {
				out.push(flowRow(r));
				if (shown(r)) out.push(detRow(r));
			});
		}

		if (view.err || !rows.length) {
			out.push(E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': NC }, [ E('em', {}, [ view.err ||
					// A rate needs two samples; a flow with none is not listed.
					((view.nSamp | 0) >= 2 ? _('No flows with traffic') : view.running ? _('Measuring\u2026')
						: _('Paused before a rate was measured \u2014 pick a refresh time')) ]) ])
			]));
		} else if (!view.grp) {
			flows(rows);
		} else {
			// One row per device with its totals; rows keep the table sort.
			var by = {}, groups = [];
			rows.forEach(function(r) {
				var g = by[r.dev.key];
				if (!g) groups.push(g = by[r.dev.key] = { d: r.dev, rows: [], game: false,
					ub: 0, db: 0, up: 0, dp: 0, tu: 0, td: 0, avgBps: 0, avgPps: 0, bytes: 0 });
				g.rows.push(r);
				g.ub += r.avgUpBps; g.db += r.avgDnBps; g.up += r.avgUpPps; g.dp += r.avgDnPps;
				g.tu += r.upBytes; g.td += r.dnBytes;
				g.avgBps += r.avgBps; g.avgPps += r.avgPps; g.bytes += r.bytes;
				if (isGame(r)) g.game = true;
			});
			var num = (col === 'avgBps' || col === 'avgPps' || col === 'bytes');
			groups.sort(function(a, b) {
				if ((a.d === OTHER) !== (b.d === OTHER)) return a.d === OTHER ? 1 : -1;
				if (num && a[col] !== b[col]) return (a[col] < b[col]) === desc ? 1 : -1;
				return a.d.name.toLowerCase() < b.d.name.toLowerCase() ? -1 : 1;
			});
			groups.forEach(function(g) {
				var d = g.d, open = (d.key in view.open) ? !!view.open[d.key] : g.game;
				out.push(E('tr', { 'class': 'tr grp' + (open ? ' open' : ''), 'data-dev': d.key }, [
					E('td', { 'class': 'td', 'colspan': '6', 'title': d.ip }, [
						open ? '▾ ' : '▸ ', E('b', {}, [ d.name ]),
						d.ip && d.ip !== d.name ? E('span', { 'class': 'qos-ex-muted' }, [ ' ' + d.ip ]) : '',
						g.game ? ' ' : '',
						g.game ? E('span', { 'class': 'label notice', 'title': _('configured gaming device') }, [ 'GAME' ]) : '',
						E('span', { 'class': 'qos-ex-muted' }, [ ' · ' + g.rows.length + (g.rows.length === 1 ? _(' flow') : _(' flows')) ]) ]),
					td(updn(g.ub, g.db, fmtBits), 1),
					td(updn(g.up, g.dp), 1),
					td(updn(g.tu, g.td, h.fmtBytes), 1)
				]));
				if (open) flows(g.rows);
			});
		}
		h.morphKids(view.tbody, out);
	},

	handleSave: null, handleSaveApply: null, handleReset: null
});
