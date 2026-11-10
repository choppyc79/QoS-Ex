'use strict';
'require view';
'require uci';
'require poll';
'require dom';
'require view.qos-ex._helpers as h';

// Stats (Network > QoS-Ex > Live > Stats): the queues live, on two tabs,
// Download (ingress, IFB) and Upload (egress, WAN). Each has a throughput
// chart stacked by class, a queue delay chart, the per-class (CAKE: per-tin)
// counters and tc's own queue details, sampled at the refresh picked in the
// tab bar. A stopped shaper gets a card that says so instead.

// Rolling window in wall-clock time: five minutes whatever the refresh rate,
// long enough to see a download start and the game class hold through it.
var WIN = 300;
var PAD_L = 46, PAD_R = 8, PAD_T = 10, PAD_B = 20;
// Stack, legend and table order, bottom of the stack first: the game class
// sits on the axis so it is always a visible band, never buried under Bulk.
var RANK = [ 'Gaming', 'Voice', 'Video', 'Default', 'Best Effort', 'Low', 'Bulk' ];
function rank(n) {
	var k = RANK.indexOf(n), m = /^Tin (\d+)$/.exec(n || '');
	return k >= 0 ? k : m ? 20 - +m[1] : 3.5;
}

function svgEl(name, attrs) {
	var el = document.createElementNS('http://www.w3.org/2000/svg', name);
	for (var k in attrs) if (attrs[k] != null) el.setAttribute(k, attrs[k]);
	return el;
}

// ---- per-qdisc detail tables (tc -s -j, via the shim's `tc` method) ------
// tc reports rates in bytes/s and delays in microseconds.
function fmtUs(us) {
	us = +us || 0;
	return us < 1000 ? us + ' \u00b5s' : (us / 1000).toFixed(us < 10000 ? 2 : 1) + ' ms';
}
function num(v) { return (v == null || v === '') ? '\u2014' : String(v); }
function stockTable(cols, rows, empty) {
	return E('div', { 'class': 'qos-ex-conn-wrap' }, [
		E('table', { 'class': 'table qos-ex-conn' }, [
			E('tr', { 'class': 'tr table-titles' }, cols.map(function(c) {
				return E('th', { 'class': 'th' + (c[1] ? ' right' : '') }, [ c[0] ]);
			}))
		].concat(rows.length ? rows.map(function(r) {
			return E('tr', { 'class': 'tr' }, r.map(function(v, k) {
				return E('td', { 'class': 'td' + (cols[k][1] ? ' right' : '') }, [ v ]);
			}));
		}) : [ E('tr', { 'class': 'tr placeholder' }, [
			E('td', { 'class': 'td', 'colspan': String(cols.length) }, [ E('em', {}, empty) ]) ]) ]))
	]);
}
// The tc text parser lives in the helpers (the Overview reads it too).
function parseTcText(txt) { return h.parseTcText(txt); }

