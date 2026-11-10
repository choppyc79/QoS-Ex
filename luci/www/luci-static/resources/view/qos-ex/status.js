'use strict';
'require view';
'require uci';
'require poll';
'require dom';
'require view.qos-ex._helpers as h';

// Status (Network > QoS-Ex > System > Status): what is installed, what it
// was set up with, and every health check. Nothing here is a statistic --
// every live counter lives on Live > Stats, every live flow on Live > Flows,
// the last nft load error on System > Logs. The Overview shows a health
// check only when it fails, and links here. After the tiles and the health
// card, the cards go in the order a failure cascades: what is installed,
// what tc was told, what nft was told.

// Rule toggles the backend publishes as toggles=name:yes,name:no: the
// Simple or Advanced switches on Setup > Rules, or Adaptive's guard, sticky
// and P2P states (it has no switches). Labelled by what each rule does, not
// by the switch titles.
var TOGGLE_LABEL = {
	bulk_ports:  _('Bulk ports set to LE'),
	vidconf:     _('Video call ports set to CS4 / AF41'),
	gaming_ip:   _('Gaming IP UDP set to EF'),
	lowprio_ip:  _('Low-priority device UDP set to CS1'),
	udp_rate:    _('Fast UDP set to AF11'),
	gaming_guard: _('Gaming EF guard'),
	meter_down:  _('Download packets metered'),
	tcp_500ms:   _('New TCP set to AF11'),
	tcp_upgrade: _('Slow TCP lifted to Video'),
	tcp_10s:     _('Bulk TCP set to LE'),
	bulk_sticky: _('Bulk pairs sticky'),
	p2p:         _('P2P hosts set to LE')
};

function tile(label, value, cls, sub) {
	var kids = [ E('div', { 'class': 'qos-ex-tile-l' }, label),
	             E('div', { 'class': 'qos-ex-tile-v' + (cls ? ' ' + cls : '') }, [ value ]) ];
	if (sub) kids.push(E('div', { 'class': 'qos-ex-tile-sub' }, [ sub ]));
	return E('div', { 'class': 'qos-ex-tile' }, kids);
}

function muted(text, title) {
	var a = { 'class': 'qos-ex-muted' };
	if (title) a.title = title;
	return E('span', a, [ text ]);
}

// Inline muted suffix: " · text". Keeps every value on one line.
function dim(text, title) { return muted(' · ' + text, title); }

// Push one label/value pair onto a qos-ex-grid row list.
function row(rows, label, value) {
	rows.push(E('div', {}, label));
	rows.push(E('div', {}, value));
}

function card(title, rows, extra) {
	return E('div', { 'class': 'cbi-section qos-ex-card' }, [
		E('h3', { 'class': 'qos-ex-card-title' }, title),
		E('div', { 'class': 'qos-ex-grid' }, rows)
	].concat(extra || []));
}

// The @@STATE@@ keys state() and status() both carry: comparing them tells
// whether the full report is worth fetching again.
var LITE = [ 'version', 'enabled', 'qdisc', 'nft_mode', 'wan', 'ifb',
	'ul_kbps_eff', 'dl_kbps_eff', 'backend_stale', 'pf_stale', 'ifb_up',
	'root_qdisc', 'ingress_qdisc', 'ctinfo', 'nft_table', 'init', 'hotplug',
	'running', 'shape_up', 'shape_dn' ];
function liteSig(s) {
	return LITE.map(function(k) { return s[k] || ''; }).join('|');
}

function yesNo(v) {
	return (v === 'yes')
		? E('span', { 'class': 'qos-ex-ok' }, _('on'))
		: muted(_('off'));
}

// An installed file, flagged when it differs from the copy in /root.
function fileRow(path, stale, note) {
	return E([], [ E('code', {}, [ path ]),
		stale === '1'
			? E('span', { 'class': 'qos-ex-warn-text' }, ' · ' + _('differs from /root — re-run installer'))
			: (note ? dim(note) : '') ]);
}

