'use strict';
'require baseclass';
'require rpc';
'require uci';
'require ui';
'require poll';
'require dom';

// Shared module for every QoS-Ex page and the Status -> Overview tile
// (view.qos-ex._helpers). Loading it injects qos-ex.css and, on QoS-Ex
// pages only, auto-expires notifications and puts up the banner above the
// tabs (pageHead adds the update note). The class it returns holds the RPC
// declarations, parsers, formatters and the widgets the pages share.

// Auto-expire notification banners. Every "applied / saved / failed" banner
// (ui.addNotification renders .alert-message nodes) fades out on its own
// instead of stacking up until manually dismissed.
//
// SCOPING CONTRACT (same rule the stylesheet follows): LuCI is a single-page
// app, so anything hung off document.body survives navigation to OTHER apps
// until a hard reload. Through 1.0.2.2 this observer armed every
// .alert-message on the page with no origin check, so one visit to QoS-Ex
// silently auto-dismissed notifications in Network, Firewall, System and
// everywhere else for the rest of the session. ui.addNotification does not
// place banners inside our view container, so they cannot be scoped by
// ancestry -- the route is the only honest test, and it is re-checked on
// every arm() rather than once at load.
//
// This is also the SINGLE owner of banner lifetime. notify() below used to
// schedule its own removeChild as well, which raced this one: the fade
// started at 5000ms and the other timer ripped the node out at exactly
// 5000ms, so the fade never rendered and danger banners had one timer
// saying 8s and another saying 10s.
(function() {
	if (window.__qosExNotifAutoDismiss) return;
	window.__qosExNotifAutoDismiss = true;
	function onQosExPage() {
		try { return /\/qos-ex(\/|$)/.test(location.pathname); }
		catch (e) { return false; }
	}
	function arm(n) {
		if (!onQosExPage()) return;
		if (!n || n.nodeType !== 1 || !n.classList ||
		    !n.classList.contains('alert-message') || n.__qosExArmed)
			return;
		n.__qosExArmed = true;
		// An error or a warning stays until it is dismissed by hand: it may
		// be LuCI's own (a failed apply, an expired session), and one that
		// fades after a few seconds is one nobody read.
		if (n.classList.contains('error') || n.classList.contains('danger') ||
		    n.classList.contains('warning'))
			return;
		var ttl = 5000;
		setTimeout(function() {
			n.style.transition = 'opacity .4s ease';
			n.style.opacity = '0';
			setTimeout(function() {
				if (n.parentNode) n.parentNode.removeChild(n);
			}, 450);
		}, ttl);
	}
	try {
		var mo = new MutationObserver(function(muts) {
			if (!onQosExPage()) return;
			for (var i = 0; i < muts.length; i++) {
				var added = muts[i].addedNodes || [];
				for (var k = 0; k < added.length; k++) {
					arm(added[k]);
					if (added[k].nodeType === 1 && added[k].querySelectorAll)
						added[k].querySelectorAll('.alert-message').forEach(arm);
				}
			}
		});
		mo.observe(document.body, { childList: true, subtree: true });
		document.querySelectorAll('.alert-message').forEach(arm);
	} catch (e) {}
})();

// Inject qos-ex.css once per page — every view that requires this helpers module
// automatically gets the stylesheet. The mjpg-streamer migration guide on
// blog.freifunk.net documents this pattern; it's the JS-framework equivalent
// of <link rel="stylesheet"> in old Lua-MVC templates. The dedup check stops
// repeated injection when several views require this module in the same load.
//
// The ?v= token is the install token (install_views in QoS-Ex-luci-app.sh):
// the version plus the installer's own hash. The URL changes with every
// release and every edit to the installer, and stays put on a reinstall of
// the same one, so the browser fetches the current CSS instead of serving a
// hard-cached stale copy. That stale-cache was
// the cause of the persistent black box behind the home marker: the marker JS
// updated but the old qos-ex.css (without the transparent-container rule) kept
// being reused. Bumping the token sidesteps that for every future CSS change.
//
// L.resource(), not a hardcoded /luci-static: the resource base is a
// configurable LuCI setting (luci.main.resourcebase) and can also be moved by
// a reverse proxy prefix. Hardcoding it made every view render unstyled
// behind a 404 nobody would see on such a box.
var CSS_HREF = L.resource('qos-ex/qos-ex.css') + '?v=__CACHEBUST__';
(function() {
	if (typeof document === 'undefined' || !document.head) return;
	if (document.querySelector('link[href="' + CSS_HREF + '"]')) return;
	var link = document.createElement('link');
	link.rel  = 'stylesheet';
	link.type = 'text/css';
	link.href = CSS_HREF;
	document.head.appendChild(link);
})();

// ---------------------------------------------------------------------
// Scroll stability across auto-refresh repaints.
//
// Stock LuCI repaints straight into the DOM on every poll tick and lets
// the browser keep the reader in place. It never reads or writes the
// document scroll position, and it never disables scroll anchoring. We
// now do the same, because 1.0.0.6's belt-and-braces did more harm than
// the problem it fixed: pageOff()/pageBack() wrote window.scrollTo() on
// EVERY tick of EVERY page, and pageYOffset read on the main thread is
// stale while the compositor is scrolling, so writing it back snapped
// the page out from under the reader once per interval. That, plus
// overflow-anchor:none stopping the browser from compensating on its
// own, is the 5-second hop. Both are gone.
//
// What the browser genuinely cannot do for us is a container that is
// EMPTIED and refilled: dom.content(el, []) removes the node anchoring
// was holding on to and clamps that box's scrollTop to 0. So exactly two
// helpers remain, and both are box-local:
//
//   scrollKeepAll(root, sels, fn) — capture scroll boxes BY SELECTOR, run fn,
//                          put them back. Never touches window scroll.
//   scrollBusy(node)     — true while the user is ACTIVELY driving that
//                          box (wheel / touch / scrollbar drag / keys in
//                          the last SCROLL_HOLD_MS, or a live text
//                          selection inside it). Poll callbacks return
//                          early so the DOM is not yanked mid-gesture.
//
// The guard listens only to genuine input events — never 'scroll' — so
// our own restore never re-arms the hold and starves the refresh. Hover
// is NOT input and no longer counts: a pointer merely resting over a
// table used to freeze it for up to 30s and then land the whole backlog
// in one paint, which read as a jump in its own right.
// scrollArm() is exported for containers that are rebuilt from scratch
// each paint and so cannot stay armed; no view calls it at present (the
// PF dashboard ladder is now built once and kept).
// ---------------------------------------------------------------------
var SCROLL_HOLD_MS = 1500;
var SEL_HOLD_MS    = 10000;
var SCROLL_EVENTS  = ['wheel', 'touchstart', 'touchmove', 'pointerdown', 'mousedown', 'keydown'];

function scrollArm(el) {
	if (!el || el.nodeType !== 1 || el.__qosExScrollArmed) return el;
	el.__qosExScrollArmed = true;
	el.__qosExScrollTouch = 0;
	var mark = function() { el.__qosExScrollTouch = Date.now(); };
	function on(ev, fn) {
		try { el.addEventListener(ev, fn, { passive: true }); }
		catch (e) { el.addEventListener(ev, fn, true); }
	}
	SCROLL_EVENTS.forEach(function(ev) { on(ev, mark); });
	return el;
}

// The scroll box that owns the given node, node itself included -- and nothing
// else. Matched by CLASS against the boxes this app creates, deliberately
// not by computed overflow.
//
// The overflow version escaped. It skipped any ancestor that was not
// CURRENTLY overflowing and kept climbing, so a short table, or the
// raw-text <pre> inside a collapsed <details> (scrollHeight 0), walked
// straight past our box into the theme's own DOM. Anything up there with
// overflow:auto -- material-family themes ship a scrolling content pane,
// and an open LuCI combobox list is another -- came back as "the box",
// after which the restore wrote a stale offset onto the PAGE scroller once
// per refresh and scrollArm hung listeners on it. That is the page
// drifting by itself on live tabs and nowhere else, because live tabs are
// the only ones that call these helpers.
//
// A box that is not overflowing yet is still the right answer: its
// scrollTop is 0 and restoring 0 is a no-op. Matching by class also drops
// a getComputedStyle() per call, i.e. a forced style recalculation on
// every repaint of every box.
//
// Keep this list in step with the overflow:auto rules in qos-ex.css.
var SCROLL_BOXES = [
	'qos-ex-pre', 'pf-serverlist-wrap', 'pf-list-scroll',
	'pf2-ladder-scroll', 'pf-devbox', 'pf-popup-scroll', 'qos-ex-sbox'
];

function scrollHost(node) {
	var el = (typeof node === 'function') ? node() : node;
	for (var i = 0; el && el.nodeType === 1 && i < 8; el = el.parentNode, i++) {
		if (!el.classList) continue;
		for (var j = 0; j < SCROLL_BOXES.length; j++)
			if (el.classList.contains(SCROLL_BOXES[j])) return el;
	}
	return null;
}

function scrollHeld(el) {
	if (!el) return false;
	if (Date.now() - (el.__qosExScrollTouch || 0) < SCROLL_HOLD_MS) return true;
	// A live selection inside the box dies the instant we swap content.
	var sel = (typeof window !== 'undefined' && window.getSelection) ? window.getSelection() : null;
	if (sel && sel.rangeCount && !sel.isCollapsed) {
		var n = sel.anchorNode;
		if (n && n.nodeType !== 1) n = n.parentNode;
		// ...but not forever. A selection left behind by a double-click on
		// an IP froze the Dashboard indefinitely; after SEL_HOLD_MS the
		// refresh wins, as it does everywhere else in LuCI.
		if (n && el.contains(n)) {
			if (!el.__qosExSelAt) el.__qosExSelAt = Date.now();
			return (Date.now() - el.__qosExSelAt) < SEL_HOLD_MS;
		}
	}
	el.__qosExSelAt = 0;
	return false;
}

// ---------------------------------------------------------------------
// Last-known replies, for instant tab switches.
//
// Every LuCI tab is a full page load, and load() holds the page on the
// spinner until its slowest RPC answers -- for status and pf_servers that
// is a fork of a 250KB shell script, a second or more on an 880MHz
// MT7621, on every click. The replies the polls already fetch are kept in
// sessionStorage (this browser tab only, gone when it closes), so the next
// view can paint from one at once and replace it on its first poll.
//
// Only a view that repaints EVERYTHING from each poll may take a cached
// reply (h.loadC): a view that renders once and polls a corner would keep
// the stale part forever, and a view that picks its whole layout from the
// reply (Map setup mode, the Servers page's disabled notice) would keep the
// wrong layout. Storage can throw (private mode, quota, blocked site
// data); every access is wrapped, and a miss is simply a normal load.
// ---------------------------------------------------------------------
var CACHE_PFX = 'qosex:', CACHE_MAX_MS = 60000;

function cacheGet(key, anyAge) {
	try {
		var o = JSON.parse(window.sessionStorage.getItem(CACHE_PFX + key) || 'null');
		if (!o || typeof o.t !== 'number' || (!anyAge && (Date.now() - o.t) > CACHE_MAX_MS)) return null;
		return o.v;
	} catch (e) { return null; }
}

function cachePut(key, v) {
	if (!v || typeof v !== 'object' || v._err || v.error) return;
	// The shim's stand-in for a failed Ping Filter call (no master_enabled)
	// is not a state to start the next page from.
	if (key === 'pf_servers' && v.master_enabled == null) return;
	try { window.sessionStorage.setItem(CACHE_PFX + key, JSON.stringify({ t: Date.now(), v: v })); }
	catch (e) {}
}

// A light poll verb (backend 3.0.6.0+), falling back to the full one when
// the reply lacks its marker -- an older backend answers an unknown verb
// with its usage text -- or the call fails outright.
function lightOr(light, full, mark) {
	return function() {
		return light().then(function(r) {
			return (r && String(r.output || '').indexOf(mark) >= 0) ? r : full();
		}, function() { return full(); });
	};
}

// Every successful reply refreshes the cache, whichever view made the call.
function cacheTap(key, fn) {
	return function() {
		return fn.apply(this, arguments).then(function(r) { cachePut(key, r); return r; });
	};
}

// ---- Ping Filter live chart (Dashboard; a small one on the Overview) -----
// Built like the Stats charts: the SVG viewBox follows the box's pixel width
// (axis text is never stretched), x is real time from the ring's timestamps
// (a break in play is a break in the line), hover gives a crosshair +
// tooltip. The chart node is made once per view and kept, so hover survives
// a poll. mini: no axes, grid or labels, 72px high.
var C_LAT = '#D85A30', C_JIT = '#378ADD', C_PPS = '#7cb0d0', CH_GAP = 20;
var CH_FULL = { l: 46, r: 8, t: 10, b: 20, h: 170 }, CH_MINI = { l: 2, r: 2, t: 6, b: 4, h: 72 };

function pfSvg(name, attrs) {
	var el = document.createElementNS('http://www.w3.org/2000/svg', name);
	for (var k in attrs) if (attrs[k] != null) el.setAttribute(k, attrs[k]);
	return el;
}
// Scale top rounded to a 1/2/2.5/5 x 10^n step (readable gridlines).
function pfScale(v) {
	if (!(v > 0)) v = 1;
	var raw = v / 4, p = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10)), m = raw / p;
	var step = p * (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10);
	return { max: Math.ceil(v / step - 1e-9) * step, step: step };
}
// Path through the points. Each control point shares its end point's y, so
// the curve never overshoots a sample: no dip below zero, no false peak.
function pfCurve(pts, move) {
	var s = '';
	for (var i = 0; i < pts.length; i++) {
		var x = pts[i][0].toFixed(1), y = pts[i][1].toFixed(1);
		if (!i) { s += (move ? 'M' : 'L') + x + ',' + y; continue; }
		var xm = ((pts[i - 1][0] + pts[i][0]) / 2).toFixed(1);
		s += 'C' + xm + ',' + pts[i - 1][1].toFixed(1) + ' ' + xm + ',' + y + ' ' + x + ',' + y;
	}
	return s;
}
function pfSpan(s) { return s < 120 ? Math.round(s) + ' s' : (+(s / 60).toFixed(1)) + ' min'; }

function pfMakeChart(mini) {
	var G = mini ? CH_MINI : CH_FULL;
	var svg = pfSvg('svg', { 'class': 'qos-ex-chart' + (mini ? ' qx-chart-mini' : ''), 'style': 'height:' + G.h + 'px', 'viewBox': '0 0 680 ' + G.h });
	var body = pfSvg('g', {});
	var cross = pfSvg('line', { 'class': 'qos-ex-ch-cross', 'y1': G.t, 'y2': G.h - G.b, 'visibility': 'hidden' });
	svg.appendChild(body); svg.appendChild(cross);
	var ch = { svg: svg, body: body, cross: cross, W: 680, hx: null, last: null, G: G, mini: !!mini,
		tip: E('div', { 'class': 'qos-ex-ch-tip' }),
		empty: E('div', { 'class': 'qos-ex-muted', 'style': 'font-size:11.5px;padding:18px 0;text-align:center' },
			_('Waiting for live packets from a match.')) };
	ch.plot = E('div', { 'class': 'qos-ex-ch-plot' }, [ svg, ch.tip ]);
	ch.node = E('div', { 'class': 'pf2-spark' }, [ ch.plot, ch.empty ]);
	svg.addEventListener('mousemove', function(ev) {
		ch.hx = ev.clientX - svg.getBoundingClientRect().left; pfHover(ch);
	});
	svg.addEventListener('mouseleave', function() { ch.hx = null; pfHover(ch); });
	return ch;
}