// One direction's tc detail. CAKE: a row per tin from tc -j. HFSC/HTB: a row
// per leaf class from plain `tc -s qdisc/class show` text -- what the class
// counters above do not show: the scheduler's curves and its own xstats, and
// the class's leaf queue (fq_codel flows, ECN marks, overlimit drops).
// names: class id -> counter name.
function tcDetail(d, prio, names) {
	var none = [ E('p', {}, E('em', {}, _('No tc data \u2014 shaper stopped.'))) ];
	var cake = h.cakeOf(d && d.qdisc);
	if (cake) {
		var tn = h.cakeTins((cake.options && cake.options.diffserv) || prio);
		return [ stockTable([ [ _('Tin') ], [ _('Threshold'), 1 ], [ _('Target'), 1 ], [ _('Interval'), 1 ],
			[ _('Peak delay'), 1 ], [ _('Avg delay'), 1 ], [ _('Sparse delay'), 1 ], [ _('Sent'), 1 ],
			[ _('Packets'), 1 ], [ _('Drops'), 1 ], [ _('ECN marks'), 1 ], [ _('Flows s/b/u'), 1 ] ],
			// Same order as the counters: Voice at the top, Bulk at the bottom.
			(cake.tins || []).map(function(t, k) { return [ tn[k] || ('Tin ' + k), t ]; })
				.sort(function(a, z) { return rank(a[0]) - rank(z[0]); }).map(function(p) {
					var t = p[1];
					return [ p[0], h.fmtRate((+t.threshold_rate || 0) * 8), fmtUs(t.target_us),
						fmtUs(t.interval_us), fmtUs(t.peak_delay_us), fmtUs(t.avg_delay_us), fmtUs(t.base_delay_us),
						h.fmtBytes(t.sent_bytes), num(t.sent_packets), num(t.drops), num(t.ecn_mark),
						num(t.sparse_flows) + ' / ' + num(t.bulk_flows) + ' / ' + num(t.unresponsive_flows) ];
				}), _('No tins reported')) ];
	}
	var t = parseTcText(d && d.text), cl = t['class'], lq = {};
	if (!cl.length) return none;
	t.qdisc.forEach(function(x) { lq[x.handle] = x; });
	function minor(x) { return parseInt(String(x.handle).split(':')[1], 16) || 0; }
	function isLeaf(x) { return !!x.leaf || x.level === 0; }
	// Short rate: "120.4 Mbit". A two-slope curve shows its burst: "160 Mbit (20 Mbit / 50ms)".
	function r(v) {
		v = +v || 0;
		var u = v >= 1e9 ? [ 1e9, 'Gbit' ] : v >= 1e6 ? [ 1e6, 'Mbit' ] : v >= 1e3 ? [ 1e3, 'kbit' ] : [ 1, 'bit' ];
		return (+(v / u[0]).toFixed(1)) + ' ' + u[1];
	}
	function dim(t) { return E('span', { 'style': 'opacity:.6' }, [ t ]); }
	// m2 on the first line; a two-slope curve's burst (m1 / d) and, for
	// real-time, the share of bytes sent under it on a dimmed second line.
	function curve(c, extra) {
		if (!c) return '\u2014';
		var sub = [ c.m1 ? r(c.m1) + ' / ' + c.d : '', extra || '' ].filter(Boolean).join(' \u00b7 ');
		return sub ? E([], [ r(c.m2), E('br'), dim(sub) ]) : r(c.m2);
	}
	var leaves = cl.filter(isLeaf).sort(function(a, b) { return minor(a) - minor(b); });
	var htb = cl.some(function(x) { return x.kind === 'htb'; });
	function any(f) { return leaves.some(f); }
	// [ header, right-aligned, cell(class, leaf qdisc), shown ]
	var cols = [
		[ _('Class'), 0, function(x, q) { return E([], [ x.handle + (names[x.handle] ? ' ' + names[x.handle] : ''),
			E('br'), dim(q.kind || '') ]); }, 1 ],
		[ _('Rate'), 1, function(x) { return x.rate != null ? r(x.rate) : '\u2014'; }, htb ],
		[ _('Ceil'), 1, function(x) { return x.ceil != null ? r(x.ceil) : '\u2014'; }, htb ],
		[ _('Lended'), 1, function(x) { return num(x.lended); }, htb ],
		[ _('Borrowed'), 1, function(x) { return num(x.borrowed); }, htb ],
		[ _('Real-time'), 1, function(x) {
			return curve(x.sc.rt, x.work > 0 ? Math.round((x.rtwork || 0) * 100 / x.work) + '% ' + _('sent') : ''); }, !htb ],
		[ _('Link-share'), 1, function(x) { return curve(x.sc.ls); }, !htb ],
		[ _('Upper limit'), 1, function(x) { return curve(x.sc.ul); }, !htb && any(function(x) { return x.sc.ul; }) ],
		[ _('Busy periods'), 1, function(x) { return num(x.period); }, !htb ],
		[ _('Active flows'), 1, function(x, q) {
			return q.new_flows_len != null ? String(q.new_flows_len + q.old_flows_len) : '\u2014'; }, 1 ],
		[ _('New flows'), 1, function(x, q) { return num(q.new_flow_count); }, 1 ],
		[ _('ECN marks'), 1, function(x, q) { return num(q.ecn_mark); }, 1 ],
		[ _('Overflow drops'), 1, function(x, q) { return num(q.drop_overlimit); }, 1 ]
	].filter(function(c) { return c[3]; });
	var rows = leaves.map(function(x) {
		var q = lq[x.leaf] || {};
		return cols.map(function(c) { return c[2](x, q); });
	});
	return [ stockTable(cols.map(function(c) { return [ c[0], c[1] ]; }), rows, _('No classes reported')) ];
}

// ---- charts ---------------------------------------------------------------
// Axis rate: "250M", "1.5G", "800k".
function axRate(b) {
	var u = b >= 1e9 ? [ 1e9, 'G' ] : b >= 1e6 ? [ 1e6, 'M' ] : b >= 1e3 ? [ 1e3, 'k' ] : [ 1, '' ];
	return (+(b / u[0]).toFixed(2)) + u[1];
}
function fmtMs(v) {
	return v == null ? '—' : (v < 10 ? v.toFixed(1) : String(Math.round(v))) + ' ms';
}
// Scale top rounded to a 1/2/2.5/5 x 10^n step, so the gridlines land on
// readable figures.
function scale(v) {
	if (!(v > 0)) v = 1;
	var raw = v / 4, p = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10)), m = raw / p;
	var step = p * (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10);
	return { max: Math.ceil(v / step - 1e-9) * step, step: step };
}
// Path through the points. Each control point shares its end point's y, so
// the curve never overshoots a sample: no dip below zero, no false peak.
function curve(pts, move) {
	var s = '';
	for (var i = 0; i < pts.length; i++) {
		var x = pts[i][0].toFixed(1), y = pts[i][1].toFixed(1);
		if (!i) { s += (move ? 'M' : 'L') + x + ',' + y; continue; }
		var xm = ((pts[i - 1][0] + pts[i][0]) / 2).toFixed(1);
		s += 'C' + xm + ',' + pts[i - 1][1].toFixed(1) + ' ' + xm + ',' + y + ' ' + x + ',' + y;
	}
	return s;
}
function sw(nm) { return E('i', { 'class': 'sw', 'style': 'background:' + h.classColor(nm) }); }
function ago(t, now) {
	var s = Math.round((now - t) / 1000);
	return s < 1 ? _('now') : s < 60 ? s + 's ' + _('ago') : Math.floor(s / 60) + 'm ' + (s % 60) + 's ' + _('ago');
}
function rateOf(s, nm) { return s.r[nm] || 0; }
function delayOf(s, nm) { return s.dl && s.dl[nm] != null ? s.dl[nm] : null; }