// Download then upload, arrow first: "↓ 800  ↑ 800 Mbps".
// A rate of 0 is a direction left unshaped.
function mbpsPair(dnKbps, upKbps) {
	function one(k) {
		return (String(k) === '0') ? muted(_('not shaped')) : E('code', {}, h.fmtMbps(k));
	}
	return E([], [ '↓ ', one(dnKbps), '\u2003↑ ', one(upKbps), muted(' Mbps') ]);
}

// One class rate: figure over a bar showing its share of the shaped rate.
function rateCell(kbps, shaped) {
	var k = parseFloat(kbps) || 0, t = parseFloat(shaped) || 0;
	var pct = t > 0 ? Math.min(100, k * 100 / t) : 0;
	return E('div', { 'class': 'qos-ex-rate', 'title': Math.round(pct) + _('% of shaped') }, [
		E('span', {}, [ E('strong', {}, h.fmtMbps(kbps)), muted(' · ' + Math.round(pct) + '%') ]),
		E('div', { 'class': 'qos-ex-share' }, E('i', { 'style': 'width:' + pct.toFixed(1) + '%' }))
	]);
}

var CHECKS = [
	[ 'root_qdisc',    _('Root qdisc on WAN') ],
	[ 'ingress_qdisc', _('Download hook (ingress or clsact)') ],
	[ 'ifb_up',        _('Download device present') ],
	[ 'ctinfo',        _('ctinfo DSCP restore') ],
	[ 'nft_table',     _('nftables table loaded') ],
	[ 'init',          _('procd init installed') ],
	[ 'hotplug',       _('Hotplug (ifup) hook') ]
];

