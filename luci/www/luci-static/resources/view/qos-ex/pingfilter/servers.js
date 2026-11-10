'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require poll';
'require view.qos-ex._helpers as h';

// Ping Filter → Servers: the servers Ping Filter shows, and the
// always-allowed / always-blocked lists, in one table (was Discovered
// Servers and Manage Servers). The Map's servers (h.pfVisible) plus every
// list entry, so a listed IP or range not seen yet is listed too.

var CHIPS = [
	[ '',          _('All') ],
	[ 'allowed',   _('Allowed') ],
	[ 'blocked',   _('Blocked') ],
	[ 'whitelist', _('Always allowed') ],
	[ 'blacklist', _('Always blocked') ],
	[ 'cached',    _('Cached') ]
];

return view.extend({
	data: [],
	lists: { whitelist: [], blacklist: [] },
	st: '',
	_open: null,

	load: function() {
		return Promise.all([
			uci.load('qos-ex'),
			h.rpcSafe(h.callPfServers(), { servers: [] }),
			h.rpcSafe(h.callPfLists(), { whitelist: [], blacklist: [] })
		]);
	},

	take: function(j, lists) {
		var view = this;
		if (j) {
			if (Array.isArray(j.servers)) view.data = j.servers;
			view.playStart    = parseInt(j.play_start, 10) || 0;
			view.actPps       = parseInt(j.active_pps, 10) || 20;
			view.blockMode    = String(j.block_mode || 'ping');
			view.pingCatch    = parseInt(j.ping_catch, 10) || 0;
			view.pingVarPct   = isNaN(parseInt(j.ping_var_pct, 10)) ? 5 : parseInt(j.ping_var_pct, 10);
			view.homeLat      = parseFloat(j.home_lat);
			view.homeLon      = parseFloat(j.home_lon);
			view.homeRadiusKm = parseInt(j.home_radius_km || 1000, 10);
		}
		if (lists) [ 'whitelist', 'blacklist' ].forEach(function(k) {
			view.lists[k] = Array.isArray(lists[k]) ? lists[k] : [];
		});
	},

	render: function(loaded) {
		var view = this, j = loaded[1] || {};
		if (!h.pfOn(j)) {
			// Off: the setup card; watch for Ping Filter coming on, then
			// rebuild the page.
			var off = h.pfSetup({ sw: true });
			h.pollWhile(off, function() {
				return h.callPfServers().then(function(r) { h.pfFlip(view, r, false); }).catch(function() {});
			});
			return E([], [ h.pageHead(_('Servers'), 'pf'), off ]);
		}
		view.take(j, loaded[2]);
		var repaint = function() { view.renderTable(); };

		// State filter: one chip per state with its count; click again = all.
		var chips = E('div', { 'class': 'qos-ex-chips', 'click': function(ev) {
			var c = ev.target.closest('[data-st]');
			if (!c) return;
			var v = c.getAttribute('data-st');
			view.st = (view.st === v) ? '' : v;
			repaint();
		} });

		var bar = E('div', { 'class': 'qos-ex-bar' }, [
			E('input', { 'type': 'text', 'id': 'pf-f-search', 'input': repaint,
				'placeholder': _('Search IP, country, city or game…') }),
			E('label', {}, [ _('Sort: '), E('select', { 'id': 'pf-f-sort', 'change': repaint }, [
				E('option', { 'value': 'country-ping' }, _('Country, then ping')),
				E('option', { 'value': 'score-desc' }, _('Best grade first')),
				E('option', { 'value': 'ping-desc' }, _('Highest ping')),
				E('option', { 'value': 'dist-asc' }, _('Nearest')),
				E('option', { 'value': 'ts-desc' }, _('Most recent')),
				E('option', { 'value': 'state-asc' }, _('State')),
				E('option', { 'value': 'ip-asc' }, _('IP'))
			]) ]),
			E('span', { 'class': 'qos-ex-muted', 'id': 'pf-tbl-count' }, '—')
		]);

		var tbody = E('tbody', {});
		// One delegated listener (rows are synced in place): a server row
		// opens or closes its detail row, one at a time.
		tbody.addEventListener('click', function(ev) {
			if (ev.target.closest('button, a') || String(window.getSelection() || '')) return;
			var tr = ev.target.closest('tr'), k = tr && tr.getAttribute('data-k');
			if (!k || k === '_empty' || k.indexOf('det:') === 0) return;
			view._open = (view._open === k) ? null : k;
			repaint();
		});
		var table = E('table', { 'class': 'qos-ex-tbl pf-rows' }, [
			h.pfSrvHead(),
			tbody
		]);

		// Add an IP or range to a list; clear a whole list.
		var input = E('input', { 'type': 'text', 'class': 'qos-ex-dev-q',
			'placeholder': _('Server IP or range, e.g. 1.2.3.4 or 1.2.3.0/24') });
		function add(verb) {
			var ip = input.value.trim();
			if (!ip) return;
			return view.act(verb, ip).then(function(ok) { if (ok) input.value = ''; });
		}
		input.addEventListener('keydown', function(ev) { if (ev.key === 'Enter') { ev.preventDefault(); add('whitelist'); } });
		function clearBtn(key, verb, label, warn) {
			return E('button', { 'class': 'btn cbi-button cbi-button-remove qx-mini', 'data-clear': key,
				'click': ui.createHandlerFn(view, function() {
					var n = view.lists[key].length;
					if (!n || !confirm(_('%s: remove all %d?').format(label, n) + '\n\n' + warn)) return;
					return view.act(verb, '');
				}) }, '');
		}
		var clears = [
			clearBtn('whitelist', 'clear_wl', _('Always allowed'), _('They are graded again on the next scan.')),
			clearBtn('blacklist', 'clear_bl', _('Always blocked'), _('Their blocks go; they are graded again on the next scan.'))
		];

		view.refs = { tbody: tbody, counter: bar.querySelector('#pf-tbl-count'), chips: chips, clears: clears,
			sort: bar.querySelector('#pf-f-sort'), search: bar.querySelector('#pf-f-search') };
		view.renderTable();
		h.pollWhile(tbody, function() { return view.refetch(); });

		return E('div', { 'class': 'qos-ex-scope' }, [
			h.pageHead(_('Servers'), 'pf'),
			E('div', { 'class': 'cbi-section qos-ex-card' }, [
				chips, bar,
				E('div', { 'class': 'pf-serverlist-wrap' }, table),
				E('div', { 'class': 'qos-ex-muted pf-keyline' }, [
					_('Click a server for its details.'), ' ',
					E('span', { 'class': 'pf-badge-connected' }), ' ', _('on it now'), ' · ',
					E('strong', {}, _('Allow')), ' / ', E('strong', {}, _('Block')), ' ',
					_('pin it either way (click again to unpin)'), ' · ',
					E('strong', {}, '×'), ' ', _('forget it') ])
			]),
			E('div', { 'class': 'cbi-section qos-ex-card' }, [
				E('h3', { 'class': 'qos-ex-card-title' }, _('Add a server')),
				E('div', { 'class': 'qos-ex-dev-bar' }, [ input,
					E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(view, function() { return add('whitelist'); }) }, _('Always allow')),
					E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(view, function() { return add('blacklist'); }) }, _('Always block')) ]),
				E('div', { 'class': 'qos-ex-dev-bar' }, clears)
			])
		]);
	},

	// Run a list action; refetch on success. Resolves true when it worked.
	act: function(verb, ip) {
		var view = this;
		return h.callPfAction(verb, ip, 0).then(function(r) {
			if (r && r.ok) { h.notifyOk('✓ ' + (ip || verb)); return view.refetch().then(function() { return true; }); }
			h.notifyErr(_('Action failed') + (ip ? ': ' + ip : ''));
			return false;
		}).catch(function() { h.notifyErr(_('Action failed')); return false; });
	},

	renderTable: function() {
		var view = this, refs = view.refs, tbody = refs.tbody;
		var playIp = h.liveIp(view, view.data, view.actPps);
		var st = view.st, so = refs.sort.value || 'country-ping';
		var fs = (refs.search.value || '').toLowerCase();
		var home = (isFinite(view.homeLat) && isFinite(view.homeLon) && !(view.homeLat === 0 && view.homeLon === 0))
			? [ view.homeLat, view.homeLon ] : null;

		// The Map's servers, then every list entry not among them (an IP not
		// seen yet, or a range), from its saved row.
		var all = h.pfVisible(view.data, view.playStart).slice(), have = {};
		all.forEach(function(r) { have[r.ip] = 1; });
		[ 'whitelist', 'blacklist' ].forEach(function(k) {
			view.lists[k].forEach(function(e) {
				e = (typeof e === 'string') ? { ip: e } : e;
				if (!e.ip || have[e.ip]) return;
				have[e.ip] = 1;
				all.push({ ip: e.ip, state: k, ping: e.ping, country: e.country, city: e.city,
					lat: e.lat, lon: e.lon, ts: e.ts, _list: 1 });
			});
		});
		var cnt = {}, noGeo = 0;
		all.forEach(function(r) {
			cnt[r.state] = (cnt[r.state] | 0) + 1;
			if (!r._list && !h.pfLocated(r)) noGeo++;
		});
		var rows = all.filter(function(r) {
			if (fs && (r.ip + ' ' + (r.country || '') + ' ' + (r.city || '') + ' ' + (r.gname || '')).toLowerCase().indexOf(fs) < 0) return false;
			return !st || r.state === st;
		});

		h.morphKids(refs.chips, CHIPS.map(function(c) {
			var n = c[0] ? (cnt[c[0]] | 0) : all.length;
			return E('span', { 'class': 'qos-ex-chip qos-ex-chip-btn' + (st === c[0] ? ' on' : (st ? ' dim' : '')),
				'data-st': c[0] }, [ c[1] + ' ', E('b', {}, String(n)) ]);
		}));
		refs.clears.forEach(function(b) {
			var k = b.getAttribute('data-clear'), n = view.lists[k].length;
			h.setText(b, (k === 'whitelist' ? _('Clear always allowed') : _('Clear always blocked')) + ' (' + n + ')');
			b.disabled = !n;
		});

		// Country groups are ordered by each group's best (lowest) ping;
		// unmeasured pings and an empty country sort last.
		var EFF = function(p) { return (p == null || p < 0 || p === '') ? 999999 : +p; };
		var bestByCountry = {};
		rows.forEach(function(r) {
			var k = r.country || '￿', v = EFF(r.ping);
			if (bestByCountry[k] === undefined || v < bestByCountry[k]) bestByCountry[k] = v;
		});
		bestByCountry['￿'] = Infinity;
		var played = function(r) { return (r.hist_sessions | 0) > 0 ? h.score(r) : -1; };
		// Distance from home, km; no home or not located sorts last.
		var DIST = function(r) {
			return (home && parseFloat(r.lat) && parseFloat(r.lon))
				? h.haversineKm(home[0], home[1], parseFloat(r.lat), parseFloat(r.lon)) : 999999;
		};
		var cmps = {
			'country-ping': function(a, b) {
				var ak = a.country || '￿', bk = b.country || '￿';
				if (ak !== bk) {
					var ab = bestByCountry[ak], bb = bestByCountry[bk];
					return (ab !== bb) ? ab - bb : ak.localeCompare(bk);
				}
				return EFF(a.ping) - EFF(b.ping);
			},
			'score-desc': function(a, b) { return (played(b) - played(a)) || (EFF(a.ping) - EFF(b.ping)); },
			'ping-desc':  function(a, b) { return (b.ping > 0 ? +b.ping : -1) - (a.ping > 0 ? +a.ping : -1); },
			'dist-asc':   function(a, b) { return (DIST(a) - DIST(b)) || (EFF(a.ping) - EFF(b.ping)); },
			'state-asc':  function(a, b) { return (a.state || '').localeCompare(b.state || ''); },
			'ip-asc':     function(a, b) { return (a.ip || '').localeCompare(b.ip || '', undefined, { numeric: true }); },
			'ts-desc':    function(a, b) { return (b.ts || 0) - (a.ts || 0); }
		};
		if (cmps[so]) rows.sort(cmps[so]);

		var ro = { playIp: playIp, home: home, blockMode: view.blockMode, pingCatch: view.pingCatch,
			pingVarPct: view.pingVarPct, homeRadiusKm: view.homeRadiusKm,
			act: function(verb, ip) { return view.act(verb, ip); } };
		function rowDesc(r) {
			ro.open = (view._open === r.ip);
			return h.pfSrvRow(r, ro);
		}

		var out = [];
		if (!rows.length) {
			var msg = all.length ? _('No servers match the filter.') : _('No servers yet — play a game and they appear here.');
			out.push({ k: '_empty', sig: msg, cells: function() {
				return [ E('td', { 'colspan': 8, 'class': 'qos-ex-muted', 'style': 'padding:12px' }, E('em', {}, msg)) ];
			} });
		} else rows.forEach(function(r) {
			out.push(rowDesc(r));
			if (view._open === r.ip && !r._list) out.push(h.pfDetRow(r, 8, { home: home, liveIp: playIp }));
		});
		h.syncRows(tbody, out);
		h.setText(refs.counter, _('%d of %d').format(rows.length, all.length) +
			(noGeo ? ' · ' + _('%d not on the Map yet (not located)').format(noGeo) : ''));
	},

	// syncRows keeps every row node, so scroll, hover, selection and focus
	// survive a repaint.
	refetch: function() {
		var view = this;
		return Promise.all([ h.callPfServers(), h.callPfLists() ]).then(function(r) {
			if (!view.refs) return;
			h.pfFlip(view, r[0], true);
			view.take(h.pfReal(r[0]) ? r[0] : null, r[1] && typeof r[1] === 'object' && !r[1].error ? r[1] : null);
			view.renderTable();
		}).catch(function() {});
	},

	handleSave: null, handleSaveApply: null, handleReset: null
});