// One chart. The SVG's viewBox follows the box's pixel width on every paint,
// so axis text is never stretched; the body is rebuilt per paint (a few
// dozen nodes), the crosshair and tooltip persist across paints.
var clipSeq = 0;
function makeChart(title, H) {
	var id = 'qos-ex-clip-' + (++clipSeq);
	var clipRect = svgEl('rect', { 'x': PAD_L, 'y': 0, 'height': H });
	var defs = svgEl('defs', {}), clip = svgEl('clipPath', { 'id': id });
	clip.appendChild(clipRect); defs.appendChild(clip);
	var svg = svgEl('svg', { 'class': 'qos-ex-chart', 'style': 'height:' + H + 'px', 'viewBox': '0 0 680 ' + H });
	var body = svgEl('g', {});
	var cross = svgEl('line', { 'class': 'qos-ex-ch-cross', 'y1': PAD_T, 'y2': H - PAD_B, 'visibility': 'hidden' });
	svg.appendChild(defs); svg.appendChild(body); svg.appendChild(cross);
	var ch = {
		svg: svg, body: body, cross: cross, clip: id, clipRect: clipRect, H: H, W: 680, hx: null, last: null,
		tip: E('div', { 'class': 'qos-ex-ch-tip' }),
		note: E('span', { 'class': 'qos-ex-chart-note' }, ''),
		sub: E('span', { 'class': 'qos-ex-muted' }, ''),
		right: E('span', { 'class': 'qos-ex-muted' }, '')
	};
	ch.node = E('div', { 'class': 'qos-ex-chart-wrap' }, [
		E('div', { 'class': 'qos-ex-chart-h' }, [ E('span', {}, [ E('b', {}, title), ' ', ch.sub ]), ch.note, ch.right ]),
		E('div', { 'class': 'qos-ex-ch-plot' }, [ svg, ch.tip ])
	]);
	svg.addEventListener('mousemove', function(ev) {
		ch.hx = (ev.clientX - svg.getBoundingClientRect().left); hover(ch);
	});
	svg.addEventListener('mouseleave', function() { ch.hx = null; hover(ch); });
	return ch;
}

function hover(ch) {
	var L = ch.last;
	if (ch.hx == null || !L || !L.xs.length) {
		ch.cross.setAttribute('visibility', 'hidden');
		ch.tip.style.display = 'none';
		return;
	}
	var b = 0;
	for (var i = 1; i < L.xs.length; i++)
		if (Math.abs(L.xs[i] - ch.hx) < Math.abs(L.xs[b] - ch.hx)) b = i;
	var x = L.xs[b];
	ch.cross.setAttribute('x1', x); ch.cross.setAttribute('x2', x);
	ch.cross.setAttribute('visibility', 'visible');
	dom.content(ch.tip, L.tip(b));
	ch.tip.style.display = 'block';
	var tw = ch.tip.offsetWidth;
	ch.tip.style.left = (x + 14 + tw > ch.W ? Math.max(0, x - tw - 14) : x + 14) + 'px';
}

// o = { samp, order, val(s, nm), stack, floor, ref: [v, label], band, marks,
//       fmtAx(v), focus, tip(i) }. x is time: the newest sample on the right
// edge, WIN seconds across.
function paint(ch, o) {
	var W = Math.round(ch.svg.getBoundingClientRect().width) || ch.W;
	ch.W = W;
	var H = ch.H, pw = W - PAD_L - PAD_R, ph = H - PAD_T - PAD_B;
	ch.svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
	ch.clipRect.setAttribute('width', pw);
	var S = o.samp, n = S.length, now = n ? S[n - 1].t : 0, names = o.order;
	function X(t) { return PAD_L + pw * (1 - (now - t) / (WIN * 1000)); }
	var vals = [], mx = 0;
	S.forEach(function(s) {
		var acc = 0, row = [];
		names.forEach(function(nm) {
			var v = o.val(s, nm);
			if (o.stack) { acc += v || 0; v = acc; }
			row.push(v);
			if (v > mx) mx = v;
		});
		vals.push(row);
	});
	var top = Math.max(mx * 1.1, o.floor || 0);
	if (o.ref && o.ref[0] > 0 && o.ref[0] <= mx * 1.6) top = Math.max(top, o.ref[0] * 1.05);
	var sc = scale(top);
	function Y(v) { return PAD_T + ph * (1 - Math.min(1, Math.max(0, v) / sc.max)); }
	var g = svgEl('g', {}), t, v, y;
	if (o.band > 0)
		g.appendChild(svgEl('rect', { 'class': 'qos-ex-ch-band', 'x': PAD_L, 'width': pw,
			'y': Y(o.band).toFixed(1), 'height': (Y(0) - Y(o.band)).toFixed(1) }));
	for (v = 0; v <= sc.max + sc.step / 2; v += sc.step) {
		y = Y(v).toFixed(1);
		g.appendChild(svgEl('line', { 'class': v ? 'qos-ex-ch-grid' : 'qos-ex-ch-base',
			'x1': PAD_L, 'x2': W - PAD_R, 'y1': y, 'y2': y }));
		t = svgEl('text', { 'class': 'qos-ex-ch-ax', 'x': PAD_L - 6, 'y': (+y + 3.5).toFixed(1), 'text-anchor': 'end' });
		t.textContent = o.fmtAx(v);
		g.appendChild(t);
	}
	[ [ PAD_L, 'start', '−' + (WIN / 60) + ' min' ], [ PAD_L + pw / 2, 'middle', '−' + (WIN / 120) + ' min' ],
	  [ W - PAD_R, 'end', _('now') ] ].forEach(function(a) {
		t = svgEl('text', { 'class': 'qos-ex-ch-ax', 'x': a[0].toFixed(1), 'y': H - 5, 'text-anchor': a[1] });
		t.textContent = a[2];
		g.appendChild(t);
	});
	var xs = S.map(function(s) { return X(s.t); });
	var ser = svgEl('g', { 'clip-path': 'url(#' + ch.clip + ')' });
	var base = xs.map(function(x) { return [ x, Y(0) ]; });
	names.forEach(function(nm, k) {
		var col = h.classColor(nm), dim = o.focus && o.focus !== nm, i;
		if (o.stack) {
			if (n < 2) return;
			var pts = xs.map(function(x, i) { return [ x, Y(vals[i][k]) ]; });
			ser.appendChild(svgEl('path', { 'd': curve(pts, true) + curve(base.slice().reverse(), false) + 'Z',
				'fill': col, 'fill-opacity': dim ? '0.06' : '0.30', 'stroke': 'none' }));
			ser.appendChild(svgEl('path', { 'd': curve(pts, true), 'fill': 'none', 'stroke': col,
				'stroke-width': '1.5', 'stroke-opacity': dim ? '0.2' : '1', 'stroke-linejoin': 'round' }));
			base = pts;
			return;
		}
		// Plain lines break where a sample carries no value.
		var seg = [], d = '';
		for (i = 0; i <= n; i++) {
			if (i < n && vals[i][k] != null) { seg.push([ xs[i], Y(vals[i][k]) ]); continue; }
			if (seg.length > 1) d += curve(seg, true);
			seg = [];
		}
		if (d) ser.appendChild(svgEl('path', { 'd': d, 'fill': 'none', 'stroke': col,
			'stroke-width': k ? '1.4' : '2.2', 'stroke-opacity': dim ? '0.15' : k ? '0.8' : '1',
			'stroke-linejoin': 'round', 'stroke-linecap': 'round' }));
	});
	if (o.marks) S.forEach(function(s, i) {
		if (!(s.ev > 0)) return;
		t = svgEl('text', { 'class': 'qos-ex-ch-mark', 'x': xs[i].toFixed(1), 'y': PAD_T + 6, 'text-anchor': 'middle' });
		t.textContent = '▼';
		ser.appendChild(t);
	});
	g.appendChild(ser);
	if (o.ref && o.ref[0] > 0 && o.ref[0] <= sc.max) {
		y = Y(o.ref[0]).toFixed(1);
		g.appendChild(svgEl('line', { 'class': 'qos-ex-ch-ref', 'x1': PAD_L, 'x2': W - PAD_R, 'y1': y, 'y2': y }));
		t = svgEl('text', { 'class': 'qos-ex-ch-ax', 'x': W - PAD_R, 'y': (+y - 4).toFixed(1), 'text-anchor': 'end' });
		t.textContent = o.ref[1];
		g.appendChild(t);
	}
	ch.svg.replaceChild(g, ch.body);
	ch.body = g;
	ch.last = { xs: xs, tip: o.tip };
	hover(ch);
}