return view.extend({
	// Three calls: UCI, status and the host hints (device names). No stats
	// run: it was fetched only to read the CAKE priority, which status
	// already carries (cls_tins) and UCI holds. status answers from the
	// last-known reply when there is one (h.loadC).
	load: function() {
		return Promise.all([
			uci.load('qos-ex'),
			h.loadC('status', h.callStatus),
			h.callHostHints().catch(function() { return {}; })
		]);
	},

	// Every card, built from one status reply. render() and each poll call
	// it; see paint(). Layout top to bottom: tiles, health, installed | leaf
	// qdiscs (CAKE: root qdisc), tc | class rates, nft.
	build: function(st) {
		var qd = st.qdisc || 'cake', adv = st.nft_mode !== 'simple';
		// A device as the router knows it: its name before the MAC or address.
		var hints = this.hints || {};
		function devName(x) {
			var k = String(x).toLowerCase(), hh = hints[k] || hints[String(x).toUpperCase()];
			if (!hh) Object.keys(hints).some(function(m) {
				var a = [].concat(hints[m].ipaddrs || [], hints[m].ip6addrs || []).map(String);
				if (a.indexOf(String(x)) >= 0) { hh = hints[m]; return true; }
			});
			return (hh && hh.name) ? hh.name + ' \u00b7 ' + x : x;
		}
		// toggles=name:yes,name:no, as the rules in force. A row that only
		// matters while its rule is on follows it.
		var tg = {};
		(st.toggles || '').split(',').forEach(function(t) {
			var kv = t.split(':'); if (kv[0]) tg[kv[0]] = kv[1];
		});

		// --- header tiles ------------------------------------------------
		var svcUp = (st.running != null) ? st.running === '1'
			: (st.root_qdisc === '1' && st.ingress_qdisc === '1' &&
			   st.nft_table === '1' && st.ifb_up === '1');
		var upTile = tile(_('Uptime'), h.fmtUptime(st.uptime_s), null, 'v' + (st.version || '?'));
		upTile.querySelector('.qos-ex-tile-v').setAttribute('id', 'qos-ex-up-v');

		var tiles = E('div', { 'class': 'qos-ex-tiles' }, [
			tile(_('Service'), svcUp ? _('Running') : _('Stopped'), svcUp ? 'ok' : 'bad',
				st.enabled === '1' ? _('enabled') : _('disabled')),
			upTile,
			tile(_('Shaper'), h.qdiscDisplay(qd), null,
				qd === 'cake'
					? (st.cls_tins || uci.get('qos-ex', 'cake', 'priority') || 'diffserv4')
					: h.nftModeDisplay(st.nft_mode || 'adaptive')),
			tile(_('Shaped'), E([], [ h.fmtMbps(st.dl_kbps_eff || '0'), ' / ', h.fmtMbps(st.ul_kbps_eff || '0') ]),
				null, _('Mbps ↓ / ↑')),
			tile(_('Path'), (st.wan || '?') + ' → ' + (st.ifb || '?'))
		]);

		// --- installed components ------------------------------------------
		var missing = (st.pkg_missing || '').split(/\s+/).filter(function(p) { return p; });
		var pkgVal;
		if (!st.pkg_mgr)
			pkgVal = muted(_('no apk / opkg'));
		else if (!missing.length)
			pkgVal = E([], [ E('span', { 'class': 'qos-ex-ok' }, '✔ ' + _('all present')), dim(st.pkg_mgr) ]);
		else
			pkgVal = E([], [ E('span', { 'class': 'qos-ex-err' }, missing.length + _(' missing')),
				E('div', { 'class': 'qos-ex-warn-text', 'style': 'font-size:11px' },
					[ (st.pkg_mgr === 'apk' ? 'apk add ' : 'opkg install ') + missing.join(' ') ]) ]);

		var instRows = [];
		row(instRows, _('Shaper'),
			fileRow(st.script_bin || '/usr/sbin/qos-ex.sh', st.backend_stale, 'v' + (st.version || '?')));
		row(instRows, _('Ping Filter'),
			st.pf_installed === '1'
				? fileRow(st.pf_bin || '/usr/sbin/qos-ex-pf.sh', st.pf_stale)
				: muted(_('not installed')));
		row(instRows, _('procd init'), st.init === '1'
			? E([], [ E('code', {}, '/etc/init.d/QoS-Ex'),
				dim(st.init_enabled === '1' ? _('enabled') : _('not enabled')) ])
			: E('span', { 'class': 'qos-ex-err' }, _('missing')));
		row(instRows, _('Hotplug'), st.hotplug === '1'
			? E([], [ E('code', {}, '99-QoS-Ex'), dim(_('on ') + (st.wan || '?') + _(' up')) ])
			: E('span', { 'class': 'qos-ex-err' }, _('missing')));
		row(instRows, _('Config'), E('code', {}, '/etc/config/qos-ex'));
		row(instRows, _('Packages'), pkgVal);
		var instCard = card(_('Installed Files'), instRows);

		// --- queue setup (tc) ---------------------------------------------
		var cfgUl = uci.get('qos-ex', 'settings', 'upload_kbps')   || st.ul_kbps_eff || '0';
		var cfgDl = uci.get('qos-ex', 'settings', 'download_kbps') || st.dl_kbps_eff || '0';
		var effUl = st.ul_kbps_eff || cfgUl, effDl = st.dl_kbps_eff || cfgDl;

		var ratioCell;
		if (!st.bw_ratio || st.bw_ratio === 'off' || st.bw_ratio === '0')
			ratioCell = muted(_('off'));
		else
			ratioCell = E([], [
				E('strong', {}, [ (st.bw_ratio_eff || '?') + '×' ]),
				dim(st.bw_ratio === 'auto' ? _('auto') : _('fixed')),
				dim(String(cfgDl) !== String(effDl) ? _('limiting download') : _('not binding'))
			]);

		var ackCell = (st.ack_on === 'yes')
			? E('span', { 'title': _('pps slow/med/fast/xfast: ') + [ st.ack_slow, st.ack_med,
				st.ack_fast, st.ack_xfast ].map(function(v) { return v || '?'; }).join(' / ') },
				[ E('span', { 'class': 'qos-ex-ok' }, _('on')), dim(st.ack_filter || 'auto') ])
			: E([], [ muted(_('off')), dim(st.ack_filter || 'auto') ]);

		var redirect = (st.shape_dn === '0') ? muted(_('not shaped'))
			: E([], [ E('code', {}, [ 'ctinfo → ' + (st.ifb || '?') ]),
				dim((st.ifb_filters || '0') + _(' filters')) ]);

		var qRows = [];
		row(qRows, _('Line'), mbpsPair(st.dl_kbps_line || cfgDl, st.ul_kbps_line || cfgUl));
		row(qRows, _('Headroom'), (st.bw_headroom && st.bw_headroom !== '100')
			? E('strong', {}, [ st.bw_headroom + '%' ]) : muted('100%'));
		row(qRows, _('Shaped'), mbpsPair(effDl, effUl));
		if (qd !== 'cake') row(qRows, _('Ratio cap'), ratioCell);
		row(qRows, _('Overhead / MPU'), E([], [
			E('code', {}, [ (st.overhead || '?') + ' B' ]), ' / ',
			E('code', {}, [ (st.mpu || '?') + ' B' ])
		]));
		row(qRows, _('ACK filter'), ackCell);
		row(qRows, _('Root qdisc'), E([], [ E('code', {}, h.qdiscDisplay(qd)),
			dim((st.wan || '?') + ' + ' + (st.ifb || '?')) ]));
		if (qd !== 'cake') {
			row(qRows, _('Leaf qdisc'), E([], [
				E('code', {}, [ st.game_qdisc || 'pfifo' ]), muted(_(' game')), ' · ',
				E('code', {}, [ st.def_qdisc || 'fq_codel' ]), muted(_(' rest')),
				st.def_tune ? dim(st.def_tune === 'manual' ? _('manual') : _('auto')) : ''
			]));
		}
		row(qRows, st.download_on === 'lan' ? _('Download (LAN egress)') : _('Ingress'), redirect);

		// Class rates, structure only. cls_<cid> is name|up|dn|detail, built
		// from the same specs setup_hfsc/setup_htb hand to tc, so what is
		// drawn cannot drift from what the kernel was told. Its own card to
		// the right of the qdisc card; the gaming class (1:10) is the game
		// reserve, so that is not repeated on the left. Detail in the tooltip.
		var cRows = [];
		[ '10', '11', '12', '13', '14', '15' ].forEach(function(cid) {
			var cv = st['cls_' + cid];
			if (!cv) return;
			var cf = String(cv).split('|');
			cRows.push(E('div', { 'title': cf[3] || '' }, [ E('code', {}, [ '1:' + cid ]), ' ', E('strong', {}, [ cf[0] || '' ]) ]));
			cRows.push(rateCell(cf[2], effDl));
			cRows.push(rateCell(cf[1], effUl));
		});
		if (st.cls_mode === 'cake' && st.cls_tins)
			row(qRows, _('Tins'), E('code', {}, [ st.cls_tins ]));
		var qCard = card(_('Traffic Shaping (tc)'), qRows);

		// Leaf qdiscs of 1:11-1:15: leaf_<cid> is upload|download, each the
		// qdisc line tc holds. One line when both directions match. Sits
		// beside Installed Files, above Class Rates.
		var lRows = [];
		[ '11', '12', '13', '14', '15' ].forEach(function(cid) {
			if (!st['leaf_' + cid]) return;
			var lf = String(st['leaf_' + cid]).replace(/ drop_batch \d+/g, '').split('|');
			var up = lf[0], dn = lf[1];
			row(lRows, E([], [ E('code', {}, [ '1:' + cid ]), ' ',
				E('strong', {}, [ String(st['cls_' + cid] || '').split('|')[0] ]) ]),
				(up && dn && up !== dn)
					? E([], [ E('div', {}, [ '↓ ', E('code', {}, [ dn ]) ]),
					          E('div', {}, [ '↑ ', E('code', {}, [ up ]) ]) ])
					: E('code', {}, [ dn || up ]));
		});
		// CAKE has no leaves: its root line carries every CAKE setting in force.
		var rRows = [];
		if (qd === 'cake' && st.root_tc) {
			var rt = String(st.root_tc).split('|');
			if (rt[1]) row(rRows, '↓ ' + (st.ifb || ''), E('code', {}, [ rt[1] ]));
			if (rt[0]) row(rRows, '↑ ' + (st.wan || ''), E('code', {}, [ rt[0] ]));
		}
		var topRow = lRows.length
			? E('div', { 'class': 'qos-ex-cols' }, [ instCard,
				card([ _('Leaf Qdiscs'), muted(_('1:11 to 1:15 · as loaded in tc')) ], lRows) ])
			: rRows.length
			? E('div', { 'class': 'qos-ex-cols' }, [ instCard,
				card([ _('Root Qdisc'), muted(_('as loaded in tc')) ], rRows) ])
			: instCard;
		var queueCard = cRows.length
			? E('div', { 'class': 'qos-ex-cols' }, [ qCard,
				E('div', { 'class': 'cbi-section qos-ex-card' }, [
					E('h3', { 'class': 'qos-ex-card-title' }, [ _('Class Rates'),
						muted(_('ceiling per class · bar = share of shaped rate')) ]),
					E('div', { 'class': 'qos-ex-rates' }, [
						E('div', { 'class': 'qos-ex-rates-h qos-ex-muted' }, _('Class')),
						E('div', { 'class': 'qos-ex-rates-h qos-ex-muted' }, '↓ ' + _('Download (Mbps)')),
						E('div', { 'class': 'qos-ex-rates-h qos-ex-muted' }, '↑ ' + _('Upload (Mbps)'))
					].concat(cRows))
				])
			])
			: qCard;

		// --- classifier setup (nft) ---------------------------------------
		var mssCell;
		if (!st.mss_mode || st.mss_mode === 'off')
			mssCell = muted(_('off'));
		else if (!st.mss_up && !st.mss_dn)
			mssCell = E([], [ E('strong', {}, [ st.mss_mode ]), dim(_('inactive'),
				_('both directions at or above ') + (st.mss_gate || '?') + ' kbps') ]);
		else
			mssCell = E([], [ E('strong', {}, [ st.mss_mode ]),
				dim('↑ ' + (st.mss_up || '—') + ' ↓ ' + (st.mss_dn || '—')) ]);

		// Bulk TCP: off with its rule. Sticky (the source / destination pair
		// stays Bulk for bulk_timeout) exists in Advanced and Adaptive, not
		// Simple, and 0 turns it off.
		var bulkCell = (st.nft_mode === 'adaptive') ? E([], [
			_('over '), E('code', {}, [ (st.ada_heavy_pct || '25') + '%' ]), muted(_(' of the line for ') + (st.ada_heavy_secs || '10') + ' s'),
			(st.bulk_timeout && st.bulk_timeout !== '0') ? dim(_('sticky ') + st.bulk_timeout + ' s') : ''
		]) : (tg.tcp_10s === 'no') ? muted(_('off')) : E([], [
			_('past '), E('code', {}, [ h.fmtBytes(st.first_10s || 0) ]), muted(_(' in 10 s')),
			(adv && st.bulk_timeout && st.bulk_timeout !== '0')
				? dim(_('sticky ') + st.bulk_timeout + ' s') : ''
		]);

		// A device list whose rule is off is kept, but marked.
		function devCell(rule, a, b, c) {
			return (tg[rule] === 'no') ? E([], [ listCell(a, b, c), dim(_('rule off')) ]) : listCell(a, b, c);
		}

		function listCell() {
			var v = [].filter.call(arguments, function(x) { return x; });
			if (!v.length) return muted(_('none'));
			return E([], v.join(' ').split(/\s+/).filter(Boolean).map(function(x) {
				return E('code', { 'style': 'margin-right:6px' }, [ devName(x) ]);
			}));
		}

		var nRows = [];
		row(nRows, _('Table'), E([], [ E('code', {}, [ 'inet ' + (st.nft_tbl || '—') ]),
			dim(h.nftModeDisplay(st.nft_mode || 'adaptive')),
			dim((st.nft_chains || '0') + _(' chains, ') + (st.nft_sets || '0') + _(' sets')) ]));
		row(nRows, _('DSCP wash'), E([], [ '↑ ', yesNo(st.wash_up), '  ↓ ', yesNo(st.wash_down) ]));
		row(nRows, _('MSS clamp'), mssCell);
		row(nRows, _('Bulk TCP'), bulkCell);
		row(nRows, _('Web ports'), E('code', {}, [ st.http_ports || '—' ]));
		// Simple uses these lists only while their rule is on; Advanced always.
		if (st.vidconf_ports && (adv || tg.vidconf !== 'no'))
			row(nRows, _('Video ports'), E('code', {}, [ st.vidconf_ports ]));
		if ((st.tcp_bulk || st.udp_bulk) && (adv || tg.bulk_ports !== 'no'))
			row(nRows, _('Bulk ports'), E([], [
				st.tcp_bulk ? E('code', {}, [ 'tcp ' + st.tcp_bulk ]) : '',
				(st.tcp_bulk && st.udp_bulk) ? ' ' : '',
				st.udp_bulk ? E('code', {}, [ 'udp ' + st.udp_bulk ]) : '' ]));
		if (st.nft_mode === 'adaptive' && st.ada_vpn_ports)
			row(nRows, _('VPN ports'), E('code', {}, [ st.ada_vpn_ports ]));
		row(nRows, _('Gaming devices'), devCell('gaming_ip', st.gaming_mac, st.gaming_ip4, st.gaming_ip6));
		row(nRows, _('Low-priority devices'), devCell('lowprio_ip', st.lowprio_mac, st.lowprio_ip4, st.lowprio_ip6));

		// toggles=name:yes,name:no -- one chip per rule block the running
		// mode actually emits, so a rule that is off is visible as off.
		var tglEls = (st.toggles || '').split(',').filter(function(t) { return t; }).map(function(t) {
			var kv = t.split(':'), on = (kv[1] === 'yes');
			return E('div', { 'class': 'qos-ex-check ' + (on ? 'ok' : 'bad') }, [
				E('span', { 'class': 'dot' }), TOGGLE_LABEL[kv[0]] || kv[0]
			]);
		});
		var nftCard = card(_('Packet Classification (nft)'), nRows, tglEls.length
			? [ E('div', { 'class': 'qos-ex-checks',
				'style': 'margin-top:12px;padding-top:12px;border-top:1px solid var(--border-color-medium, #ddd)' }, tglEls) ] : []);

		// --- health: every check, in the order a fault spreads (root queue
		// -> download queue -> mirror device -> DSCP restore -> ruleset ->
		// service -> interface hook); the first red dot is the cause. The
		// Overview shows them only when one fails and links here.
		var on = st.enabled === '1', bad = 0, warns = [];
		var dots = CHECKS.map(function(c) {
			var off = h.compOff(st, c[0]), ok = off || st[c[0]] === '1';
			if (on && !ok) bad++;
			return E('div', { 'class': 'qos-ex-check ' + (!on ? 'idle' : ok ? 'ok' : 'bad') }, [
				E('span', { 'class': 'dot' }), c[1], off ? muted(' \u2014 ' + _('not shaped')) : '' ]);
		});
		if (st.wan_match === '0')
			warns.push([ _('WAN mismatch: set '), E('code', {}, [ st.wan || '?' ]), _(', line is on '), E('code', {}, [ st.wan_live || '?' ]) ]);
		if (st.offload_sw === '1' || st.offload_hw === '1')
			warns.push([ _('Flow offloading is on \u2014 classification bypassed. '),
				E('a', { 'href': L.url('admin', 'network', 'qos-ex', 'system', 'maintenance') }, _('Turn it off on Maintenance')) ]);
		if (st.ct_acct === '0')
			warns.push([ E('code', {}, 'nf_conntrack_acct'), _(' is off \u2014 restart the shaper') ]);
		// mwan3 / pbr keep routing choices in the conntrack mark, which
		// classify rewrites whole: theirs do not hold while QoS-Ex shapes.
		if (st.ct_mark_users)
			warns.push([ E('code', {}, [ st.ct_mark_users ]), _(' also uses the conntrack mark; QoS-Ex overwrites it.') ]);
		if (st.pf_geo_down === '1')
			warns.push([ _('Ping Filter: no location service answers; check ad blockers.') ]);
		var health = E('div', { 'class': 'cbi-section qos-ex-card' + ((on && (bad || warns.length)) ? ' qx-alert' : '') }, [
			E('h3', { 'class': 'qos-ex-card-title' }, [ _('Health'),
				!on ? E('span', { 'class': 'label pf-pill' }, _('shaper off'))
				: (bad || warns.length) ? E('span', { 'class': 'label pf-pill off' }, _('%d issue(s)').format(bad + warns.length))
				: E('span', { 'class': 'label pf-pill on' }, _('all good')) ]),
			E('div', { 'class': 'qos-ex-checks' }, dots)
		].concat(warns.map(function(w) { return E('div', { 'class': 'qos-ex-warn-text qx-warn' }, w); })));

		return [ tiles, health, topRow, queueCard, nftCard ];
	},

	// Every card is rebuilt from each poll, like LuCI's own Status page.
	// Through 1.0.3.6 they were built once and only the raw report, the
	// check dots and the service tile were patched afterwards -- and that
	// patch never ran (see h.pollWhile). A rebuild happens only when the
	// state changed; uptime, which changes every tick, is written in place.
	// The full text report is not shown in LuCI (1.2.9.5): `qos-ex.sh status`
	// over SSH prints it.
	render: function(loaded) {
		var view = this;
		view.stOut  = (loaded[1] && loaded[1].output) || '';
		view.hints  = loaded[2] || {};
		view.live   = E('div');

		view.paint();
		h.pollWhile(view.live, function() { return view.poll(); },
			!!(loaded[1] && loaded[1]._cached));

		return E([], [ h.pageHead(_('Status')), view.live ]);
	},

	// The light `state` every tick, plus UCI (the rate cards quote it). The
	// full report -- a package-manager query, a complete nft dump, the WAN
	// probe -- is re-fetched only when state moved (a restart, a flag, a
	// UCI commit) and once a minute regardless.
	poll: function() {
		var view = this;
		uci.unload('qos-ex');
		return Promise.all([
			uci.load('qos-ex').catch(function() { return null; }),
			h.rpcSafe(h.callState())
		]).then(function(r) {
			if (r[1]._err) return;
			var ns = h.parseState(r[1].output || '').state;
			var old = h.parseState(view.stOut).state;
			var restarted = (parseInt(ns.uptime_s, 10) || 0) < (parseInt(view.upNow, 10) || 0);
			// status carries cfg_sum too (shaper 3.1.5.2): a reply from the
			// cache, or one taken before a Save & Apply, is refetched at once.
			// A move also refetches the next three polls, while procd's
			// reload rebuilds tc and nft behind the commit.
			var cfgMoved = (old.cfg_sum != null) ? ns.cfg_sum !== old.cfg_sum
				: (view.cfgSum != null && ns.cfg_sum !== view.cfgSum);
			if (cfgMoved || restarted) view.settle = 4;
			view.lite = true;
			view.upNow = ns.uptime_s;
			view.cfgSum = ns.cfg_sum;
			view.ticks = (view.ticks || 0) + 1;
			var settling = (view.settle || 0) > 0;
			if (settling) view.settle--;
			if (!restarted && !cfgMoved && !settling && liteSig(ns) === liteSig(old) && view.ticks < 12) return;
			view.ticks = 0;
			return h.rpcSafe(h.callStatus()).then(function(s) {
				if (!s._err) view.stOut = s.output || '';
			});
		}).then(function() { view.paint(); });
	},

	paint: function() {
		var st = h.parseState(this.stOut).state, keep = {};
		Object.keys(st).forEach(function(k) { if (k !== 'uptime_s') keep[k] = st[k]; });
		var sig = JSON.stringify([ keep,
			uci.get('qos-ex', 'settings', 'upload_kbps'),
			uci.get('qos-ex', 'settings', 'download_kbps'),
			uci.get('qos-ex', 'cake', 'priority') ]);
		if (this.live.__qosExSig !== sig) {
			this.live.__qosExSig = sig;
			dom.content(this.live, this.build(st));
		}
		h.setText(this.live.querySelector('#qos-ex-up-v'), h.fmtUptime(this.lite ? this.upNow : st.uptime_s));
	},

	handleSave: null, handleSaveApply: null, handleReset: null
});