function pfHover(ch) {
	var Lh = ch.last;
	if (ch.hx == null || !Lh) {
		ch.cross.setAttribute('visibility', 'hidden');
		ch.tip.style.display = 'none';
		return;
	}
	var b = 0;
	for (var i = 1; i < Lh.xs.length; i++)
		if (Math.abs(Lh.xs[i] - ch.hx) < Math.abs(Lh.xs[b] - ch.hx)) b = i;
	var x = Lh.xs[b];
	ch.cross.setAttribute('x1', x); ch.cross.setAttribute('x2', x);
	ch.cross.setAttribute('visibility', 'visible');
	dom.content(ch.tip, Lh.tip(b));
	ch.tip.style.display = 'block';
	var tw = ch.tip.offsetWidth;
	ch.tip.style.left = (x + 14 + tw > ch.W ? Math.max(0, x - tw - 14) : x + 14) + 'px';
}

// tele.samples = [{ ts, pps, bps, jitter, rtt }]. Latency = the measured
// RTT when the sample carries one, else ping baseline + jitter. limit = the
// active ping limit in ms (0 = none), drawn as a dashed reference.
function pfPaintChart(ch, tele, basePing, limit) {
	var S = (tele && tele.samples) || [], n = S.length;
	ch.plot.style.display = n < 2 ? 'none' : '';
	ch.empty.style.display = n < 2 ? '' : 'none';
	if (n < 2) { ch.last = null; pfHover(ch); return; }
	var W = Math.round(ch.svg.getBoundingClientRect().width) || ch.W;
	ch.W = W;
	var G = ch.G, PAD_L = G.l, PAD_R = G.r, PAD_T = G.t, PAD_B = G.b;
	var H = G.h, pw = W - PAD_L - PAD_R, ph = H - PAD_T - PAD_B;
	ch.svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
	var base = (basePing > 0) ? basePing : 0;
	var now = S[n - 1].ts, span = Math.max(60, now - S[0].ts), mx = 0, mp = 0;
	var lat = S.map(function(x) { return (x.rtt > 0) ? x.rtt : (base + (x.jitter || 0)); });
	S.forEach(function(x, i) { mx = Math.max(mx, lat[i], x.jitter || 0); mp = Math.max(mp, x.pps || 0); });
	var top = Math.max(mx * 1.15, 20);
	if (limit > 0 && limit <= mx * 1.6) top = Math.max(top, limit * 1.05);
	var sc = pfScale(top);
	function Y(v) { return PAD_T + ph * (1 - Math.min(1, Math.max(0, v) / sc.max)); }
	var xs = S.map(function(x) { return PAD_L + pw * (1 - (now - x.ts) / span); });
	// One point list per unbroken run of samples.
	function runs(val) {
		var out = [], seg = [];
		S.forEach(function(x, i) {
			if (i && x.ts - S[i - 1].ts > CH_GAP) { out.push(seg); seg = []; }
			seg.push([ xs[i], val(x, i) ]);
		});
		out.push(seg);
		return out.filter(function(r) { return r.length > 1; });
	}
	function line(val, col, w) {
		var d = runs(val).map(function(r) { return pfCurve(r, true); }).join('');
		if (d) g.appendChild(pfSvg('path', { 'd': d, 'fill': 'none', 'stroke': col, 'stroke-width': w,
			'stroke-linejoin': 'round', 'stroke-linecap': 'round' }));
	}
	var g = pfSvg('g', {}), t, v, y;
	// Packet rate backdrop: relative to its own peak, lower 60% of the plot.
	if (mp > 0) runs(function(x) { return PAD_T + ph * (1 - 0.6 * (x.pps || 0) / mp); }).forEach(function(r) {
		g.appendChild(pfSvg('path', { 'd': pfCurve(r, true) + 'L' + r[r.length - 1][0].toFixed(1) + ',' + Y(0).toFixed(1) +
			'L' + r[0][0].toFixed(1) + ',' + Y(0).toFixed(1) + 'Z', 'fill': C_PPS, 'fill-opacity': '0.16', 'stroke': 'none' }));
	});
	for (v = 0; !ch.mini && v <= sc.max + sc.step / 2; v += sc.step) {
		y = Y(v).toFixed(1);
		g.appendChild(pfSvg('line', { 'class': v ? 'qos-ex-ch-grid' : 'qos-ex-ch-base',
			'x1': PAD_L, 'x2': W - PAD_R, 'y1': y, 'y2': y }));
		t = pfSvg('text', { 'class': 'qos-ex-ch-ax', 'x': PAD_L - 6, 'y': (+y + 3.5).toFixed(1), 'text-anchor': 'end' });
		t.textContent = (+v.toFixed(1)) + (v ? '' : ' ms');
		g.appendChild(t);
	}
	(ch.mini ? [] : [ [ PAD_L, 'start', '−' + pfSpan(span) ], [ PAD_L + pw / 2, 'middle', '−' + pfSpan(span / 2) ],
	  [ W - PAD_R, 'end', _('now') ] ]).forEach(function(a) {
		t = pfSvg('text', { 'class': 'qos-ex-ch-ax', 'x': a[0].toFixed(1), 'y': H - 5, 'text-anchor': a[1] });
		t.textContent = a[2];
		g.appendChild(t);
	});
	if (limit > 0 && limit <= sc.max) {
		y = Y(limit).toFixed(1);
		g.appendChild(pfSvg('line', { 'class': 'qos-ex-ch-ref', 'x1': PAD_L, 'x2': W - PAD_R, 'y1': y, 'y2': y }));
		if (!ch.mini) {
			t = pfSvg('text', { 'class': 'qos-ex-ch-ax', 'x': W - PAD_R, 'y': (+y - 4).toFixed(1), 'text-anchor': 'end' });
			t.textContent = _('limit') + ' ' + limit + ' ms';
			g.appendChild(t);
		}
	}
	line(function(x) { return Y(x.jitter || 0); }, C_JIT, '1.2');
	line(function(x, i) { return Y(lat[i]); }, C_LAT, '2');
	g.appendChild(pfSvg('circle', { 'cx': xs[n - 1].toFixed(1), 'cy': Y(lat[n - 1]).toFixed(1), 'r': 3, 'fill': C_LAT }));
	ch.svg.replaceChild(g, ch.body);
	ch.body = g;
	function row(col, label, val) {
		return E('div', {}, [ E('i', { 'class': 'sw', 'style': 'background:' + col }), label + ' ', E('b', {}, val) ]);
	}
	ch.last = { xs: xs, tip: function(i) {
		var d = now - S[i].ts;
		return [ E('div', { 'class': 'qos-ex-muted' }, d < 1 ? _('now') : pfSpan(d) + ' ' + _('ago')),
			row(C_LAT, _('latency'), lat[i] + ' ms'),
			row(C_JIT, _('jitter'), (S[i].jitter || 0) + ' ms'),
			row(C_PPS, _('packets/s'), String(S[i].pps || 0)) ];
	} };
	pfHover(ch);
}