// Queue delay per class from the tc snapshot. CAKE reports it per tin;
// HFSC/HTB report none, so `est` asks the caller to derive it from backlog.
function queueInfo(td, rows, cake) {
	var q = h.cakeOf(td && td.qdisc);
	if (cake) {
		if (!q) return { dl: null, ecn: null, target: 0, est: false };
		var tins = q.tins || [], dl = {}, ecn = 0;
		tins.forEach(function(t) { ecn += +t.ecn_mark || 0; });
		rows.forEach(function(row) {
			if (row.tin >= 0 && tins[row.tin]) dl[row.name] = (+tins[row.tin].avg_delay_us || 0) / 1000;
		});
		return { dl: dl, ecn: ecn, target: tins[0] ? (+tins[0].target_us || 0) / 1000 : 0, est: false };
	}
	var e = null;
	if (td && td.text) {
		e = 0;
		parseTcText(td.text).qdisc.forEach(function(x) { e += x.ecn_mark || 0; });
	}
	// fq_codel leaves at their default target.
	return { dl: null, ecn: e, target: 5, est: true };
}
// Little's law on what the counters do give: the class's queued bytes over
// the rate it is draining at (its measured rate; the shaped rate when it
// moved nothing this sample). Capped at 1 s.
function estDelay(rows, r, shaped) {
	var dl = {};
	rows.forEach(function(row) {
		var drain = r[row.name] > 0 ? r[row.name] : shaped;
		dl[row.name] = (row.backlog > 0 && drain > 0) ? Math.min(1000, row.backlog * 8000 / drain) : 0;
	});
	return dl;
}

return view.extend({
	// One light backend call: the counters. The full tc report is not shown
	// in LuCI (1.2.9.5): `qos-ex.sh stats` over SSH prints it.
	load: function() {
		return Promise.all([
			uci.load('qos-ex'),
			h.rpcSafe(h.callCounters())
		]);
	},

	render: function(loaded) {
		var view = this;
		var cs = h.parseCounters(loaded[1].output || '');
		var qdiscv = cs.meta.qdisc || h.qdiscCfg();
		// Either direction's root, as the Status include: upload unshaped
		// (upload_kbps 0) has no qd_up, and config warnings printed outside
		// the fence made a stopped shaper read as running.
		var running = /^(cake|hfsc|htb)$/.test(cs.meta.qd_up || '') ||
			/^(cake|hfsc|htb)$/.test(cs.meta.qd_down || '');
		// Nothing to sample while the shaper is down: say so, and offer the
		// way to start it, instead of empty charts polling every 5 s.
		if (!running) return E([], [ h.pageHead(_('Stats')), h.shaperOffCard() ]);
		var DIRS = [ 'down', 'up' ];

		view.cur     = cs;
		view.samp    = { up: [], down: [] };   // [{ t, r, dl, ev, dr }], oldest first
		view.order   = { up: [], down: [] };   // stack order, game class first
		view.rowsNow = { up: [], down: [] };
		view.prevEv  = { up: null, down: null };
		view.target  = { up: 0, down: 0 };
		view.est     = { up: false, down: false };
		view.focus   = { up: null, down: null };
		view.prev    = null;
		view.lastTc  = null;

		function isCake() { return (view.cur.meta.qdisc || qdiscv) === 'cake'; }
		function shapedOf(d) { return (+(d === 'up' ? view.cur.meta.ul_kbps : view.cur.meta.dl_kbps) || 0) * 1000; }
		function ifName(d) { return (d === 'up' ? view.cur.meta.wan : view.cur.meta.ifb) || ''; }

		// ---- one sample -> history -------------------------------------
		// Counters are cumulative: the first sample, or a counter that went
		// backwards after a qdisc rebuild, gives no rate -- nothing is pushed
		// rather than a fake zero or a spike.
		function ingest(c, tc) {
			var now = Date.now(), dt = view.prev ? (now - view.prev.ts) / 1000 : 0, b = {};
			DIRS.forEach(function(d) {
				var rows = (c.rows[d] || []).slice(), ord = view.order[d], shaped = shapedOf(d);
				rows.forEach(function(row) {
					b[d + '|' + row.name] = row.bytes;
					if (ord.indexOf(row.name) < 0) ord.push(row.name);
				});
				ord.sort(function(a, z) { return (rank(a) - rank(z)) || (a < z ? -1 : a > z ? 1 : 0); });
				rows.sort(function(a, z) { return ord.indexOf(a.name) - ord.indexOf(z.name); });
				view.rowsNow[d] = rows;
				var q = queueInfo(tc ? (d === 'down' ? tc.ingress : tc.egress) : null, rows, isCake());
				if (q.target) view.target[d] = q.target;
				view.est[d] = q.est;
				var drops = 0, pe = view.prevEv[d];
				rows.forEach(function(row) { drops += row.drops; });
				if (!view.prev || !(dt > 0.2) || !pe) { view.prevEv[d] = { drops: drops, ecn: q.ecn }; return; }
				var r = {}, dr = {};
				rows.forEach(function(row) {
					var was = view.prev.b[d + '|' + row.name];
					r[row.name] = was !== undefined ? Math.max(0, row.bytes - was) * 8 / dt : 0;
					dr[row.name] = row.drops;
				});
				if (q.est) q.dl = estDelay(rows, r, shaped);
				var ev = Math.max(0, drops - pe.drops) +
					((q.ecn != null && pe.ecn != null) ? Math.max(0, q.ecn - pe.ecn) : 0);
				view.prevEv[d] = { drops: drops, ecn: q.ecn != null ? q.ecn : pe.ecn };
				var S = view.samp[d];
				S.push({ t: now, r: r, dl: q.dl, ev: ev, dr: dr });
				// One sample is kept past the left edge so the curve runs off it.
				while (S.length > 2 && S[1].t < now - WIN * 1000) S.shift();
			});
			view.prev = { ts: now, b: b };
		}

		function lastTotal(d) {
			var S = view.samp[d], s = S[S.length - 1], a = 0;
			if (s) view.order[d].forEach(function(nm) { a += rateOf(s, nm); });
			return s ? a : null;
		}
		// ---- one direction: two charts, chips, counters table -------------
		function chips(d) {
			var S = view.samp[d], s = S[S.length - 1], foc = view.focus[d], tot = lastTotal(d) || 0;
			if (!s) return [ E('span', { 'class': 'qos-ex-muted' }, _('no data yet')) ];
			return view.order[d].map(function(nm) {
				var r = rateOf(s, nm);
				return E('span', { 'class': 'qos-ex-chip' + (foc && foc !== nm ? ' dim' : ''), 'data-cls': nm }, [
					sw(nm), nm + ' ', E('b', {}, h.fmtRate(r)),
					E('span', { 'class': 'qos-ex-muted' }, ' ' + (tot > 0 ? Math.round(r * 100 / tot) : 0) + '%')
				]);
			});
		}

		// Per-class cards: the headline strip over the charts. Rate now, drops
		// (total, and the window's rise) and backlog per class, keyed by the
		// class colour; idle classes dim, a class dropping or holding a
		// backlog gets the red edge. Hovering one focuses the charts, as the
		// chips do (same data-cls contract).
		function clsCards(d) {
			var S = view.samp[d], s = S[S.length - 1], foc = view.focus[d];
			return view.rowsNow[d].map(function(row) {
				var nm = row.name, r = s ? rateOf(s, nm) : 0, pk = 0;
				S.forEach(function(x) { if (rateOf(x, nm) > pk) pk = rateOf(x, nm); });
				var w = (S.length && S[0].dr[nm] != null) ? Math.max(0, row.drops - S[0].dr[nm]) : 0;
				var hot = w > 0 || row.backlog > 0;
				var cls = 'qx-cc' + (hot ? ' hot' : pk <= 0 ? ' idle' : '') + (foc && foc !== nm ? ' dim' : '');
				return E('div', { 'class': cls, 'data-cls': nm, 'style': '--qx-cc:' + h.classColor(nm) }, [
					E('div', { 'class': 'qx-label' }, [ nm ]),
					E('div', { 'class': 'qx-cc-rate' }, h.fmtRate(r)),
					E('div', { 'class': 'qx-cc-sub' }, [ String(row.drops) + ' ' + _('drops') +
						(w > 0 ? ' +' + w : '') + ' · ' + h.fmtBytes(row.backlog) ]) ]);
			});
		}

		function tableRows(d) {
			var S = view.samp[d], s = S[S.length - 1];
			var shaped = shapedOf(d), foc = view.focus[d], est = view.est[d];
			var sum = { r: 0, peak: 0, drops: 0, win: 0, bytes: 0, pkts: 0, bl: 0, ecn: null };
			S.forEach(function(x) {
				var a = 0;
				view.order[d].forEach(function(nm) { a += rateOf(x, nm); });
				if (a > sum.peak) sum.peak = a;
			});
			// Share of link: a class's part of everything sent since the
			// shaper started (its bytes / all bytes), in the class colour. The
			// Total row is how much of the shaped rate is in use now.
			var totBytes = 0;
			view.rowsNow[d].forEach(function(row) { totBytes += row.bytes; });
			function share(r, base, nm) {
				var fmt = nm ? h.fmtBytes : h.fmtRate;
				var pct = base > 0 ? Math.min(100, r * 100 / base) : 0;
				// Floor the DRAWN width only; the label stays exact.
				var wpct = (r > 0 && pct < 1.5) ? 1.5 : pct;
				return E('div', { 'class': 'qos-ex-sharewrap', 'title': fmt(r) + _(' of ') + fmt(base) +
						(nm ? _(' sent') : _(' shaped')) }, [
					E('span', { 'class': 'qos-ex-sharep' }, pct.toFixed(1) + '%'),
					E('div', { 'class': 'qos-ex-share' }, E('i', { 'style': 'width:' + wpct.toFixed(2) + '%' +
						(nm ? ';background:' + h.classColor(nm) : '') + (pct > 0 ? '' : ';min-width:0') }))
				]);
			}
			// Trend: the rate now against this class's own peak in the window,
			// as a moving bar in the class colour. No figure: the percentage
			// is Share of link's.
			function trend(r, pk, nm) {
				var pct = pk > 0 ? Math.min(100, r * 100 / pk) : 0;
				return E('div', { 'class': 'qos-ex-sharewrap', 'title': h.fmtRate(r) + _(' of ') + h.fmtRate(pk) + _(' peak') }, [
					E('div', { 'class': 'qos-ex-share' },
						E('i', { 'style': 'width:' + pct.toFixed(2) + '%;background:' + h.classColor(nm) + (pct > 0 ? '' : ';min-width:0') }))
				]);
			}
			function drops(n, w) {
				return E('td', { 'class': 'r' + (w > 0 ? ' qos-ex-warn-text' : '') }, [ String(n),
					w > 0 ? E('span', { 'class': 'qos-ex-delta', 'title': _('in the last %d min').format(WIN / 60) }, '+' + w) : '' ]);
			}
			var rows = view.rowsNow[d].map(function(row) {
				var nm = row.name, r = s ? rateOf(s, nm) : 0, pk = 0;
				S.forEach(function(x) { if (rateOf(x, nm) > pk) pk = rateOf(x, nm); });
				var w = (S.length && S[0].dr[nm] != null) ? Math.max(0, row.drops - S[0].dr[nm]) : 0;
				var dl = s ? delayOf(s, nm) : null;
				if (row.ecn != null) sum.ecn = (sum.ecn || 0) + row.ecn;
				sum.r += r; sum.drops += row.drops; sum.win += w; sum.bytes += row.bytes;
				sum.pkts += row.pkts; sum.bl += row.backlog;
				var cls = (foc === nm ? 'focus' : foc ? 'dim' : '') + (pk <= 0 && row.backlog <= 0 ? ' idle' : '');
				return E('tr', { 'class': cls.trim(), 'data-cls': nm }, [
					E('td', {}, [ sw(nm), E('b', {}, [ nm ]),
						row.tin < 0 ? E('span', { 'class': 'qos-ex-muted' }, [ ' ' + row.id ]) : '' ]),
					E('td', {}, trend(r, pk, nm)),
					E('td', { 'class': 'r' }, E('b', {}, h.fmtRate(r))),
					E('td', { 'class': 'r qos-ex-muted' }, h.fmtRate(pk)),
					E('td', {}, share(row.bytes, totBytes, nm)),
					// CAKE measures its delay; HFSC / HTB have none to show, so
					// the column is the leaf queue's ECN marks there.
					isCake()
						? E('td', { 'class': 'r' + (dl != null && view.target[d] && dl > view.target[d] * 2 ? ' qos-ex-warn-text' : '') }, fmtMs(dl))
						: E('td', { 'class': 'r', 'title': row.leaf }, row.ecn != null ? String(row.ecn) : '\u2014'),
					drops(row.drops, w),
					// Always print a figure. An idle queue really is 0 bytes, and
					// an em-dash there was read as "this column is broken".
					E('td', { 'class': 'r' + (row.backlog > 0 ? ' qos-ex-warn-text' : '') }, [ h.fmtBytes(row.backlog),
						row.blpkts > 0 ? E('span', { 'class': 'qos-ex-muted' }, ' · ' + row.blpkts + 'p') : '' ]),
					E('td', { 'class': 'r' }, h.fmtBytes(row.bytes)),
					E('td', { 'class': 'r' }, String(row.pkts))
				]);
			});
			if (!rows.length)
				return { body: [ E('tr', {}, E('td', { 'colspan': 10, 'class': 'qos-ex-muted' },
					running ? _('Waiting for the first counter sample…')
					        : _('QoS-Ex is not running — start it from the Overview tab.'))) ], foot: [] };
			return { body: rows, foot: [ E('tr', {}, [
				E('td', {}, _('Total')), E('td', {}, ''),
				E('td', { 'class': 'r' }, h.fmtRate(sum.r)),
				E('td', { 'class': 'r' }, h.fmtRate(sum.peak)),
				E('td', {}, share(sum.r, shaped)),
				E('td', { 'class': 'r' }, est && sum.ecn != null ? String(sum.ecn) : ''),
				drops(sum.drops, sum.win),
				E('td', { 'class': 'r' }, h.fmtBytes(sum.bl)),
				E('td', { 'class': 'r' }, h.fmtBytes(sum.bytes)),
				E('td', { 'class': 'r' }, String(sum.pkts))
			]) ] };
		}

		function paintDir(d) {
			var P = view.pane[d], S = view.samp[d], ord = view.order[d], foc = view.focus[d];
			var now = S.length ? S[S.length - 1].t : 0, shaped = shapedOf(d), tg = view.target[d] || 5;
			var tot = S.map(function(s) { var a = 0; ord.forEach(function(nm) { a += rateOf(s, nm); }); return a; });
			h.setText(P.thr.sub, '· ' + _('stacked by class') + ' · ' + ifName(d) +
				' · ' + _('shaped at ') + h.fmtRate(shaped));
			h.setText(P.thr.right, _('peak ') + h.fmtRate(Math.max.apply(null, [ 0 ].concat(tot))));
			paint(P.thr, { samp: S, order: ord, val: rateOf, stack: true, floor: 1e5, focus: foc,
				ref: [ shaped, _('shaped') + ' ' + axRate(shaped) ], fmtAx: axRate,
				tip: function(i) {
					var s = S[i];
					return [ E('div', { 'class': 'qos-ex-muted' }, ago(s.t, now)) ].concat(
						ord.slice().reverse().map(function(nm) {
							return E('div', {}, [ sw(nm), nm + ' ', E('b', {}, h.fmtRate(rateOf(s, nm))) ]);
						}),
						[ E('div', { 'class': 'qos-ex-ch-tot' }, [ _('Total') + ' ', E('b', {}, h.fmtRate(tot[i])) ]) ]);
				} });
			var any = S.some(function(s) { return !!s.dl; });
			h.setText(P.dly.sub, '· ' + (isCake() ? _('per tin') : _('per class, estimated from backlog')) +
				' · ' + _('target') + ' ' + fmtMs(tg));
			h.setText(P.dly.right, '▼ ' + _('drop / ECN mark'));
			h.setText(P.dly.note, S.length && !any ? _('no queue data from tc') : '');
			paint(P.dly, { samp: S, order: ord, val: delayOf, stack: false, floor: tg * 2, band: tg,
				marks: true, focus: foc, fmtAx: function(v) { return (+v.toFixed(2)) + 'ms'; },
				tip: function(i) {
					var s = S[i];
					return [ E('div', { 'class': 'qos-ex-muted' }, ago(s.t, now)) ].concat(
						ord.map(function(nm) {
							return E('div', {}, [ sw(nm), nm + ' ', E('b', {}, fmtMs(delayOf(s, nm))) ]);
						}),
						s.ev > 0 ? [ E('div', { 'class': 'qos-ex-ch-tot qos-ex-warn-text' },
							_('%d drops / ECN marks').format(s.ev)) ] : []);
				} });
			h.morphKids(P.cards, clsCards(d));
			h.morphKids(P.chips, chips(d));
			var tr = tableRows(d);
			h.morphKids(P.tbody, tr.body);
			h.morphKids(P.tfoot, tr.foot);
		}

		function paintAll() {
			DIRS.forEach(paintDir);
		}

		// Hovering a chip or a table row picks that class out on both charts.
		function focusable(node, d) {
			node.addEventListener('mouseover', function(ev) {
				var r = ev.target.closest ? ev.target.closest('[data-cls]') : null;
				var nm = r ? r.getAttribute('data-cls') : null;
				if (view.focus[d] !== nm) { view.focus[d] = nm; paintDir(d); }
			});
			node.addEventListener('mouseleave', function() {
				if (view.focus[d]) { view.focus[d] = null; paintDir(d); }
			});
		}

		var cntLabel = qdiscv === 'cake' ? _('Per-tin counters') : _('Per-class counters');
		function mkPane(d, label, tcName) {
			var P = {
				thr: makeChart(_('Throughput'), 200),
				dly: makeChart(_('Queue delay'), 140),
				cards: E('div', { 'class': 'qx-cls-cards' }),
				chips: E('div', { 'class': 'qos-ex-chips' }),
				tbody: E('tbody', {}), tfoot: E('tfoot', {}),
				detail: E('div', {})
			};
			focusable(P.cards, d);
			focusable(P.chips, d);
			focusable(P.tbody, d);
			var head = E('tr', {}, [
				E('th', {}, qdiscv === 'cake' ? _('Tin') : _('Class')),
				E('th', { 'title': _('Rate now against the class peak in the last %d min').format(WIN / 60) }, _('Trend')),
				E('th', { 'class': 'r' }, _('Rate')),
				E('th', { 'class': 'r' }, _('Peak')),
				E('th', { 'title': _('Class: its share of all traffic. Total: shaped rate in use now.') }, _('Share of link')),
				E('th', { 'class': 'r', 'title': qdiscv === 'cake' ? _('CAKE average delay, this sample')
					: _('Packets marked ECN instead of dropped. Dash: no marking.') },
					qdiscv === 'cake' ? _('Delay') : _('ECN marks')),
				E('th', { 'class': 'r', 'title': _('Packets dropped by the class or its queue (the larger)') }, _('Drops')),
				E('th', { 'class': 'r' }, _('Backlog')),
				E('th', { 'class': 'r' }, _('Sent')),
				E('th', { 'class': 'r' }, _('Packets'))
			]);
			P.node = E('div', {}, [
				P.cards,
				E('div', { 'class': 'cbi-section qos-ex-card' }, [
					E('h3', { 'class': 'qos-ex-card-title' }, [ label, ' — ',
						E('span', { 'class': 'qos-ex-muted' }, h.qdiscDisplay(qdiscv)) ]),
					P.thr.node, P.chips, P.dly.node
				]),
				E('div', { 'class': 'cbi-section qos-ex-card' }, [
					E('h3', { 'class': 'qos-ex-card-title' }, [ label, ' — ', cntLabel ]),
					E('div', { 'class': 'qos-ex-ctbl-wrap' },
						E('table', { 'class': 'qos-ex-tbl qos-ex-ctbl' }, [ E('thead', {}, head), P.tbody, P.tfoot ]))
				]),
				E('div', { 'class': 'cbi-section qos-ex-card' }, [
					E('h3', { 'class': 'qos-ex-card-title' }, [ label, ' — ',
						qdiscv === 'cake' ? _('CAKE tins') : _('Queue details'),
						E('span', { 'class': 'qos-ex-muted' }, [ ' (' + tcName + ')' ]) ]),
					P.detail
				])
			]);
			return P;
		}
		view.pane = {
			down: mkPane('down', _('Download'), 'ingress · ' + (cs.meta.ifb || 'IFB')),
			up:   mkPane('up',   _('Upload'),   'egress · ' + (cs.meta.wan || 'WAN'))
		};

		// Class id -> the name the counters give it, per direction.
		function namesFor(d) {
			var m = {};
			(view.rowsNow[d] || []).forEach(function(r) { if (r.id) m[r.id] = r.name; });
			return m;
		}
		// CAKE tins / HFSC and HTB classes, shown in full on both panes.
		function paintDetail() {
			var t = view.lastTc, prio = view.cur.meta.cake_prio || uci.get('qos-ex', 'cake', 'priority') || 'diffserv4';
			[ [ 'down', 'ingress' ], [ 'up', 'egress' ] ].forEach(function(p) {
				h.morphKids(view.pane[p[0]].detail, tcDetail(t && t[p[1]], prio, namesFor(p[0])));
			});
		}

		ingest(cs, null);
		paintAll();

		// ---- live cadence -----------------------------------------------
		// On LuCI's own poll loop at the chosen interval:
		// the handler is re-registered when the interval changes, and pause
		// removes it. One sample at a time -- a slow reply throttles the
		// cadence instead of queueing -- and a hidden browser tab samples
		// nothing: LuCI's loop keeps ticking in the background (a plain
		// setInterval), so the handler skips while document.hidden.
		var RATES = [ [ 1, _('1s') ], [ 2, _('2s') ], [ 5, _('5s') ], [ 10, _('10s') ], [ 0, _('pause') ] ];
		var graphSec = h.liveRate('stats'), busy = false, handler = null;

		function chartNote(msg) {
			DIRS.forEach(function(d) { h.setText(view.pane[d].thr.note, msg); });
		}

		function sample() {
			if (busy) return Promise.resolve();
			busy = true;
			return h.liveSample().then(function(res) {
				var r = res[0];
				busy = false;
				if (r._err) { chartNote(_('backend error — ') + r._err); return; }
				var c = h.parseCounters(r.output || '');
				// Distinguish "nothing to draw" from "not drawing". No rows
				// means the backend's stats output carried no @@COUNTERS@@
				// block -- the shaper is stopped, or its counters are off.
				var have = ((c.rows.up && c.rows.up.length) ||
				            (c.rows.down && c.rows.down.length));
				chartNote(have ? '' : _('no per-class counters in stats output'));
				view.cur = c;
				view.lastTc = res[1];
				ingest(c, res[1]);
				paintAll();
				paintDetail();
			}).catch(function() { busy = false; });
		}

		function arm() {
			if (handler) { poll.remove(handler); handler = null; }
			if (graphSec > 0) {
				handler = function() { return document.hidden ? Promise.resolve() : sample(); };
				poll.add(handler, graphSec);
			}
		}
		arm();
		// First extra sample straight away: a rate needs two samples to exist,
		// so without this the graph is empty until the first interval elapses.
		setTimeout(sample, 250);

		var rateSel = E('select', { 'class': 'cbi-input-select' },
			RATES.map(function(r) {
				return E('option', { 'value': String(r[0]) }, r[1]);
			}));
		rateSel.value = String(graphSec);
		rateSel.addEventListener('change', function(ev) {
			graphSec = parseInt(ev.target.value, 10) || 0;
			h.liveRateSet('stats', graphSec);
			arm();
			chartNote(graphSec > 0 ? '' : _('paused'));
			if (graphSec > 0) sample();
		});
		// The charts draw at the box's pixel width: repaint when it changes.
		// The listener removes itself once the view is gone.
		var rz = null;
		function onResize() {
			if (!document.body.contains(view.pane.down.node)) { window.removeEventListener('resize', onResize); return; }
			if (rz) return;
			rz = window.requestAnimationFrame(function() { rz = null; paintAll(); });
		}
		window.addEventListener('resize', onResize);

		// Download (ingress, IFB) and Upload (egress, WAN) on stock LuCI tabs.
		var panes = [ [ _('Download'), view.pane.down.node ], [ _('Upload'), view.pane.up.node ] ];
		var tabs = E('ul', { 'class': 'cbi-tabmenu' });
		function show(k) {
			panes.forEach(function(p, n) {
				p[1].style.display = (n === k) ? '' : 'none';
				tabs.children[n].className = (n === k) ? 'cbi-tab' : 'cbi-tab-disabled';
			});
			// A pane painted while hidden had no width to measure.
			paintAll();
		}
		panes.forEach(function(p, n) {
			tabs.appendChild(E('li', {}, E('a', { 'href': '#', 'click': function(ev) { ev.preventDefault(); show(n); } }, p[0])));
		});
		// The cadence control governs every number on this page: it sits in
		// the tab bar, at its right end (show() only touches the two tabs).
		tabs.appendChild(E('li', { 'class': 'qx-tabtools' },
			E('label', { 'class': 'qos-ex-chart-rate' }, [ _('refresh '), rateSel ])));
		show(0);
		// First paint happens before the view is in the document (no width):
		// paint again once it is.
		window.requestAnimationFrame(paintAll);

		return E([], [
			h.pageHead(_('Stats')),
			tabs,
			panes[0][1],
			panes[1][1]
		]);
	},

	handleSave: null, handleSaveApply: null, handleReset: null
});