// ---- tc text (HFSC / HTB) -> qdisc and class records --------------------
function tcBps(v) {
	var m = String(v || '').match(/^([\d.]+)([KMGT]?)bit$/);
	return m ? +m[1] * ({ K: 1e3, M: 1e6, G: 1e9, T: 1e12 }[m[2]] || 1) : 0;
}
// HFSC prints "sc" when rt == ls; a curve is [m1 <rate>] [d <time>] m2 <rate>.
function parseTcText(txt) {
	var out = { qdisc: [], 'class': [] }, cur = null, U = { K: 1024, M: 1048576, G: 1073741824 };
	var KV = /\b(period|work|rtwork|level|maxpacket|drop_overlimit|new_flow_count|ecn_mark|new_flows_len|old_flows_len|lended|borrowed|giants|(?:prob|forced)_mark(?:_head)?):? (\d+)/g;
	String(txt || '').split('\n').forEach(function(l) {
		var m = l.match(/^(qdisc|class) (\S+) (\S+)(.*)$/), k;
		if (m) {
			var rest = m[4] + ' ';
			cur = { handle: m[3], kind: m[2], sc: {} };
			if ((k = rest.match(/ parent (\S+)/))) cur.parent = k[1];
			if ((k = rest.match(/ leaf (\S+)/))) cur.leaf = k[1];
			if ((k = rest.match(/ rate (\S+)/))) cur.rate = tcBps(k[1]);
			if ((k = rest.match(/ ceil (\S+)/))) cur.ceil = tcBps(k[1]);
			if ((k = rest.match(/ limit (\d+)p /))) cur.limit_p = +k[1];
			else if ((k = rest.match(/ limit ([\d.]+)([KMG]?)b /))) cur.limit_b = Math.round(+k[1] * (U[k[2]] || 1));
			[ 'sc', 'rt', 'ls', 'ul' ].forEach(function(n) {
				var x = rest.match(new RegExp(' ' + n + ' (?:m1 (\\S+) )?(?:d (\\S+) )?m2 (\\S+)'));
				if (x) cur.sc[n] = { m1: tcBps(x[1]), d: x[2] || '', m2: tcBps(x[3]) };
			});
			if (cur.sc.sc) { cur.sc.rt = cur.sc.ls = cur.sc.sc; delete cur.sc.sc; }
			out[m[1]].push(cur);
			return;
		}
		if (!cur) return;
		if ((m = l.match(/backlog ([\d.]+)([KMG]?)b (\d+)p/))) { cur.backlog = Math.round(+m[1] * (U[m[2]] || 1)); cur.qlen = +m[3]; }
		if ((m = l.match(/Sent (\d+) bytes (\d+) pkt \(dropped (\d+), overlimits (\d+)/))) {
			cur.sent_bytes = +m[1]; cur.sent_pkts = +m[2]; cur.dropped = +m[3]; cur.overlimits = +m[4];
		}
		KV.lastIndex = 0;
		// sfq RED (Auto) reports its ECN marks as prob_mark/forced_mark (+ _head).
		while ((m = KV.exec(l)))
			if (/^(prob|forced)_/.test(m[1])) cur.ecn_mark = (cur.ecn_mark || 0) + +m[2];
			else cur[m[1]] = +m[2];
	});
	return out;
}

// ---- one conntrack row of the backend's table ----------------------------
function ctRow(line) {
	var f = line.split('\t');
	if (f.length < 9) return null;
	var pkts  = parseInt(f[6], 10) || 0;
	var bytes = parseInt(f[7], 10) || 0;
	// Fields 10-11 are the ORIGINAL conntrack direction, which for a
	// LAN-initiated flow is the upload. A backend that predates them
	// reports totals only; treating the whole flow as upload would be a
	// lie, so leave both directions at zero and let the row show totals.
	var hasDir = (f.length >= 11);
	var upPkts  = hasDir ? (parseInt(f[9],  10) || 0) : 0;
	var upBytes = hasDir ? (parseInt(f[10], 10) || 0) : 0;
	// Fields 12-16 (shaper 3.0.9.4+): reply tuple, TCP state, timeout, flags.
	var ext = (f.length >= 16), dash = function(v) { return v === '-' ? '' : v; };
	return {
		rsrc: ext ? dash(f[11]) : '', rdst: ext ? dash(f[12]) : '',
		state: ext ? dash(f[13]) : '', tmo: ext ? (parseInt(f[14], 10) || 0) : 0,
		fl: ext ? dash(f[15]) : '',
		proto: f[0], src: f[1], sport: f[2],
		dst:   f[3], dport: f[4], dscp:  f[5],
		pkts: pkts, bytes: bytes, fam: f[8],
		hasDir: hasDir,
		upPkts: upPkts, upBytes: upBytes,
		dnPkts:  Math.max(0, pkts  - upPkts),
		dnBytes: Math.max(0, bytes - upBytes)
	};
}

var PF_STATE_TXT = { allowed: _('allowed'), blocked: _('blocked'), whitelist: _('always allowed'),
	blacklist: _('always blocked'), cached: _('cached') };

return baseclass.extend({
	callStatus:    cacheTap('status', rpc.declare({ object: 'qos-ex', method: 'status' })),
	// Poll-sized versions of status and stats: the runtime flags only, and
	// the counters only. See state() / counters() in QoS-Ex.sh.
	callState:     cacheTap('state', lightOr(
		rpc.declare({ object: 'qos-ex', method: 'state'  }),
		rpc.declare({ object: 'qos-ex', method: 'status' }), '@@STATE@@')),
	callCounters:  lightOr(
		rpc.declare({ object: 'qos-ex', method: 'counters' }),
		rpc.declare({ object: 'qos-ex', method: 'stats'    }), '@@COUNTERS@@'),
	callLive:      rpc.declare({ object: 'qos-ex', method: 'live' }),
	callNfterr:    cacheTap('nfterr', rpc.declare({ object: 'qos-ex', method: 'nfterr' })),
	callLogdump:   rpc.declare({ object: 'qos-ex', method: 'logdump',   params: [ 'lines', 'src' ] }),
	callDebug:     rpc.declare({ object: 'qos-ex', method: 'debug'      }),
	callRuleset:   rpc.declare({ object: 'qos-ex', method: 'ruleset'    }),
	callConntrack: rpc.declare({ object: 'qos-ex', method: 'conntrack', params: [ 'max' ] }),
	callHostHints: rpc.declare({ object: 'luci-rpc', method: 'getHostHints', expect: { '': {} } }),
	callNetDevices: rpc.declare({ object: 'luci-rpc', method: 'getNetworkDevices', expect: { '': {} } }),
	callAction:    rpc.declare({ object: 'qos-ex', method: 'action',    params: [ 'verb' ] }),
	callPfStatus:  cacheTap('pf_status',  rpc.declare({ object: 'qos-ex', method: 'pf_status'  })),
	callPfServers: cacheTap('pf_servers', rpc.declare({ object: 'qos-ex', method: 'pf_servers' })),
	callPfTelemetry: rpc.declare({ object: 'qos-ex', method: 'pf_telemetry', params: [ 'ip' ] }),
	callPfAction:  rpc.declare({ object: 'qos-ex', method: 'pf_action', params: [ 'verb', 'ip', 'ms' ] }),
	callPfText:    rpc.declare({ object: 'qos-ex', method: 'pf_text',   params: [ 'verb', 'ip' ] }),
	// pf_run is pf_text's mutating half. Same {"output":"..."} shape, but it
	// is granted under the ACL's write section because these verbs change
	// state -- scan, clear, refresh_lists, session_reset, reclassify --
	// plus geo_check and livecap,
	// which reach out to the network. Keep the split: routing any of
	// them back through pf_text hands them to read-only ACL holders.
	callPfRun:     rpc.declare({ object: 'qos-ex', method: 'pf_run',    params: [ 'verb', 'ip' ] }),
	callPfSetHome: rpc.declare({ object: 'qos-ex', method: 'pf_set_home', params: [ 'lat', 'lon', 'radius_km', 'mode' ] }),
	callPfLists:   rpc.declare({ object: 'qos-ex', method: 'pf_lists'   }),
	callPfSessions: rpc.declare({ object: 'qos-ex', method: 'pf_sessions' }),
	callCfgExport: rpc.declare({ object: 'qos-ex', method: 'cfg_export' }),
	callCfgImport: rpc.declare({ object: 'qos-ex', method: 'cfg_import', params: [ 'data' ] }),
	// Updates: latest versions on GitHub main (cached on the router), the
	// one-click upgrade (write ACL) and its log.
	callUpdateCheck: rpc.declare({ object: 'qos-ex', method: 'update_check', params: [ 'force', 'inst' ] }),
	callUpdateCfg:   rpc.declare({ object: 'qos-ex', method: 'update_cfg', params: [ 'on' ] }),
	callUpdateBranch: rpc.declare({ object: 'qos-ex', method: 'update_branch', params: [ 'branch' ] }),
	callUpdateRun:   rpc.declare({ object: 'qos-ex', method: 'update_run' }),
	callUpdateLog:   rpc.declare({ object: 'qos-ex', method: 'update_log' }),
	callUninstallRun: rpc.declare({ object: 'qos-ex', method: 'uninstall_run' }),
	// Auto Setup: probe / hw / result (read); suggest / speedtest / apply /
	// undo / skip (write ACL -- suggest saves the file apply reads, so a
	// read-only session must not be able to rewrite it).
	callAutosetup:    rpc.declare({ object: 'qos-ex', method: 'autosetup', params: [ 'verb' ] }),
	callAutosetupRun: rpc.declare({ object: 'qos-ex', method: 'autosetup_run', params: [ 'verb', 'keys', 'down', 'up' ] }),
	// A progress bar in a modal, as Update now: steps [ label, %, fn ] run in
	// turn (fn returns a promise) and the bar creeps towards each step's % while
	// it runs. Then 100% Complete (plus the last step's text, if it returns
	// one) for 2 s, then done(). A failed step closes the modal and rejects.
	progressRun: function(title, steps, done) {
		var h = this, txt = E('span'), pct = E('strong', { 'style': 'float:right' }), bar = E('i');
		var at = 0, to = 0;
		function paint(p, label) {
			at = p;
			h.setText(pct, p + '%');
			bar.style.width = p + '%';
			if (label != null) h.setText(txt, label);
		}
		ui.showModal(title, [ E('div', {}, [ txt, pct ]),
			E('div', { 'class': 'qx-meter', 'style': 'height:8px;margin-top:6px' }, bar) ]);
		var tick = window.setInterval(function() { if (at < to - 1) paint(at + 1); }, 500);
		return steps.reduce(function(chain, s, i) {
			return chain.then(function() {
				paint(i ? steps[i - 1][1] : 0, s[0]);
				to = s[1];
				return s[2]();
			});
		}, Promise.resolve()).then(function(v) {
			window.clearInterval(tick);
			paint(100, _('Complete') + (typeof v === 'string' && v ? ' — ' + v : ''));
			return new Promise(function(ok) { window.setTimeout(ok, 2000); });
		}).then(function() { done(); }, function(e) {
			window.clearInterval(tick);
			ui.hideModal();
			throw e;
		});
	},
	// A Live page's refresh in seconds (0 = paused), per page ('stats',
	// 'flows'): 1 s until the user picks another, which is kept in this
	// browser (localStorage) and used from then on. Storage can throw.
	liveRate: function(page) {
		var v = NaN, d = NaN;
		try { v = parseInt(window.localStorage.getItem('qosex:rate:' + page), 10); } catch (e) {}
		if ([ 0, 1, 2, 5, 10 ].indexOf(v) >= 0) return v;
		// No pick in this browser: the router's default (settings.live_refresh;
		// Auto Setup puts 2 s on a low-spec router), else 1 s.
		try { d = parseInt(uci.get('qos-ex', 'settings', 'live_refresh'), 10); } catch (e) {}
		return [ 1, 2, 5, 10 ].indexOf(d) >= 0 ? d : 1;
	},
	liveRateSet: function(page, sec) {
		try { window.localStorage.setItem('qosex:rate:' + page, String(sec)); } catch (e) {}
	},
	// Wait (up to secs, 30 by default) until the shaper runs, or is off.
	waitShaper: function(secs) {
		var h = this, n = 0, max = secs || 30;
		return new Promise(function(ok, bad) {
			(function poll() {
				var again = function() {
					if (++n >= max) bad(new Error(_('the shaper did not start - see System → Status')));
					else window.setTimeout(poll, 1000);
				};
				h.callState().then(function(r) {
					var s = h.parseState((r && r.output) || '').state;
					if (s.enabled != null && (s.enabled !== '1' || h.running(s))) ok(s);
					else again();
				}, again);
			})();
		});
	},
	// Settings backup: QoS-Ex Settings.cfg (header, hash, then the settings).
	cfgBackup: function() {
		var h = this;
		return h.callCfgExport().then(function(r) {
			var txt = (r && r.output) || '';
			if (txt.indexOf('# QoS-Ex settings\n') !== 0) throw new Error('?');
			var a = E('a', { 'download': 'QoS-Ex Settings.cfg',
				'href': URL.createObjectURL(new Blob([ txt ], { type: 'text/plain' })) });
			document.body.appendChild(a); a.click();
			window.setTimeout(function() { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
		}).catch(function() { h.notifyErr(_('Backup failed')); });
	},
	// Restore: pick a settings file (.cfg; .qosex or .txt from older
	// versions), confirm, send; the router checks it and restarts QoS-Ex.
	// The bar waits for the shaper, then QoS-Ex opens on its first tab (Auto
	// Setup when the file says it is not done, else the Overview).
	cfgRestore: function() {
		var h = this;
		var fi = E('input', { 'type': 'file', 'accept': '.cfg,.qosex,.txt', 'style': 'display:none', 'change': function() {
			var f = fi.files && fi.files[0];
			fi.remove();
			if (!f) return;
			if (f.size > 65536) { h.notifyErr(_('Restore failed') + ': ' + _('not a QoS-Ex settings file')); return; }
			var rd = new FileReader();
			rd.onload = function() {
				if (!confirm(_('Replace the settings with %s? QoS-Ex turns on or off as it says.').format(f.name))) return;
				var old = false;
				h.progressRun(_('Restore settings'), [
					[ _('Checking and saving the settings'), 60, function() {
						return h.callCfgImport(String(rd.result || '')).then(function(r) {
							if (!(r && r.ok)) throw new Error((r && r.error) || _('rc=') + ((r && r.rc) || '?'));
							old = !!r.old;
						});
					} ],
					[ _('Restarting QoS-Ex'), 95, function() {
						return h.waitShaper().then(function() {
							return old ? _('an older backup: download a new one') : '';
						});
					} ]
				], function() { h.menuGo([]); })
					.catch(function(e) { h.notifyErr(_('Restore failed') + ': ' + ((e && e.message) || e)); });
			};
			rd.readAsText(f);
		} });
		document.body.appendChild(fi);
		fi.click();
	},

	// Open a page after autosetup.done changed (Auto Setup applied or
	// skipped, Run Auto Setup, Reset, a restore). The Auto Setup tab shows
	// only while done is 0; the router has dropped its built menu, and the
	// copy this browser tab keeps goes too, so the next page has the right
	// tabs. path as tabUrl; [] = QoS-Ex's first tab.
	menuGo: function(path) {
		try { ui.menu.flushCache(); } catch (e) {}
		window.location.href = this.tabUrl(path || []);
	},

	// Dotted versions, numerically per part: 1 if a > b, -1 if a < b.
	verCmp: function(a, b) {
		var x = String(a || '').split('.'), y = String(b || '').split('.');
		for (var i = 0; i < Math.max(x.length, y.length); i++) {
			var d = (parseInt(x[i], 10) || 0) - (parseInt(y[i], 10) || 0);
			if (d) return d > 0 ? 1 : -1;
		}
		return 0;
	},
	// Keys of `loc` ({ shaper, pf, luci } installed versions) that GitHub
	// (`r`, an update_check reply) has newer, by module: app, Ping Filter,
	// shaper. A component not installed is not an update.
	updNewer: function(r, loc) {
		var self = this;
		return [ 'luci', 'pf', 'shaper' ].filter(function(k) {
			return r && r[k] && loc[k] && self.verCmp(r[k], loc[k]) > 0;
		});
	},
	// Components with a newer version on GitHub, by the router's cached
	// automatic check ([] when off, failed or up to date). For pages with
	// no status of their own: the Status-page tile.
	updAvail: function() {
		var self = this;
		return this.callUpdateCheck(0, 1).then(function(r) {
			return !r || r.off || r.error || !r.checked ? [] : self.updNewer(r,
				{ shaper: r.i_shaper, pf: r.i_pf, luci: '__VERSION__'.replace(/^v/, '') });
		}).catch(function() { return []; });
	},
	// The "update available" note over a page's controls (row: pageHead's
	// row), from the router's cached automatic check: off or nothing newer
	// draws nothing. Overview and Maintenance show their own. Asked by each
	// page as it renders: a theme that swaps pages without a page load
	// (footstrap) loads this module once.
	updNote: function(row) {
		var p = (L.env && L.env.dispatchpath) || [], last = p[p.length - 1];
		if (last === 'qos-ex' || last === 'overview' || last === 'maintenance') return;
		this.updAvail().then(function(newer) {
			if (!newer.length) return;
			var el = E('div', { 'class': 'qos-ex-upd-banner' }, [ '⬆ ', _('QoS-Ex update available'), ' · ',
				E('a', { 'href': L.url('admin', 'network', 'qos-ex', 'system', 'maintenance') }, _('Update') + ' →') ]);
			// The row is on the page once the view has rendered (10 s cap).
			var n = 0;
			(function put() {
				var up = row.parentNode;
				if (!up) { if (++n < 50) window.setTimeout(put, 200); return; }
				if (!up.querySelector(':scope > .qos-ex-upd-banner')) up.insertBefore(el, row);
			})();
		});
	},
	// A copy of qos-ex.css for the view to carry, while a theme has switched
	// the <head> copy off. footstrap swaps pages without a page load and
	// lights the <head> copy only on the app whose page added it, so QoS-Ex
	// after LuCI's Status page (the tile adds it there) was unstyled, and the
	// tile after QoS-Ex. A sheet inside the view lives and goes with the
	// page, as footstrap expects; '' while the <head> copy paints.
	cssCopy: function() {
		var lk = document.querySelector('link[href="' + CSS_HREF + '"]');
		return (lk && !lk.disabled) ? '' : E('link', { 'rel': 'stylesheet', 'href': CSS_HREF });
	},

	// A link into the app: path is the page under admin/network/qos-ex, and
	// its last element may be a '#hash' (a Setup tab, a Ping Filter Settings
	// tab or section). go() is the "label →" link every page uses.
	tabUrl: function(path) {
		var p = path.slice(), tab = /^#/.test(p[p.length - 1]) ? p.pop() : '';
		return L.url.apply(L, [ 'admin', 'network', 'qos-ex' ].concat(p)) + tab;
	},
	go: function(path, label) {
		return E('a', { 'class': 'qx-go', 'href': this.tabUrl(path) }, label + ' →');
	},

	// The Ping Filter mode settings from UCI, in the pf_servers reply's
	// shape. Each mode keeps its own number there; the daemon ignores the
	// other one. Callers have uci.load('qos-ex') done.
	pfUci: function() {
		function g(k) { return uci.get('qos-ex', 'pingfilter', k); }
		return { block_mode: g('block_mode') || 'ping', threshold: g('threshold_ms') | 0,
			home_radius_km: parseInt(g('home_radius_km'), 10) || 1000, ping_catch: g('ping_catch_ms') | 0 };
	},
	// The mode in words, from a pf_servers reply or pfUci(): in full for
	// the Dashboard, short for the banner, the Overview and the Status tile.
	pfModeText: function(j, short) {
		var thr = j.threshold | 0, ctc = j.ping_catch | 0;
		if (j.block_mode === 'distance')
			return (short ? _('Distance ≤ %d km') : _('Blocking servers outside %d km')).format(parseInt(j.home_radius_km, 10) || 1000) +
				(ctc > 0 ? ' · ' + _('Ping Catch ≤ %d ms').format(ctc) : '');
		if (thr > 0) return (short ? _('Ping ≤ %d ms') : _('Blocking servers over %d ms')).format(thr);
		return short ? _('Watch only') : _('Watching only, no ping limit');
	},

	// One count of the pf_servers payload for every view that shows one.
	// The Overview card and the Dashboard tiles counted separately and
	// disagreed: the Dashboard's "Servers (+cached)" took the whole list,
	// cached rows included, and then added the cached count on top.
	pfCounts: function(j) {
		var c = { live: 0, cached: 0, allowed: 0, blocked: 0, manual: 0 };
		((j && j.servers) || []).forEach(function(s) {
			if (s.state === 'cached') { c.cached++; return; }
			c.live++;
			if (s.state === 'allowed' || s.state === 'whitelist') c.allowed++;
			else if (s.state === 'blocked' || s.state === 'blacklist') c.blocked++;
			if (s.state === 'whitelist' || s.state === 'blacklist') c.manual++;
		});
		return c;
	},

	// The devices PF actually watches: ticked (pf_devices) AND still a
	// gaming device (Setup -> Devices & Ports). pf_apply_device_filter()
	// drops the rest, and an empty result means no sources at all -- never
	// "all". Callers must have uci.load('qos-ex') already.
	pfDevIps: function() {
		var g4 = L.toArray(uci.get('qos-ex', 'ips', 'gaming_ipv4'));
		var g6 = L.toArray(uci.get('qos-ex', 'ips', 'gaming_ipv6'));
		var gm = L.toArray(uci.get('qos-ex', 'ips', 'gaming_mac')).map(function(m) { return String(m).toLowerCase(); });
		return L.toArray(uci.get('qos-ex', 'pingfilter', 'pf_devices')).filter(function(ip) {
			return g4.indexOf(ip) >= 0 || g6.indexOf(ip) >= 0 || gm.indexOf(String(ip).toLowerCase()) >= 0;
		});
	},

	// pf_status mac_devices ("mac=ip mac=ip") -> { mac: [ ip, ... ] }: the
	// address Ping Filter resolved each MAC device to, from the neighbour
	// table and the DHCP leases. A MAC missing from it is not on the network.
	pfMacMap: function(st) {
		var m = {};
		String((st && st.mac_devices) || '').split(/\s+/).forEach(function(e) {
			var k = e.split('=');
			if (k[0] && k[1]) (m[k[0]] = m[k[0]] || []).push(k[1]);
		});
		return m;
	},

	// Host hints (luci-rpc getHostHints) -> { mac: [ ip, ... ] }, MACs in
	// lower case: the address each known host holds (IPv4, else IPv6).
	// Merged under pfMacMap() it labels MAC devices Ping Filter does not watch.
	hintMacMap: function(hints) {
		var m = {};
		Object.keys(hints || {}).forEach(function(mac) {
			var x = hints[mac] || {}, v4 = [].concat(x.ipaddrs || x.ipv4 || []);
			var ips = v4.length ? v4 : [].concat(x.ip6addrs || x.ipv6 || []).slice(0, 1);
			if (ips.length) m[String(mac).toLowerCase()] = ips.map(String);
		});
		return m;
	},

	// The devices to pick from on Setup -> Devices & Ports and in Auto Setup:
	// the host hints without the router itself (getHostHints also lists the
	// router's own interfaces) and without the hosts on the WAN side (an
	// Ethernet WAN's gateway, the router upstream of a double NAT), i.e. a
	// hint whose IPv4 addresses all sit in a subnet of the WAN device. wan =
	// that device, or a promise of it; '' leaves the WAN side in. If
	// getNetworkDevices fails, every hint stays.
	lanHints: function(wan) {
		function v4(s) {
			var p = String(s || '').split('.'), n = 0;
			if (p.length !== 4) return null;
			for (var i = 0; i < 4; i++) {
				if (!/^\d{1,3}$/.test(p[i]) || +p[i] > 255) return null;
				n = n * 256 + +p[i];
			}
			return n;
		}
		return Promise.all([
			this.callHostHints().catch(function() { return {}; }),
			this.callNetDevices().catch(function() { return {}; }),
			Promise.resolve(wan).catch(function() { return ''; })
		]).then(function(r) {
			var hints = r[0] || {}, devs = r[1] || {}, own = {}, nets = [], out = {};
			Object.keys(devs).forEach(function(name) {
				var d = devs[name] || {}, m = String(d.mac || '').toLowerCase();
				if (m && m !== '00:00:00:00:00:00') own[m] = true;
				if (r[2] && name === r[2]) [].concat(d.ipaddrs || []).forEach(function(a) {
					var ip = v4(a && a.address), mask = v4(a && a.netmask);
					if (ip !== null && mask) nets.push([ ip, mask ]);
				});
			});
			function wanSide(ip) {
				var n = v4(ip);
				return n !== null && nets.some(function(w) { return ((n ^ w[0]) & w[1]) === 0; });
			}
			Object.keys(hints).forEach(function(mac) {
				var x = hints[mac] || {}, a4 = [].concat(x.ipaddrs || x.ipv4 || []);
				if (own[String(mac).toLowerCase()]) return;
				if (nets.length && a4.length && a4.every(wanSide)) return;
				out[mac] = x;
			});
			return out;
		});
	},

	// How a monitored device is shown: an address as it is; a MAC as the
	// address it holds now, then the MAC. mm = pfMacMap().
	pfDevLabel: function(d, mm) {
		if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(d)) return d;
		var ips = (mm || {})[String(d).toLowerCase()];
		return (ips && ips.length ? ips.join(', ') : _('not on the network now')) + ' \u00b7 ' + d;
	},

	// The ONE visibility rule for the Map and Servers pages: connected,
	// pinned (whitelist/blacklist), or seen since the open play window began
	// (play_start from pf_servers_json; 0 once idle for map_keep).
	pfShown: function(r, playStart) {
		return !!(r.connected === true || r.connected === 'true' || r.state === 'whitelist' || r.state === 'blacklist' ||
			(playStart > 0 && (r.ts | 0) >= playStart));
	},

	// The servers both pages show, in one place: what the Map plots (or
	// counts as not located yet) is what the Servers page lists, and the
	// Map's legend counts are the list's chip counts.
	pfVisible: function(servers, playStart) {
		var self = this;
		return (servers || []).filter(function(r) {
			return (r.proto || 'udp') === 'udp' && self.pfShown(r, playStart);
		});
	},
	pfLocated: function(r) {
		return !((parseFloat(r.lat) || 0) === 0 && (parseFloat(r.lon) || 0) === 0);
	},

	// "Actually playing on" = connected AND inbound pps at game rate: the
	// same enter gate the dashboard card uses (half the daemon's
	// active_pps, default 20 -> 10, floor 5). Keepalive / matchmaking /
	// voice side flows are "connected" but sit far below this rate.
	// cfgPps = the active_pps field from the pf_servers JSON header.
	pfPlaying: function(s, cfgPps) {
		if (!s || !(s.connected === true || s.connected === 'true')) return false;
		return (s.pps | 0) >= Math.max(5, (parseInt(cfgPps, 10) || 20) >> 1);
	},

	// The ONE server being played on right now -- the game stream is the
	// DOMINANT connected flow: highest pps wins, score only breaks ties.
	// Enter gate = HALF the daemon's active_pps (default 20 -> 10), exit =
	// a quarter for the server already picked, so low-tick games keep it
	// and lobby keepalives (<5 pps) age out. The Dashboard's Now playing
	// card, the map pulse and every "playing" dot use this, so they always
	// agree on the server -- and all go quiet together when the Dashboard
	// says there is no active game server.
	pickLive: function(servers, prevIp, cfgPps) {
		cfgPps = parseInt(cfgPps, 10) || 20;
		var enter = Math.max(5, cfgPps >> 1), exit = Math.max(3, cfgPps >> 2);
		return (servers || []).filter(function(s) {
			var pps = s.pps | 0;
			return (s.connected === true || s.connected === 'true') &&
				(pps >= enter || (prevIp && s.ip === prevIp && pps >= exit));
		}).sort(function(a, b) {
			return ((b.pps | 0) - (a.pps | 0)) || ((b._score || 0) - (a._score || 0));
		})[0];
	},

	// pickLive with memory, for views that poll: holds view._liveIp across
	// ticks (exit hysteresis) and bridges an in-game packet gap of up to 8s,
	// the same window the Dashboard card uses. Returns the IP or null.
	liveIp: function(view, servers, cfgPps) {
		var live = this.pickLive(servers, view._liveIp, cfgPps);
		if (live) { view._liveIp = live.ip; view._liveAt = Date.now(); }
		else if (Date.now() - (view._liveAt || 0) > 8000) view._liveIp = null;
		return view._liveIp || null;
	},

	// Great-circle km, rounded. Shared by the server detail rows
	// (Dashboard, Servers), the catch tag and the map popup rows (v1.7.8)
	// -- was duplicated at dashboard module scope, and a copied formula is
	// how two views silently drift.
	haversineKm: function(la1, lo1, la2, lo2) {
		var R = 6371, rad = Math.PI / 180;
		var dLa = (la2 - la1) * rad, dLo = (lo2 - lo1) * rad;
		var a = Math.sin(dLa / 2) * Math.sin(dLa / 2) +
			Math.cos(la1 * rad) * Math.cos(la2 * rad) *
			Math.sin(dLo / 2) * Math.sin(dLo / 2);
		return Math.round(R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)));
	},

	// Connection score, display only: 100 - ping - jitter - stutter.
	//   ping    min(60, max(0, ping - 10) * 0.6)
	//   jitter  min(20, max(0, jitter - 5))
	//   stutter min(15, gaps per minute of graded play * 5)
	// Distance is not scored (it is already in the ping) and neither is
	// loss (an unreliable proxy on variable-rate game traffic). No ping
	// yet = no score (-1).
	score: function(s) {
		var p = this.scoreParts(s);
		return p ? Math.max(0, Math.round(100 - p.ping - p.jitter - p.stutter)) : -1;
	},
	// The three deductions (null = no ping yet), for score() and the
	// ladder's detail row. gpm = gaps per minute of graded play.
	scoreParts: function(s) {
		if (!(s.ping > 0)) return null;
		var jit = (s.hist_jitter > 0) ? s.hist_jitter
			: ((s.jitter_live > 0) ? s.jitter_live : (s.jitter || 0));
		var dur = s.hist_dur | 0, gpm = dur >= 60 ? (s.hist_gaps | 0) * 60 / dur : 0;
		return { ping: Math.min(60, Math.max(0, s.ping - 10) * 0.6),
			jitter: Math.min(20, Math.max(0, jit - 5)), stutter: Math.min(15, gpm * 5), gpm: gpm };
	},
	scoreTxt: function(v) { return v < 0 ? '\u2014' : String(v); },

	// Score colour bands: green great, amber ok, red poor. 80 / 60 put
	// the Competitive (40 ms) and Casual (80 ms) limits near the band edges.
	scoreColor: function(v) {
		return v < 0 ? 'inherit' : v >= 80 ? '#33cc66' : (v >= 60 ? '#e0a800' : '#e04545');
	},
	// Same bands as a pill class (qos-ex.css .label.pf-score.good/ok/poor).
	scoreBand: function(v) {
		return v < 0 ? '' : v >= 80 ? 'good' : (v >= 60 ? 'ok' : 'poor');
	},
	// The score as a letter grade (S 90+, A 80+, B 70+, C 60+, D below),
	// on the same bands: S/A good, B/C ok, D poor.
	grade: function(v) {
		return v < 0 ? '\u2014' : v >= 90 ? 'S' : v >= 80 ? 'A' : v >= 70 ? 'B' : v >= 60 ? 'C' : 'D';
	},

	// Rate gauge (the Overview's Download / Upload tiles): a semicircular
	// SVG arc, drawn by hand like every other chart here. The value path
	// carries pathLength=100, so set(frac) is one dash-offset write;
	// qos-ex.css animates the move (and stops it under reduced motion).
	// The figure itself is the caller's node, laid inside the arc by CSS.
	qxGauge: function() {
		var ns = 'http://www.w3.org/2000/svg';
		function arc(cls) {
			var p = document.createElementNS(ns, 'path');
			p.setAttribute('d', 'M 10,58 A 50,50 0 0 1 110,58');
			p.setAttribute('class', cls);
			p.setAttribute('pathLength', '100');
			return p;
		}
		var svg = document.createElementNS(ns, 'svg');
		svg.setAttribute('viewBox', '0 0 120 64');
		svg.setAttribute('class', 'qx-gauge');
		svg.setAttribute('aria-hidden', 'true');
		// Gap 200 > the path, so the dash pattern never repeats: with a plain
		// '100' the NEXT dash period began exactly at the path end and its
		// round cap painted a stray dot at the arc's right end near 0%.
		var val = arc('qx-gauge-arc');
		val.setAttribute('stroke-dasharray', '100 200');
		val.setAttribute('stroke-dashoffset', '100');
		svg.appendChild(arc('qx-gauge-track'));
		svg.appendChild(val);
		return { svg: svg, set: function(frac) {
			var f = (frac > 0) ? (frac > 1 ? 1 : frac) : 0;
			// Empty = 101, one past the end: at exactly 100 the dash still
			// ends on the path start and its cap paints a dot there.
			val.setAttribute('stroke-dashoffset', String(f > 0 ? +(100 - f * 100).toFixed(1) : 101));
		} };
	},

	// An on/off switch (role=switch). o: { label, on, disabled, title,
	// change(want) -> Promise resolving false to keep the old state }.
	// A disabled switch can still be turned off. el.qxSet(on, disabled,
	// title) follows a poll; ignored while a change is in flight.
	qxSwitch: function(o) {
		var on = !!o.on, dis = !!o.disabled, busy = false;
		// On / Off written inside, beside the knob (aria-checked says it to
		// screen readers).
		var txt = E('span', { 'class': 'qx-sw-txt', 'aria-hidden': 'true' });
		var el = E('button', { 'type': 'button', 'class': 'qx-switch', 'role': 'switch',
			'aria-label': o.label }, [ txt, E('span', { 'class': 'qx-knob' }) ]);
		function paint() {
			txt.textContent = on ? _('On') : _('Off');
			el.setAttribute('aria-checked', on ? 'true' : 'false');
			el.classList.toggle('busy', busy);
			el.disabled = busy || (dis && !on);
		}
		el.addEventListener('click', function() {
			if (el.disabled) return;
			var want = !on;
			busy = true; on = want; paint();
			Promise.resolve().then(function() { return o.change(want); }).then(function(ok) {
				if (ok === false) on = !want;
			}, function() { on = !want; }).then(function() { busy = false; paint(); });
		});
		el.qxSet = function(v, d, t) {
			if (t != null) el.title = t;
			if (busy) return;
			on = !!v; dis = !!d; paint();
		};
		if (o.title) el.title = o.title;
		paint();
		return el;
	},

	// CAKE reports tins as unnamed columns; the backend deliberately does
	// NOT emit the names ("Best Effort" contains a space and would split on
	// a comma-separated record), so the index is mapped here instead.
	cakeTins: function(prio) {
		switch (prio) {
			case 'besteffort': return [ 'Best Effort' ];
			case 'diffserv3':  return [ 'Bulk', 'Best Effort', 'Voice' ];
			case 'precedence':
			case 'diffserv8':  return [ 'Tin 0', 'Tin 1', 'Tin 2', 'Tin 3',
			                            'Tin 4', 'Tin 5', 'Tin 6', 'Tin 7' ];
			default:           return [ 'Bulk', 'Best Effort', 'Video', 'Voice' ];
		}
	},

	// The CAKE in one direction's tc -j qdisc list.
	cakeOf: function(list) {
		return (list || []).filter(function(x) { return x.kind === 'cake'; })[0];
	},

	// Fixed hexes, not theme tokens: a chart series must keep the same colour
	// when the LuCI theme flips, and SVG stroke attributes do not accept
	// var(). Ordered worst-to-best so the palette reads as a priority ramp.
	classColor: function(name) {
		var C = {
			'Gaming':      '#33cc66',
			'Voice':       '#4aa3ff',
			'Video':       '#b07bff',
			'Default':     '#8b93a7',
			'Best Effort': '#8b93a7',
			'Low':         '#e0a800',
			'Bulk':        '#e04545'
		};
		if (C[name]) return C[name];
		var P = [ '#5bc0be', '#f0932b', '#c56cf0', '#7ed6df', '#e77f67', '#95a5a6' ];
		var hsh = 0;
		for (var i = 0; i < (name || '').length; i++) hsh = (hsh * 31 + name.charCodeAt(i)) & 0xffff;
		return P[hsh % P.length];
	},

	fmtRate: function(bps) {
		bps = bps || 0;
		if (bps >= 1e9) return (bps / 1e9).toFixed(2) + ' Gbit/s';
		if (bps >= 1e6) return (bps / 1e6).toFixed(2) + ' Mbit/s';
		if (bps >= 1e3) return (bps / 1e3).toFixed(1) + ' kbit/s';
		return Math.round(bps) + ' bit/s';
	},

	// Counterpart of parseState for the `stats` verb. Same contract: strip the
	// fenced machine block, hand back the human text untouched. Counters are
	// CUMULATIVE -- callers differentiate consecutive samples to get a rate.
	//   r=<dir>,<bytes>,<pkts>,<drops>
	//   c=<dir>,<classid>,<name>,<bytes>,<pkts>,<drops>,<over>,<backlog>,<blpkts>,<qdrop>,<ecn>,<leaf>
	//   t=<dir>,<tin>,<bytes>,<pkts>,<drops>,<backlog>
	// Backlog fields arrived with backend 3.0.8; an older backend simply
	// leaves them undefined and they fall back to 0.
	// qdrop/ecn/leaf (backend 3.1.2.4) are the class's leaf qdisc. A row's
	// drops is the larger of class and leaf: the leaf counts every drop it
	// makes, the class only the ones refused at enqueue, so adding the two
	// would count those twice and the class figure alone misses fq_codel's.
	// ecn is null where the leaf does not mark or the backend is older.
	parseCounters: function(out) {
		var meta = {}, root = {}, rows = { up: [], down: [] };
		var parsing = false, keep = [], lines = (out || '').split(/\n/);
		for (var i = 0; i < lines.length; i++) {
			var line = lines[i];
			if      (line === '@@COUNTERS@@')     { parsing = true;  continue; }
			else if (line === '@@COUNTERS_END@@') { parsing = false; continue; }
			if (!parsing) { keep.push(line); continue; }
			var kv = line.match(/^([\w_]+)=(.*)$/);
			if (!kv) continue;
			var k = kv[1], f = kv[2].split(',');
			if (k === 'r') {
				root[f[0]] = { bytes: +f[1] || 0, pkts: +f[2] || 0, drops: +f[3] || 0 };
			} else if (k === 'c') {
				if (!rows[f[0]]) rows[f[0]] = [];
				rows[f[0]].push({
					id: f[1], name: f[2], tin: -1,
					bytes: +f[3] || 0, pkts: +f[4] || 0,
					drops: Math.max(+f[5] || 0, +f[9] || 0),
					over: +f[6] || 0, backlog: +f[7] || 0, blpkts: +f[8] || 0,
					ecn: f[10] ? +f[10] : null, leaf: f[11] || ''
				});
			} else if (k === 't') {
				if (!rows[f[0]]) rows[f[0]] = [];
				rows[f[0]].push({
					id: 'tin' + f[1], name: null, tin: +f[1] || 0,
					bytes: +f[2] || 0, pkts: +f[3] || 0, drops: +f[4] || 0,
					over: 0, backlog: +f[5] || 0, blpkts: 0, ecn: null, leaf: ''
				});
			} else {
				meta[k] = kv[2];
			}
		}
		var names = this.cakeTins(meta.cake_prio);
		Object.keys(rows).forEach(function(d) {
			rows[d].forEach(function(r) {
				if (r.name === null) r.name = names[r.tin] || ('Tin ' + r.tin);
			});
		});
		return {
			meta: meta, root: root, rows: rows,
			text: keep.join('\n').replace(/^\n+/, '').replace(/\n+$/, '')
		};
	},

	// Seconds -> compact uptime. Shared by Status and Stats so the same
	// service has one age everywhere.
	fmtUptime: function(s) {
		s = parseInt(s, 10) || 0;
		if (s <= 0) return '\u2014';
		var d = Math.floor(s / 86400), hh = Math.floor((s % 86400) / 3600);
		var mm = Math.floor((s % 3600) / 60);
		if (d)  return d + 'd ' + hh + 'h';
		if (hh) return hh + 'h ' + mm + 'm';
		return mm + 'm ' + (s % 60) + 's';
	},

	parseState: function(out) {
		var state = {}, parsing = false;
		var lines = (out || '').split(/\n/);
		var keep = [];
		for (var i = 0; i < lines.length; i++) {
			var line = lines[i];
			if      (line === '@@STATE@@')     { parsing = true;  continue; }
			else if (line === '@@STATE_END@@') { parsing = false; continue; }
			if (parsing) {
				var m = line.match(/^([\w_]+)=(.*)$/);
				if (m) state[m[1]] = m[2];
			} else {
				keep.push(line);
			}
		}
		return { state: state, text: keep.join('\n').replace(/^\n+/, '').replace(/\n+$/, '') };
	},

	// --- Shaped-rate model ------------------------------------------------
	// One JS mirror of calc_bandwidth() in QoS-Ex.sh, shared by every page
	// that has to quote a rate. Callers must have uci.load('qos-ex') already.
	//
	// Mirror of _auto_bw_ratio(): how much download the upload can carry the
	// ACKs for. One ACK per two full-size segments, `share` of the uplink
	// spent on ACKs -- 60%, or 90% once the ACK filter is thinning them.
	autoBwRatio: function(overhead, ackOn) {
		var oh = parseInt(overhead, 10);
		if (!isFinite(oh) || oh < 0) oh = 44;
		var share = ackOn ? 90 : 60;
		var r = Math.floor(2 * (1500 + oh) * share / ((52 + oh) * 100));
		if (r < 4)  r = 4;
		if (r > 99) r = 99;
		return r;
	},

	// Line rate -> headroom haircut -> download cap, in that order, exactly
	// as the backend does it. `ovr` optionally overrides individual UCI keys
	// with live (unsaved) widget values, so a form can preview its own edits.
	// Returns kbps throughout.
	shapedRates: function(ovr) {
		function g(k, d) {
			var v = (ovr && ovr[k] != null && ovr[k] !== '') ? ovr[k]
				: uci.get('qos-ex', 'settings', k);
			return (v == null || v === '') ? d : v;
		}
		// As load_config: unset = 100000; not a number = 0, that direction
		// not shaped (up / dn come back 0 for it). Leading zeros read decimal.
		function line(k) {
			var v = String(g(k, ''));
			return v === '' ? 100000 : /^[0-9]+$/.test(v) ? parseInt(v, 10) : 0;
		}
		var lineUp = line('upload_kbps'), lineDn = line('download_kbps');

		// Percent of line rate; out of 50-100 or not a number = the default
		// 90, as load_config.
		var hv = String(g('bw_headroom', '90')), hr = /^[0-9]+$/.test(hv) ? parseInt(hv, 10) : 0;
		if (hr < 50 || hr > 100) hr = 90;
		var up = Math.floor(lineUp * hr / 100); if (lineUp && up < 1) up = 1;
		var dn = Math.floor(lineDn * hr / 100); if (lineDn && dn < 1) dn = 1;

		// ACK filter decision comes off the headroomed (pre-cap) rates.
		var ackf = String(g('ack_filter', 'auto')).toLowerCase();
		var ackOn;
		if (ackf === 'on' || ackf === 'yes')     ackOn = true;
		else if (ackf === 'off' || ackf === 'no') ackOn = false;
		// Auto: in kbit, as calc_bandwidth.
		else ackOn = dn > up * 14;
		if (!up) ackOn = false;

		// CAKE forces the cap off, same as calc_bandwidth.
		var qdiscv = String((ovr && ovr.qdisc) || this.qdiscCfg()).toLowerCase();
		var ratio  = String(g('bw_max_ratio', 'auto')).toLowerCase();
		if (qdiscv === 'cake' || !up || !dn) ratio = 'off';

		var eff = 'off', capped = false, max;
		if (ratio === 'auto') {
			eff = this.autoBwRatio(g('overhead', '44'), ackOn);
			max = up * eff;
			if (dn > max) { dn = max; capped = true; }
		} else if (/^[0-9]+$/.test(ratio) && parseInt(ratio, 10) > 0) {
			eff = parseInt(ratio, 10);
			max = up * eff;
			if (dn > max) { dn = max; capped = true; }
		}
		return { lineUp: lineUp, lineDn: lineDn, up: up, dn: dn,
			headroom: hr, ratioEff: eff, capped: capped, ackOn: ackOn };
	},

	// Shaper up? The backend's own answer when it gives one: a direction at
	// rate 0 has no qdisc to look for. Older backend: root qdisc + nft table.
	running: function(st) {
		return st.running != null ? st.running === '1'
			: (st.root_qdisc === '1' && st.nft_table === '1');
	},
	// True for a component that belongs to an unshaped direction.
	compOff: function(st, key) {
		if (key === 'root_qdisc') return st.shape_up === '0';
		return (key === 'ingress_qdisc' || key === 'ifb_up' || key === 'ctinfo') && st.shape_dn === '0';
	},

	// kbps -> a short Mbps string for readouts (1250 -> "1.25", 80000 -> "80").
	fmtMbps: function(kbps) {
		var n = parseInt(kbps, 10) || 0;
		return String(parseFloat((n / 1000).toFixed(2)));
	},

	fmtBytes: function(n) {
		n = parseInt(n, 10) || 0;
		if (n < 1024)          return n + ' B';
		if (n < 1048576)       return (n/1024).toFixed(1) + ' KiB';
		if (n < 1073741824)    return (n/1048576).toFixed(2) + ' MiB';
		if (n < 1099511627776) return (n/1073741824).toFixed(2) + ' GiB';
		return (n/1099511627776).toFixed(2) + ' TiB';
	},

	fmtAge: function(ts) {
		if (!ts) return '?';
		var d = Math.max(0, Math.floor(Date.now()/1000) - ts);
		if (d < 60)    return d + 's ago';
		if (d < 3600)  return Math.floor(d/60) + 'm ago';
		if (d < 86400) return Math.floor(d/3600) + 'h ago';
		return Math.floor(d/86400) + 'd ago';
	},

	// Notification banner. Expiry is NOT scheduled here -- the observer at the
	// top of this module owns it, so there is one TTL table and one timer per
	// banner. Returns the DOM node so callers can dismiss it earlier.
	notify: function(content, kind) {
		return ui.addNotification(null, content, kind || 'info');
	},

	// Convenience wrappers — accept a string or a DOM node. A string is
	// always a TEXT node: E('p', str) is innerHTML in LuCI's dom.append, and
	// callers splice typed input and backend values in (a rejected
	// whitelist entry was echoed straight back as markup).
	notifyOk:  function(content) {
		return this.notify(typeof content === 'string'
			? E('p', {}, [ content ]) : content, 'info');
	},
	notifyErr: function(content) {
		return this.notify(typeof content === 'string'
			? E('p', {}, [ content ]) : content, 'danger');
	},

	// ---------------------------------------------------------------
	// RPC failure surfacing.
	//
	// Every view used to wrap its calls in .catch(-> {output:''}), which
	// made an ACL denial, a crashed backend, a malformed reply and a
	// genuinely stopped shaper render identically: as "nothing to show".
	// The shim emits a real {"error":"..."} object on every failure path
	// precisely so the reason survives the round trip; rpcSafe keeps it.
	//
	// The stand-in still has the shape callers expect, so no parser needs
	// to change -- the reason rides along in _err. Repeat failures on a
	// poll tick are collapsed to one banner per distinct message per
	// minute, so a backend that is down does not produce a banner every
	// five seconds.
	// Counters and tc in one call (Stats, Overview): resolves
	// [ counters reply (rpcSafe-shaped, _err on failure), tc reply | null ].
	// A counters reply without the @@COUNTERS@@ block goes through
	// callCounters, whose fallback to the full stats verb it keeps.
	liveSample: function() {
		var self = this;
		return this.rpcSafe(this.callLive(), { output: '' }).then(function(r) {
			if (r._err) return [ r, null ];
			var tc = (r.tc && typeof r.tc === 'object' && !r.tc.error) ? r.tc : null;
			var c = r.counters || { output: '' };
			if (String(c.output || '').indexOf('@@COUNTERS@@') >= 0) return [ c, tc ];
			return self.rpcSafe(self.callCounters()).then(function(c2) { return [ c2, tc ]; });
		});
	},

	rpcSafe: function(p, empty) {
		var self = this;
		return p.catch(function(e) {
			var o = empty ? empty : { output: '' };
			o._err = (e && e.message) ? e.message : String(e);
			self._rpcGripe(o._err);
			return o;
		});
	},
	// load()-time fetch that answers from the last-known reply when there is
	// one (see cacheGet); otherwise a normal rpcSafe call. A cached copy is
	// flagged _cached: pass that to pollWhile as `lead`, so the view fetches
	// live data the moment it is on screen rather than an interval later.
	// `call` is the declared method itself, invoked with no arguments.
	loadC: function(key, call, empty) {
		var hit = cacheGet(key);
		if (hit) { hit._cached = true; return Promise.resolve(hit); }
		return this.rpcSafe(call(), empty);
	},

	_rpcGripe: function(msg) {
		var now = Date.now();
		if (!window.__qosExRpcSeen) window.__qosExRpcSeen = Object.create(null);
		var seen = window.__qosExRpcSeen;
		if (seen[msg] && (now - seen[msg]) < 60000) return;
		seen[msg] = now;
		this.notifyErr(_('QoS-Ex backend call failed: ') + msg);
	},

	// Register a poll handler that unregisters ITSELF once its anchor node
	// has left the document.
	//
	// LuCI is a single-page app and a view's render() has no teardown hook,
	// so a handler added with a bare poll.add outlives the view that made
	// it: walking Overview -> Status -> Stats -> Advanced left four live
	// handlers, each firing an RPC every interval and each forking the
	// backend on an 880MHz MT7621, for the rest of the session. Anchoring
	// on a node the handler already touches is self-cleaning and needs no
	// cooperation from the dispatcher.
	//
	// "Left" means it WAS attached and is not any more. Through 1.0.3.6 an
	// anchor that simply had not been attached YET counted as gone -- and at
	// registration it never has been: views call this from render(), before
	// LuCI inserts the returned nodes, and poll.add() on an idle loop runs
	// the handler synchronously right there. So every anchored handler
	// removed itself on its first call, and Overview, Status, NFT Rules,
	// Advanced, the PF Dashboard, Map, Server list and Lists never refreshed
	// at all; they sat on their load() data until the page was reloaded.
	// An anchor that never shows up (a failed render) is dropped after 30s.
	//
	// lead: also run once as soon as the anchor is on screen -- for a view
	// whose load() answered from the cache (h.loadC). Otherwise the first
	// refresh is the next interval, because load() has just fetched the same
	// thing. The handler never overlaps itself, lead run included, and a
	// throw inside it is logged instead of vanishing into the poll loop.
	pollWhile: function(anchor, fn, lead) {
		var seen = false, busy = false, born = Date.now();
		function onPage() {
			return !!(anchor && anchor.ownerDocument &&
			          anchor.ownerDocument.contains(anchor));
		}
		function run() {
			if (busy) return Promise.resolve();
			busy = true;
			return Promise.resolve().then(fn).catch(function(e) {
				if (window.console) window.console.error('QoS-Ex refresh failed:', e);
			}).then(function() { busy = false; });
		}
		// A hidden browser tab polls nothing -- LuCI's loop keeps ticking in
		// the background and every tick forks the backend -- and catches up
		// the moment it is shown again.
		// The listener goes when the poll does: one was left on the document
		// for every page visited, each holding its view.
		var onVis = function() {
			if (!document.hidden && seen && onPage()) run();
		};
		var tick = function() {
			if (!onPage()) {
				if (seen || (Date.now() - born) > 30000) {
					poll.remove(tick);
					document.removeEventListener('visibilitychange', onVis);
				}
				return Promise.resolve();
			}
			seen = true;
			return document.hidden ? Promise.resolve() : run();
		};
		poll.add(tick);
		if (lead) window.setTimeout(function() { if (onPage()) { seen = true; run(); } }, 0);
		document.addEventListener('visibilitychange', onVis);
		return tick;
	},

	// Single source of truth for the nft_mode -> table name map. Was a
	// ternary repeated in the shim, nft.js (twice) and classification.js,
	// so a third mode silently resolved to one table in every one of them.
	nftTable: function(mode) {
		var m = String(mode || '').toLowerCase();
		if (m === 'simple') return 'qos_ex_simple';
		if (m === 'advanced') return 'qos_ex_advanced';
		return 'qos_ex_adaptive';
	},

	clampN:     function(n, lo, hi) { return (n < lo) ? lo : (n > hi) ? hi : n; },

	// A port list as the backends read it (the shaper's _port_list_raw,
	// Ping Filter's _pf_ports_norm): ports or lo-hi ranges in 1-65535,
	// comma or space separated. Both drop a bad entry with only a log line.
	validPorts: function(section_id, value) {
		var t = String(value || '').split(/[, \t]+/);
		for (var i = 0; i < t.length; i++) {
			if (t[i] === '') continue;
			var m = /^([0-9]+)(?:-([0-9]+))?$/.exec(t[i]);
			var lo = m ? +m[1] : 0, hi = m ? +(m[2] || m[1]) : 0;
			if (!m || lo < 1 || hi > 65535 || hi < lo)
				return t[i] + ': ' + _('not a port or range in 1-65535');
		}
		return true;
	},
	// HTML escaper for the innerHTML sites this app still has. Lived only
	// inside map.js, which is why pingfilter/settings.js spliced raw UCI
	// values (the gaming IP list, the home coordinates) straight into a
	// markup string with nothing between them and the DOM. Anything that
	// reaches innerHTML goes through here.
	escHtml: function(s) {
		return String(s == null ? '' : s).replace(/&/g, '&amp;')
			.replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
	},

	// Tiny helper — is Ping Filter enabled? Reads the LIVE backend RPC
	// (pf_status), not the UCI cache, so it always sees the disk-truth
	// value: the enabled= line of its state block (parseState), mirroring
	// /etc/config/qos-ex pingfilter.enabled. Used by Ping Filter ->
	// Settings to show the Tools tab or the "disabled" notice.
	pingFilterEnabled: function(pfStatusJson) {
		if (!pfStatusJson || typeof pfStatusJson !== 'object') return false;
		var v = pfStatusJson.enabled;
		return v === '1' || v === 1 || v === true;
	},

	// Display helper for the root qdisc. UCI stores the lowercase value and
	// so does tc, so the UI now shows exactly what tc qdisc show reports --
	// the QoS-Ex-CAKE/HFSC/HTB branding was our own invention and made the
	// tiles disagree with the command line. Centralised so a future change
	// lands in one place.
	// The configured queue type as the backend names it; the removed
	// hfsc_sgs reads as hfsc, as the backend does. Needs uci.load('qos-ex').
	qdiscCfg: function() {
		var q = String(uci.get('qos-ex', 'settings', 'qdisc') || 'cake').toLowerCase();
		return q === 'hfsc_sgs' ? 'hfsc' : q;
	},

	qdiscDisplay: function(qdisc) {
		var q = String(qdisc || '').toLowerCase();
		if (q === 'cake' || q === 'hfsc' || q === 'htb') return q;
		return q || '?';
	},

	// Friendly name for nft_mode. Keep in step with the shim's ruleset
	// table map and nftTable() above.
	nftModeDisplay: function(mode) {
		var m = String(mode || '').toLowerCase();
		if (m === 'simple')   return 'Simple';
		if (m === 'advanced') return 'Advanced';
		if (m === 'adaptive') return 'Adaptive';
		return m || '?';
	},

	// The ONE banner, above the tab row on every page (in front of the
	// theme's #tabmenu; in front of the view where a theme has none):
	// "QoS-Ex – <main tab>", shaper and Ping Filter state, what is relevant
	// to the tab, versions. The name is the MAIN tab's, whichever sub-tab is
	// open. Fed by the light `state` call on a poll pageHead starts, or by
	// the view (o.fed, then h.barFeed) when the view polls `state` itself.
	//
	// A tab change is a full page load, so the banner is put up the moment
	// this module loads (__init__) -- before the view fetches anything --
	// with the last-known state from this browser tab, however old; the
	// first poll corrects it. Built only on a QoS-Ex page: LuCI's Status
	// page loads this module too, for its tile.
	__init__: function() {
		if (!/\/qos-ex(\/|$)/.test(location.pathname)) return;
		this.qxTheme();
		this.appBar();
	},
	// The app's accent colours follow the theme's light or dark look, read
	// from the page background itself, so every theme (bootstrap, its dark
	// mode, argon, material, ...) is covered without knowing its name:
	// data-qx-dark on <html> switches qos-ex.css to the dark palette.
	qxTheme: function() {
		var root = document.documentElement;
		function lum(el) {
			for (; el; el = el.parentElement) {
				var m = /rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?/.exec(window.getComputedStyle(el).backgroundColor);
				if (m && (m[4] == null || +m[4] > 0.5)) return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) / 255;
			}
			return 1;
		}
		function set() {
			if (lum(document.getElementById('maincontent') || document.body) < 0.45) root.setAttribute('data-qx-dark', '');
			else root.removeAttribute('data-qx-dark');
		}
		document.body.classList.add('qx-app');
		set();
		if (window.matchMedia && !this.qxWatch) {
			this.qxWatch = true;
			var mq = window.matchMedia('(prefers-color-scheme: dark)');
			if (mq.addEventListener) mq.addEventListener('change', function() { window.setTimeout(set, 50); });
		}
	},
	appBar: function() {
		var self = this, bar = document.getElementById('qos-ex-appbar');
		var MAIN = { autosetup: _('Auto Setup'), overview: _('Overview'), pingfilter: _('Ping Filter'), live: _('Live'),
			setup: _('Setup'), system: _('System') };
		// The page LuCI resolved: Network -> QoS-Ex lands on .../qos-ex itself,
		// which is the first tab (Auto Setup while it shows, else the Overview).
		var dp = (L.env && L.env.dispatchpath) || [];
		var seg = (dp[2] === 'qos-ex' && dp[3]) || (/\/qos-ex\/([a-z]+)/.exec(location.pathname) || [])[1] || 'overview';
		// Kept from the page before, under a theme that swaps pages in place.
		if (bar) {
			self.setText(bar.qosExPage, MAIN[seg] || '');
			bar.qosExPage.hidden = !MAIN[seg];
			return bar;
		}
		var pills = E('span', { 'class': 'qos-ex-hdr-pills' }), sig = null;
		var ver = E('span', { 'class': 'qos-ex-hdr-tools qos-ex-muted' });
		var page = E('span', { 'class': 'qx-hdr-page' }, MAIN[seg] || '');
		page.hidden = !MAIN[seg];
		bar = E('div', { 'id': 'qos-ex-appbar', 'class': 'qos-ex-cmdbar qos-ex-hdr qos-ex-appbar' }, [
			E('span', { 'class': 'qos-ex-hdr-title' }, [ 'QoS', E('span', { 'class': 'qx-acc' }, '-Ex'), page ]),
			pills, ver ]);
		bar.qosExPage = page;
		// Slots after the state pills: the tab's own (kind) and the view's.
		bar.qosExInfo = E('span', { 'class': 'qos-ex-hdr-pills' });
		bar.qosExView = E('span', { 'class': 'qos-ex-hdr-pills' });
		bar.insertBefore(bar.qosExInfo, ver);
		bar.insertBefore(bar.qosExView, ver);
		// text may be a [ node, string ] list: hand it over as is. Wrapping
		// it again nests the array, and LuCI's dom.append does not recurse --
		// a nested array is stringified ("[object HTMLElement], ,Shaping").
		function pill(cls, text, tip) {
			return E('span', { 'class': 'label pf-pill ' + cls, 'title': tip }, Array.isArray(text) ? text : [ text ]);
		}
		bar.qosExSubs = [];
		bar.qosExFeed = function(r) {
			var st = self.parseState((r && r.output) || '').state;
			if (st.version == null) return;
			// Ping Filter is ON only while the shaper runs: enabled but
			// stopped is OFF here, as on the Status-page tile.
			var run = self.running(st), pfOn = st.pf_on === '1' && run, act = st.pf_act || 'idle';
			// A real dot, not the ● character: it can carry the dark-theme glow.
			function sdot() { return E('i', { 'class': 'qx-sdot' }); }
			var out = [ pill(run ? 'on' : 'off', [ sdot(), ' ', run ? _('Shaping') : _('Stopped') ], _('Shaper')) ];
			if (st.pf_on != null)
				out.push(pill(pfOn ? 'on' : 'off', [ sdot(), ' ' + _('Ping Filter') + ' ' + (pfOn ? _('ON') : _('OFF')) ], _('Ping Filter')));
			if (pfOn) out.push(
				act === 'active' ? pill('active', '⦿ ' + _('in match'), _('Gaming traffic is flowing now'))
				: act === 'matchmaking' ? pill('matchmaking', '⦾ ' + _('matchmaking'), _('Console online — waiting for game traffic'))
				: pill('idle', '⊙ ' + _('idle'), _('No gaming traffic')));
			var s = JSON.stringify(out.map(function(n) { return n.className + n.textContent; }));
			if (s !== sig) { sig = s; L.dom.content(pills, out); }
			// The branch installed (main / dev) leads the versions, then the
			// parts by module: app (1.x), Ping Filter (2.x), shaper (3.x).
			self.setText(ver, (st.branch ? st.branch + ' · ' : '') + _('app') + ' __VERSION__' +
				(st.pf_ver ? ' · PF v' + st.pf_ver : '') + ' · ' + _('shaper') + ' ' + (st.ver_tag || 'v') + st.version);
			bar.qosExSubs.forEach(function(fn) { fn(st); });
		};
		function place() {
			var at = document.getElementById('tabmenu') || document.getElementById('view');
			if (at && at.parentNode) at.parentNode.insertBefore(bar, at);
			return at && at.parentNode;
		}
		var host = place();
		// footstrap swaps pages without a page load and clears what sits
		// beside #view and #tabmenu at each swap, the banner too: it goes
		// back while the page is still a QoS-Ex one. Leaving QoS-Ex, the
		// banner stays gone and so does qx-app (body outlives the page).
		if (host && window.MutationObserver) {
			var mo = new MutationObserver(function() {
				if (bar.isConnected) return;
				var p = (L.env && L.env.dispatchpath) || [];
				if (p[2] === 'qos-ex' && place()) return;
				mo.disconnect();
				document.body.classList.remove('qx-app');
			});
			mo.observe(host, { childList: true });
		}
		bar.qosExFeed(cacheGet('state', true));
		return bar;
	},
	barFeed: function(r) {
		var bar = document.getElementById('qos-ex-appbar');
		if (bar) bar.qosExFeed(r);
	},

	// What every page leads with. Puts the banner (appBar) above the tabs
	// and gives it this page's info: kind 'pf' the Ping Filter mode and
	// limit, 'none' nothing, anything else the shaper's queue, rule set and
	// rates; o.pills the view's own figures as well. Returns the page's control row
	// (o.tools, right-aligned; empty and hidden without) -- a page has no
	// title bar of its own. o.fed: the view feeds the banner.
	pageHead: function(title, kind, o) {
		var self = this, sig = null;
		o = o || {};
		// A page reached without a page load (footstrap) after a page that
		// is not QoS-Ex: this module's __init__ ran there, without these.
		self.qxTheme();
		var bar = self.appBar();
		// Such a swap also empties LuCI's poll queue: add() puts the
		// banner's handler back, and does nothing while it is still there.
		if (!o.fed && bar.qosExPoll) poll.add(bar.qosExPoll);
		else if (!o.fed) bar.qosExPoll = self.pollWhile(bar, function() {
			return self.callState().then(bar.qosExFeed, function() {});
		}, true);
		// A menu this browser tab kept from before autosetup.done changed
		// (another tab finished or reopened Auto Setup): fetched again for
		// the next page. Needs the page's uci.load('qos-ex').
		var done = uci.get('qos-ex', 'autosetup', 'done');
		if (done != null) ui.menu.load().then(function(m) {
			var n = [ 'admin', 'network', 'qos-ex', 'autosetup' ].reduce(function(x, k) {
				return x && x.children && x.children[k];
			}, m);
			if (n && !n.satisfied !== (done !== '0')) ui.menu.flushCache();
		}).catch(function() {});
		var row = E('div', { 'class': 'qos-ex-toolrow' }, o.tools || []), css = self.cssCopy();
		if (css) row.appendChild(css);
		self.updNote(row);
		var mine = o.pills || E('span', { 'class': 'qos-ex-hdr-pills' });
		bar.replaceChild(mine, bar.qosExView);
		bar.qosExView = mine;
		function pill(text, tip) {
			return E('span', { 'class': 'label pf-pill', 'title': tip }, [ text ]);
		}
		function paint(st) {
			var out = [];
			if (kind === 'pf') {
				if (st.pf_on === '1' && uci.get('qos-ex', 'pingfilter'))
					out.push(pill(self.pfModeText(self.pfUci(), true), _('Mode and limit')));
			} else if (kind !== 'none' && self.running(st)) {
				out.push(pill(self.qdiscDisplay(st.qdisc), _('Root qdisc')),
					pill(self.nftModeDisplay(st.nft_mode), _('nft ruleset')),
					pill('↓ ' + (st.shape_dn === '0' ? '—' : self.fmtMbps(st.dl_kbps_eff)) +
						'  ↑ ' + (st.shape_up === '0' ? '—' : self.fmtMbps(st.ul_kbps_eff)) + ' Mbps', _('Shaped rate')));
			}
			var s = JSON.stringify(out.map(function(n) { return n.textContent; }));
			if (s === sig) return;
			sig = s;
			L.dom.content(bar.qosExInfo, out);
		}
		// One page, one painter: a view that renders again replaces its own.
		bar.qosExSubs = [ paint ];
		var st0 = self.parseState((cacheGet('state', true) || {}).output || '').state;
		if (st0.version != null) paint(st0);
		return row;
	},

	// Service controls laid out exactly like System -> Startup: an
	// Enabled/Disabled toggle, then Start / Restart / Reload / Stop. Each
	// button is enabled only when it can do something, and row.qosExSync()
	// re-applies that from every poll, so the row follows the service.
	//   cfg.toggle(want) -> Promise; resolves false to keep the old state
	//   cfg.start / restart / reload / stop -> Promise
	svcControls: function(cfg) {
		var on = !!cfg.enabled, up = !!cfg.running, busy = false;
		var tgl = E('button', {});
		function btn(label, fn) {
			var b = E('button', { 'class': 'btn cbi-button-action' }, label);
			b.addEventListener('click', function() {
				if (b.disabled || busy) return;
				busy = true; paint(); b.textContent = '…';
				Promise.resolve(fn()).catch(function() {}).then(function() {
					busy = false; b.textContent = label; paint();
				});
			});
			return b;
		}
		var bStart = btn(_('Start'), cfg.start), bRestart = btn(_('Restart'), cfg.restart),
		    bReload = btn(_('Reload'), cfg.reload), bStop = btn(_('Stop'), cfg.stop);
		function paint() {
			tgl.className = 'btn cbi-button-' + (on ? 'positive' : 'negative');
			if (!busy) tgl.textContent = on ? _('Enabled') : _('Disabled');
			tgl.disabled = busy;
			bStart.disabled   = busy || !on || up;
			bRestart.disabled = busy || !on;
			bReload.disabled  = busy || !on || !up;
			bStop.disabled    = busy || !up;
			var off = on ? '' : _('Enable first');
			bStart.title = off || (up ? _('Already running') : '');
			bRestart.title = off;
			bReload.title = off || (up ? _('Rebuild the nft rules only') : _('Not running'));
			bStop.title = up ? '' : _('Not running');
		}
		tgl.addEventListener('click', function() {
			if (busy) return;
			var want = !on;
			busy = true; paint(); tgl.textContent = '…';
			Promise.resolve(cfg.toggle(want)).then(function(ok) {
				if (ok !== false) on = want;
			}).catch(function() {}).then(function() { busy = false; paint(); });
		});
		paint();
		var row = E('div', { 'class': 'qos-ex-svc' }, [ tgl, bStart, bRestart, bReload, bStop ]);
		row.qosExSync = function(en, run) {
			if (busy || (on === !!en && up === !!run)) return;
			on = !!en; up = !!run; paint();
		};
		return row;
	},

	// Arm the interaction guard on a scroll box (idempotent). Needed only
	// for boxes recreated on every paint; scrollKeepAll/scrollBusy arm the
	// hosts they resolve automatically.
	scrollArm: function(el) { return scrollArm(el); },

	// true = the user is mid-gesture in this box; skip the repaint tick.
	scrollBusy: function(node) {
		var box = scrollHost(node);
		if (!box) return false;
		scrollArm(box);
		return scrollHeld(box);
	},

	// Update a text pane WITHOUT replacing its child. Assigning .textContent
	// removes the existing text node and appends a new one; that is a
	// structural change, so the box's scrollHeight collapses for a frame and
	// the browser gets an excuse to clamp scrollTop. Mutating the existing
	// text node's data changes nothing structural, so the reader keeps their
	// place and no restore is needed at all. Returns true if anything moved.
	setText: function(node, text) {
		if (!node) return false;
		var t = (text == null) ? '' : String(text);
		var c = node.firstChild;
		if (c && c.nodeType === 3 && !c.nextSibling) {
			if (c.data === t) return false;
			c.data = t;
			return true;
		}
		if (node.textContent === t) return false;
		node.textContent = t;
		return true;
	},

	// Keyed, in-place row sync. Rows arrive as
	//   { k: <identity, stable for the life of the row>,
	//     sig: <every value that can change on a refresh>,
	//     cells: function() { return [ td, td, ... ]; } }
	//
	// A row whose sig matches is left completely alone -- cells() is not even
	// called, so an idle table costs zero DOM writes and zero node
	// allocations. A changed row keeps its existing <tr>, so the row count
	// and the row heights hold still and the pane's scrollTop is never
	// disturbed. New keys are inserted in place, vanished keys removed.
	//
	// This replaces dom.content(tbody, []) + full rebuild, which discarded
	// every node on every tick. That is what clamped scrollTop to 0, killed
	// focus, selection and hover, and made a scroll restore necessary in the
	// first place.
	// The tag argument defaults to tr for the table callers. The Ping Filter
	// lists are built from divs, so they pass div and carry the row class on
	// the row descriptor as cls -- applied once at creation, since it never
	// varies for a given row.
	syncRows: function(tbody, rows, tag) {
		if (!tbody) return;
		tag = tag || 'tr';
		// Object.create(null), not {}: a plain object inherits constructor,
		// toString, valueOf and __proto__, so have[k] is truthy for a row
		// keyed with any of those and the row would be destroyed and rebuilt
		// on every tick while its delete silently did nothing.
		var have = Object.create(null), node = tbody.firstChild, next, k, i, j, cs;
		while (node) {
			next = node.nextSibling;
			k = (node.nodeType === 1 && node.getAttribute) ? node.getAttribute('data-k') : null;
			if (k === null || have[k]) tbody.removeChild(node);
			else have[k] = node;
			node = next;
		}
		var cursor = tbody.firstChild;
		for (i = 0; i < rows.length; i++) {
			var r = rows[i], tr = have[r.k];
			if (tr) {
				delete have[r.k];
				if (tr.getAttribute('data-sig') !== r.sig) {
					if (r.cls) tr.className = r.cls;
					while (tr.firstChild) tr.removeChild(tr.firstChild);
					cs = r.cells();
					for (j = 0; j < cs.length; j++) if (cs[j]) tr.appendChild(cs[j]);
					tr.setAttribute('data-sig', r.sig);
				}
			} else {
				tr = document.createElement(tag);
				tr.setAttribute('data-k', r.k);
				tr.setAttribute('data-sig', r.sig);
				if (r.cls) tr.className = r.cls;
				cs = r.cells();
				for (j = 0; j < cs.length; j++) if (cs[j]) tr.appendChild(cs[j]);
			}
			if (cursor === tr) cursor = tr.nextSibling;
			else tbody.insertBefore(tr, cursor);
		}
		for (k in have) if (have[k].parentNode === tbody) tbody.removeChild(have[k]);
	},

	// Full-rebuild repaints: the scroll boxes inside `root` are destroyed
	// and recreated, so they cannot be resolved by node identity. Capture
	// each one by SELECTOR before, put it back after, and re-arm it --
	// a fresh node is not armed and would miss the next gesture.
	scrollKeepAll: function(root, sels, fn) {
		var saved = [];
		(sels || []).forEach(function(s) {
			var el = root && root.querySelector ? root.querySelector(s) : null;
			if (el) saved.push([ s, el.scrollTop, el.scrollLeft ]);
		});
		var out = fn();
		saved.forEach(function(rec) {
			var el = root && root.querySelector ? root.querySelector(rec[0]) : null;
			if (!el) return;
			if (rec[1]) el.scrollTop  = rec[1];
			if (rec[2]) el.scrollLeft = rec[2];
			scrollArm(el);
		});
		return out;
	},

	// Bring `el`'s children in line with `kids` IN PLACE: nodes of the same
	// kind keep their identity and only changed text/attributes are written;
	// a node is swapped only when the structure differs. A refresh that
	// empties and refills a table instead drops the scroll box's content
	// for a moment (the scrollbar vanishes and scrollTop is clamped) and
	// repaints everything around it. The fresh trees must carry no
	// listeners -- existing nodes keep theirs, fresh ones are discarded.
	morphKids: function(el, kids) {
		var i, x, y;
		for (i = 0; i < kids.length; i++) {
			x = el.childNodes[i]; y = kids[i];
			if (!x) el.appendChild(y);
			else if (x.nodeType !== y.nodeType || x.nodeName !== y.nodeName) el.replaceChild(y, x);
			else if (x.nodeType === 3) { if (x.data !== y.data) x.data = y.data; }
			else if (x.nodeType === 1) {
				var j, at;
				for (j = 0; j < y.attributes.length; j++) {
					at = y.attributes[j];
					if (x.getAttribute(at.name) !== at.value) x.setAttribute(at.name, at.value);
				}
				for (j = x.attributes.length - 1; j >= 0; j--)
					if (!y.hasAttribute(x.attributes[j].name)) x.removeAttribute(x.attributes[j].name);
				this.morphKids(x, Array.prototype.slice.call(y.childNodes));
			}
		}
		while (el.childNodes.length > kids.length) el.removeChild(el.lastChild);
	},

	// Detail lines for one Ping Filter server: [ [label, text], ... ] from
	// Ping Filter's own figures. Shared by the Dashboard ladder and the
	// Servers page. o = { home: [lat, lon] | null, liveIp }.
	pfDetail: function(s, o) {
		var kv = [], graded = (s.hist_sessions | 0) > 0, p = this.scoreParts(s), x;
		var sc = p ? this.score(s) : -1;
		function r1(v) { return String(Math.round(v * 10) / 10); }
		function add(k, v) { if (v) kv.push([ k, v ]); }
		if (p && graded) add(_('Grade'), this.grade(sc) + ' \u00b7 ' + _('score') + ' ' + sc + ' = 100 \u2212 ' + _('ping') + ' ' + r1(p.ping) +
			' \u2212 ' + _('jitter') + ' ' + r1(p.jitter) + ' \u2212 ' + _('stutter') + ' ' + r1(p.stutter));
		add(_('Game'), s.gname);
		x = [ s.state ];
		if (s.connected === true || s.connected === 'true') x.push(s.ip === o.liveIp ? _('playing now') : _('connected now'));
		if (s.state === 'whitelist' || s.state === 'blacklist') x.push(_('pinned manually'));
		else if ((s.expiry_remaining_sec | 0) > 0)
			x.push(_('expires in') + ' ' + Math.max(1, Math.round(s.expiry_remaining_sec / 60)) + ' m');
		add(_('Verdict'), x.join(' \u00b7 '));
		var src = s.ping_src || s.ping_source;
		var how = { icmp: _('measured (ICMP echo)'), real: _('measured (handshake RTT)'),
			prefix: _('estimated from a measured server in the same /24'),
			area: _('estimated from a measured server nearby'), distance: _('estimated from distance') };
		add(_('Ping'), src === 'pending' ? _('measuring') : s.ping > 0
			? s.ping + ' ms' + (src ? ' \u00b7 ' + (how[src] || _('estimated')) : '') : _('none yet'));
		x = [];
		if (s.city || s.country) x.push([ s.city, s.country ].filter(Boolean).join(', '));
		if (o.home && parseFloat(s.lat) && parseFloat(s.lon))
			x.push(this.haversineKm(o.home[0], o.home[1], parseFloat(s.lat), parseFloat(s.lon)) + ' km ' + _('from home'));
		if (s.geo_suspect) x.push(_('location doubtful: the ping puts it within') + ' ' + (s.bound_km | 0) + ' km');
		add(_('Location'), x.join(' \u00b7 '));
		x = [];
		if (s.hist_jitter > 0) x.push(_('graded') + ' ' + s.hist_jitter + ' ms');
		if (s.hist_jitter_max > 0) x.push(_('worst') + ' ' + s.hist_jitter_max + ' ms');
		if (s.jitter_live > 0) x.push(_('live') + ' ' + s.jitter_live + ' ms');
		add(_('Jitter'), x.join(' \u00b7 '));
		x = [];
		if (graded) x.push((s.hist_gaps | 0) + ' ' + _('gaps in graded play') + (p && p.gpm ? ' (' + r1(p.gpm) + _('/min') + ')' : ''));
		if (s.connected && (s.gaps | 0) > 0) x.push(_('live') + ' ' + (s.gaps | 0) + ' ' + _('gaps'));
		if (s.connected && (s.gap_max | 0) > 0) x.push(_('longest') + ' ' + (s.gap_max | 0) + ' ms');
		add(_('Stutter'), x.join(' \u00b7 '));
		x = [];
		if (s.connected && (s.pps | 0) > 0) x.push(_('live') + ' ' + (s.pps | 0) + ' pps');
		if ((s.hist_pps | 0) > 0) x.push(_('graded average') + ' ' + (s.hist_pps | 0) + ' pps');
		add(_('Packet rate'), x.join(' \u00b7 '));
		x = [];
		if (graded) x.push(Math.max(1, Math.round((s.hist_dur | 0) / 60)) + ' min \u00b7 ' + (s.hist_sessions | 0) + ' ' + _('segments'));
		else x.push(_('not graded yet'));
		if (s.ts > 0) x.push(_('last seen') + ' ' + this.fmtAge(s.ts));
		add(_('Played'), x.join(' \u00b7 '));
		return kv;
	},
	// The syncRows descriptor of the detail row under server s (key det:<ip>).
	pfDetRow: function(s, colspan, o) {
		var kv = this.pfDetail(s, o).concat((o && o.extra) || []);
		return { k: 'det:' + s.ip, cls: 'pf2-det', sig: JSON.stringify(kv), cells: function() {
			return [ E('td', { 'colspan': colspan }, E('div', { 'class': 'qos-ex-conn-det' }, kv.map(function(e) {
				return [ E('div', { 'class': 'qos-ex-muted' }, [ e[0] ]), E('div', {}, [ e[1] ]) ];
			}).reduce(function(a, b) { return a.concat(b); }, []))) ];
		} };
	},

	// Scroll-box table, the Servers page pattern: one table with a sticky
	// header inside a fixed .qos-ex-sbox. With a summary it sits in a
	// <details class="qos-ex-raw"> (open unless `closed`) so it can be
	// hidden; without one the box is the node. Returns { node, head, box,
	// body }; the caller keeps the nodes and updates `body` (a tbody) in
	// place.
	sboxTable: function(summary, tblClass, headRow, closed) {
		var body = E('tbody', {});
		var box = E('div', { 'class': 'qos-ex-sbox' }, E('table', { 'class': tblClass }, [ E('thead', {}, headRow), body ]));
		var node = summary ? E('details', closed ? { 'class': 'qos-ex-raw' } : { 'class': 'qos-ex-raw', 'open': '' },
			[ E('summary', {}, summary), box ]) : box;
		// Scrollbar track starts under the sticky header: follow its height.
		if (window.ResizeObserver) new ResizeObserver(function() {
			box.style.setProperty('--qos-ex-head', headRow.offsetHeight + 'px');
		}).observe(headRow);
		return { node: node, head: headRow, box: box, body: body };
	},

	// The three modes as cards, for the setup card and the Dashboard: Ping
	// (40 / 80 or its own limit), Distance (radius, Ping Catch, Set on Map)
	// and Watch only. A pick acts at once (pf_action) and keeps the other
	// mode's number. A number commits on change, 500 ms later, so one edit
	// is one reload. The cards are disabled while a call runs, then repaint
	// from a fresh UCI. o.done runs after each change; o.map: on the Map.
	// node.qxPaint() repaints from UCI (only when it changed). Callers have
	// uci.load('qos-ex') done.
	pfModes: function(o) {
		var self = this, busy = false, sig = null;
		o = o || {};
		var box = E('div', { 'class': 'pf2-prof', 'role': 'group', 'aria-label': _('Mode') });
		function act(verb, arg, n) {
			if (busy) return;
			busy = true; paint();
			self.callPfAction(verb, arg, n).then(function(r) {
				if (!(r && r.ok)) self.notifyErr(_('Mode change failed'));
			}, function() { self.notifyErr(_('Mode change failed')); }).then(function() {
				uci.unload('qos-ex');
				return uci.load('qos-ex').catch(function() {});
			}).then(function() {
				busy = false; paint();
				if (o.done) o.done();
			});
		}
		// A whole number in lo..hi, sent as pf_action verb unless UCI (key
		// of pfUci) already holds it -- a repaint drops the field, and a
		// browser may send its change once more. A call running, or UCI
		// not loaded (a poll reloading it; pfUci gives defaults), delays it.
		function num(key, lo, hi, unit, label, verb) {
			var t = null, cur = self.pfUci()[key];
			var inp = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'min': lo, 'max': hi,
				'value': cur, 'title': label, 'disabled': busy ? '' : null });
			inp.addEventListener('change', function() {
				window.clearTimeout(t);
				t = window.setTimeout(function fire() {
					if (busy || !uci.get('qos-ex', 'pingfilter')) { t = window.setTimeout(fire, 500); return; }
					var v = String(inp.value).trim();
					if (!/^\d+$/.test(v) || +v < lo || +v > hi) {
						self.notifyErr(_('%s: %d to %d').format(label, lo, hi));
						inp.value = cur;
					} else if (+v !== self.pfUci()[key]) act(verb, '', +v);
				}, 500);
			});
			return E('label', { 'class': 'qx-mode-num' }, [ label + ' ', inp, ' ' + unit ]);
		}
		function card(on, label, sub, pick, ctl) {
			return E('div', { 'class': 'qx-mode' + (on ? ' on' : '') }, [
				E('button', { 'type': 'button', 'class': 'qx-mode-hd', 'aria-pressed': on ? 'true' : 'false',
					'disabled': busy ? '' : null, 'click': on ? null : pick }, [ E('b', {}, label), E('span', {}, sub) ]),
				on && ctl ? E('div', { 'class': 'qx-mode-ctl' }, ctl) : '' ]);
		}
		function paint() {
			var c = self.pfUci(), thr = c.threshold, km = c.home_radius_km, ctc = c.ping_catch;
			var cur = c.block_mode === 'distance' ? 'distance' : thr > 0 ? 'ping' : 'watch';
			var s = JSON.stringify([ cur, thr, km, ctc, busy ]);
			if (s === sig) return;
			sig = s;
			function quick(ms, prof, title) {
				return E('button', { 'type': 'button', 'class': 'btn cbi-button qx-mini' + (thr === ms ? ' sel' : ''),
					'title': title, 'disabled': busy ? '' : null,
					'click': function() { if (thr !== ms) act('profile', prof, 0); } }, ms + ' ms');
			}
			dom.content(box, [
				card(cur === 'ping', _('Ping'), thr > 0 ? _('Block servers over %d ms').format(thr) : _('Block servers over a ping limit'),
					// Back to its own limit, or Competitive when it has none.
					function() { if (thr > 0) act('mode', 'ping', 0); else act('profile', 'competitive', 0); },
					[ quick(40, 'competitive', _('Competitive')), quick(80, 'casual', _('Casual')),
						num('threshold', 1, 5000, 'ms', _('Ping limit'), 'threshold') ]),
				card(cur === 'distance', _('Distance'), _('Block servers outside %d km').format(km) +
						(ctc > 0 ? ' · ' + _('Ping Catch ≤ %d ms').format(ctc) : ''),
					function() { act('mode', 'distance', 0); },
					[ num('home_radius_km', 50, 20000, 'km', _('Radius'), 'radius'), num('ping_catch', 0, 250, 'ms', _('Ping Catch'), 'catch'),
						o.map ? '' : self.go([ 'pingfilter', 'map' ], _('Set on Map')) ]),
				card(cur === 'watch', _('Watch only'), _('Find and grade servers, no ping limit'),
					function() { act('profile', 'observe', 0); }, null)
			]);
		}
		box.qxPaint = paint;
		paint();
		return box;
	},

	// Under the live controls while a match is on: a change applies at
	// once. el.qxSet(on) shows or hides it.
	pfMatchWarn: function() {
		var el = E('div', { 'class': 'qos-ex-warn-text qx-matchwarn', 'hidden': '' },
			_('A game is on: this may block the server you\'re playing'));
		el.qxSet = function(on) { el.hidden = !on; };
		return el;
	},

	// What a Ping Filter page shows while Ping Filter is off: two steps,
	// each with where it is done -- 1 tick the gaming devices to watch
	// (nothing is ticked for you), 2 pin home on the Map -- then turn it on:
	// it starts in Watch only (the default; a mode picked before is kept),
	// and the mode is picked on the Dashboard after. On a page with no
	// switch of its own (o.sw) the card has the switch, enabled once both
	// steps are done (the daemon's own prerequisites); turning it on reloads
	// the page. o.macMap labels MAC devices (read at each paint); o.map: on
	// the Map. node.qxPaint() repaints from UCI. Callers have
	// uci.load('qos-ex') done.
	pfSetup: function(o) {
		var self = this;
		o = o || {};
		function g(sec, k) { return L.toArray(uci.get('qos-ex', sec, k)).filter(function(v) { return String(v || '').trim(); }); }
		var sw = o.sw ? self.qxSwitch({ label: _('Ping Filter'), on: false, disabled: true,
			change: function() {
				return self.callPfAction('enable', '', 0).then(function(r) {
					if (r && r.ok) { window.location.reload(); return true; }
					self.notifyErr(_('Action failed'));
					return false;
				});
			} }) : '';
		var hd = [ E('div', { 'class': 'qx-step' }), E('div', { 'class': 'qx-step' }) ];
		var li = [ E('li', {}, hd[0]), E('li', {}, hd[1]) ], done = [];
		var ready = E('div', { 'class': 'qx-sub' });
		function step(i, ok, title, kids) {
			done[i] = ok;
			dom.content(hd[i], [ E('b', {}, title) ].concat(kids));
		}
		function muted(t) { return E('span', { 'class': 'qos-ex-muted' }, [ t ]); }
		function paint() {
			var devs = self.pfDevIps(), c = self.pfUci();
			var home = !!(g('pingfilter', 'home_lat').length && g('pingfilter', 'home_lon').length);
			var gaming = g('ips', 'gaming_mac').length + g('ips', 'gaming_ipv4').length + g('ips', 'gaming_ipv6').length > 0;
			step(0, devs.length > 0, _('Gaming devices to watch'), devs.length
				? [ muted(devs.map(function(d) { return o.macMap ? self.pfDevLabel(d, o.macMap) : d; }).join('; ')),
					self.go([ 'pingfilter', 'settings', '#devices' ], _('Change')) ]
				: [ gaming ? self.go([ 'pingfilter', 'settings', '#devices' ], _('Tick your gaming devices'))
					: self.go([ 'setup', '#dev' ], _('First set a device to Gaming on Devices & Ports')) ]);
			step(1, home, _('Your home on the map'), [ home ? muted(_('Home set')) : '',
				o.map ? muted(_('Right-click the map at home, or zoom in and press Pin home here'))
					: self.go([ 'pingfilter', 'map' ], home ? _('Change') : _('Pin your home on the Map')) ]);
			// Done steps green, the first one to do in the accent.
			li.forEach(function(n, i) { n.className = done[i] ? 'done' : i === done.indexOf(false) ? 'cur' : ''; });
			var ok = devs.length && home;
			var watch = c.block_mode !== 'distance' && !(c.threshold > 0);
			dom.content(ready, ok ? [ (sw ? _('Ready: turn it on.') : _('Ready: turn it on above.')) + ' ' + (watch
				? _('It starts in Watch only: it grades servers and blocks nothing.')
				: _('It starts with: %s.').format(self.pfModeText(c))) ] : []);
			if (sw) sw.qxSet(false, !ok, ok ? _('Turn Ping Filter on') : _('Tick a gaming device and pin your home first'));
		}
		var card = E('div', { 'class': 'cbi-section qos-ex-card qx-pfoff' }, [
			E('div', { 'class': 'qx-ctl-row' }, [
				E('div', { 'class': 'qx-ctl-txt' }, [
					E('div', { 'class': 'qx-now-title' }, _('Set up the Ping Filter')),
					E('div', { 'class': 'qx-sub' }, _('Optional: finds your game servers and blocks slow or far ones.')) ]),
				sw ]),
			E('ol', { 'class': 'qx-steps' }, li), ready ]);
		card.qxPaint = paint;
		paint();
		return card;
	},

	// What a live page (Stats) shows while the shaper is not running: why
	// there is nothing to draw, and the way to start it -- the switch while
	// it is off, Restart when it is on but not running. Either reloads the
	// page once the shaper is up. Callers have uci.load('qos-ex') done.
	shaperOffCard: function() {
		var self = this, on = uci.get('qos-ex', 'settings', 'enabled') === '1';
		function done(r) {
			if (r && r.ok) { window.location.reload(); return true; }
			self.notifyErr(_('Could not start \u2014 check the WAN and speeds on Setup'));
			return false;
		}
		var ctl = on
			? E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, function() {
				return self.callAction('restart').then(done); }) }, _('Restart'))
			: self.qxSwitch({ label: _('Shaper'), on: false,
				change: function() { return self.callAction('enable').then(done); } });
		return E('div', { 'class': 'cbi-section qos-ex-card qx-pfoff' }, [
			E('div', { 'class': 'qx-ctl-row' }, [
				E('div', { 'class': 'qx-ctl-txt' }, [
					E('div', { 'class': 'qx-now-title' }, on ? _('The shaper is not running') : _('The shaper is off')),
					E('div', { 'class': 'qx-sub' }, on
						? _('On but not running: restart it, or see System \u2192 Logs.')
						: _('Turn the shaper on to see live rates here.')) ]),
				ctl ])
		]);
	},

	// LuCI's stock Flag writes its value on every Save, changed or not (its
	// parse never compares with the stored value), so each checkbox on a
	// page queued a change and Save & Apply reloaded for nothing. Write a
	// Flag only when its value differs from the stored one; an absent value
	// is still written (rmempty false keeps the explicit default). Flags
	// with their own write are left alone. form is passed in, so this module
	// (also loaded by the Status page tile) does not pull form.js.
	quietFlags: function(form, maps) {
		[].concat(maps).forEach(function(m) {
			(m.children || []).forEach(function(s) {
				(s.children || []).forEach(function(o) {
					if (!(o instanceof form.Flag) || o.write !== form.Flag.prototype.write) return;
					o.write = function(sid, v) {
						var c = this.cfgvalue(sid);
						if (c != null && String(c) === String(v)) return;
						return form.Flag.prototype.write.call(this, sid, v);
					};
				});
			});
		});
	},

	// A real Ping Filter servers reply always carries master_enabled. The
	// rpcd shim's stand-in for a failed or busy call ({"servers":[],
	// "enabled":0,...}) does not, and must not be read as "Ping Filter is
	// off, no servers": a page keeps what it shows instead.
	pfReal: function(j) {
		return !!(j && typeof j === 'object' && !j._err && j.master_enabled != null);
	},
	// Whether Ping Filter is on: from a real reply, else from UCI (callers
	// have uci.load('qos-ex') done).
	pfOn: function(j) {
		if (this.pfReal(j)) return j.enabled === 1 || j.enabled === '1';
		return uci.get('qos-ex', 'pingfilter', 'enabled') === '1';
	},
	// For a page built for one Ping Filter state (on or off): reload it once
	// two polls in a row say the state changed (one could be a stand-in).
	pfFlip: function(view, j, builtOn) {
		if (!this.pfReal(j)) return;
		var on = j.enabled === 1 || j.enabled === '1';
		view._pfFlip = (on !== builtOn) ? (view._pfFlip || 0) + 1 : 0;
		if (view._pfFlip >= 2) window.location.reload();
	},

	// Ping Filter live chart: pfChart(mini) makes it, pfChartPaint draws
	// tele.samples into it at its box width (after it is in the document).
	PFC: { lat: C_LAT, jit: C_JIT, pps: C_PPS },
	pfChart: function(mini) { return pfMakeChart(mini); },
	pfChartPaint: function(ch, tele, basePing, limit) { pfPaintChart(ch, tele, basePing, limit); },
	parseTcText: function(txt) { return parseTcText(txt); },
	ctRow: function(line) { return ctRow(line); },
	// A LAN address: RFC 1918, IPv6 ULA or link-local.
	isLan: function(ip) {
		return /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|f[cd][0-9a-f]{2}:|fe80:)/i.test(ip || '');
	},

	// One Ping Filter server as a Servers-list row (a syncRows descriptor)
	// and the list's header: Servers and the Dashboard's Now playing card
	// share them. o = { playIp, open, home: [lat, lon] | null, blockMode,
	// pingCatch, pingVarPct, homeRadiusKm, act(verb, ip) -> Promise }.
	pfSrvHead: function() {
		return E('thead', {}, E('tr', {}, [
			E('th', {}, _('State')), E('th', {}, _('Server')), E('th', {}, _('Location')),
			E('th', { 'class': 'r' }, _('Distance')),
			E('th', { 'class': 'r' }, _('Ping')), E('th', { 'class': 'r' }, _('Grade')),
			E('th', { 'class': 'r' }, _('Last seen')), E('th', { 'class': 'r' }, '') ]));
	},
	pfSrvRow: function(r, o) {
		var self = this;
		function pin(r, verb, label, title) {
			var on = r.state === verb;
			return E('button', { 'class': 'btn cbi-button pf-actbtn qx-pin' + (on ? ' sel' : ''), 'data-v': verb,
				'title': on ? _('Unpin (grade it by ping or distance again)') : title,
				'click': function(ev) {
					ev.preventDefault();
					var b = ev.currentTarget; b.disabled = true;
					o.act(on ? 'forget' : verb, r.ip).then(function() { b.disabled = false; });
				} }, label);
		}
		function rowDesc(r) {
			var conn = (r.connected === true || r.connected === 'true');
			var playing = (r.ip === o.playIp), home = o.home;
			var badge = E('span', { 'class': 'label pf-badge ' + r.state,
				'title': r.state === 'cached' ? _('Known from the cache but not enforced now') : '' }, [ PF_STATE_TXT[r.state] || r.state ]);
			// Distance from home, km (-1 = home or the server not located).
			var km = (home && parseFloat(r.lat) && parseFloat(r.lon))
				? self.haversineKm(home[0], home[1], parseFloat(r.lat), parseFloat(r.lon)) : -1;
			// Ping Catch tag: an allowed server outside the radius that the
			// catch let in (<= catch + catch*ping_var_pct/100).
			var cLim = (o.pingCatch | 0);
			cLim += Math.floor(cLim * (o.pingVarPct | 0) / 100);
			var caught = o.blockMode === 'distance' && (o.pingCatch | 0) > 0 && r.state === 'allowed' &&
				r.ping > 0 && r.ping <= cLim &&
				km >= 0 && km > (parseInt(o.homeRadiusKm, 10) || 1000);
			var tags = [];
			if (caught) tags.push(E('span', { 'class': 'label pf-badge catch', 'title': _('Outside your radius, let in by the ping catch') }, _('catch')));
			if (r.geo_suspect) tags.push(E('span', { 'class': 'label pf-badge catch',
				'title': _('Its ping puts it within %d km of home: the location is wrong').format(r.bound_km | 0) }, _('loc?')));
			var nSess = r.hist_sessions | 0, sc = nSess > 0 ? self.score(r) : -1;
			var psrc = r.ping_src || r.ping_source;
			var pending = (psrc === 'pending');
			// ~ = an estimate (same /24, area or distance), not a measurement.
			var pEst = !pending && psrc !== 'icmp' && psrc !== 'real';
			var pingTxt = pending ? '…' : (r.ping > 0 ? (pEst ? '~' : '') + r.ping + ' ms' : '—');
			var loc = [ r.city, r.country ].filter(Boolean).join(', ') ||
				(r._list ? _('not seen yet') : self.pfLocated(r) ? '—' : _('not located yet'));
			var age = r.ts > 0 ? self.fmtAge(r.ts) : '—';
			var open = !!o.open;
			var sig = [ r.state, conn ? 1 : 0, playing ? 1 : 0, sc, nSess, caught ? 1 : 0, r.geo_suspect ? 1 : 0,
				pingTxt, loc, km, r.fam || '', age, open ? 1 : 0, r.gname || '' ].join('\u0001');
			return { k: r.ip, cls: 'pf-row' + (open ? ' open' : ''), sig: sig, cells: function() {
				return [
					E('td', {}, [ conn ? E('span', { 'class': 'pf-badge-connected' + (playing ? ' pf-live' : ''),
						'title': playing ? _('Playing on this server now') : _('Connected now') }) : '', conn ? ' ' : '', badge ].concat(tags)),
					E('td', {}, [ E('code', {}, [ r.ip ]),
						r.gname ? E('span', { 'class': 'qos-ex-muted' }, [ ' \u00b7 ' + r.gname ]) : '',
						r.fam === 'v6' ? E('span', { 'class': 'label pf-fam6', 'title': _('IPv6 server') }, 'v6') : '' ]),
					E('td', {}, [ loc ]),
					E('td', { 'class': 'r', 'title': km >= 0 ? _('From your home location') : '' },
						km >= 0 ? km + ' km' : E('span', { 'class': 'qos-ex-muted' }, '—')),
					E('td', { 'class': 'r', 'title': pending ? _('Not measured yet')
						: (pEst && r.ping > 0 ? _('Estimated from nearby servers, not measured yet') : '') },
						E('strong', {}, pingTxt)),
					E('td', { 'class': 'r' }, nSess > 0 ? self.gradePill(sc) : E('span', { 'class': 'qos-ex-muted', 'title': _('Not played on yet') }, '—')),
					E('td', { 'class': 'r qos-ex-muted' }, age),
					E('td', { 'class': 'r pf-acts' }, [
						pin(r, 'whitelist', _('Allow'), _('Always allow')),
						pin(r, 'blacklist', _('Block'), _('Always block')),
						r._list ? '' : E('button', { 'class': 'btn cbi-button pf-actbtn', 'title': _('Forget this server'),
							'click': function(ev) {
								ev.preventDefault();
								var b = ev.currentTarget; b.disabled = true;
								o.act('forget', r.ip).then(function() { b.disabled = false; });
							} }, '×') ])
				];
			} };
		}

		return rowDesc(r);
	},

	// A score as a letter-grade pill, the score in its tooltip.
	gradePill: function(sc) {
		return E('span', { 'class': 'label pf-score qx-gp ' + this.scoreBand(sc),
			'title': sc < 0 ? '' : _('Score %d').format(sc) }, this.grade(sc));
	}
});
