'use strict';
'require baseclass';
'require uci';
'require view.qos-ex._helpers as h';

// The QoS-Ex tile on LuCI's Status -> Overview: state pills like the
// banner's and the headline figures (rates, gaming devices, Ping Filter,
// Now playing), in the System -> Status tile markup (the helpers module
// brings the stylesheet; h.cssCopy() is the tile's own copy where a theme
// switched that one off).
// LuCI calls load() and render() again on every poll, so the last counter
// sample is kept on the instance: a rate needs two. The update check is
// asked once an hour (the router answers from its own 1 h cache).
return baseclass.extend({
	title: _('QoS-Ex'),

	load: function() {
		var self = this;
		// A login that may not read the QoS-Ex config has no use for the tile,
		// and every call below would be refused: the rejection is passed on,
		// so LuCI leaves the tile out (it skips an include whose load fails)
		// and nothing else is asked.
		return uci.load('qos-ex').then(function() {
			var now = Date.now(), pf = self.pf;
			if (!self.updT || now - self.updT > 3600000) { self.updT = now; self.updP = h.updAvail(); }
			// While Ping Filter is off its reply is asked for every sixth poll
			// only, as on the Overview: each one runs the Ping Filter script.
			var pfDue = !h.pfReal(pf) || pf.enabled === 1 || pf.enabled === '1' ||
				!(self.pfSkip = ((self.pfSkip || 0) + 1) % 6);
			return Promise.all([
				null,
				// A failed call draws no banner on LuCI's own page: the tile
				// then reads as stopped.
				h.callCounters().catch(function() { return { output: '' }; }),
				pfDue ? h.callPfServers().catch(function() { return {}; }) : pf,
				self.updP
			]);
		});
	},

	render: function(d) {
		var self = this, c = h.parseCounters((d[1] && d[1].output) || ''), m = c.meta, pf = d[2] || {}, upd = d[3] || [];
		if (h.pfReal(pf)) self.pf = pf;
		function g(s, k) { return uci.get('qos-ex', s, k); }
		function n(k) { return L.toArray(g('ips', k)).filter(function(v) { return String(v || '').trim(); }).length; }
		function pill(cls, text) { return E('span', { 'class': 'label pf-pill ' + cls }, [ text ]); }
		function tile(label, value, sub) {
			return E('div', { 'class': 'qos-ex-tile' }, [
				E('div', { 'class': 'qos-ex-tile-l' }, [ label ]),
				E('div', { 'class': 'qos-ex-tile-v' }, [ value ]),
				E('div', { 'class': 'qos-ex-tile-sub' }, [ sub || '' ]) ]);
		}
		var running = /^(cake|hfsc|htb)$/.test(m.qd_up || '') || /^(cake|hfsc|htb)$/.test(m.qd_down || '');
		function one(v) { return v === 1 || v === '1'; }
		var pfOn = one(pf.enabled) && one(pf.master_enabled) && running;
		var act = pf.activity || 'idle', cnt = h.pfCounts(pf);

		// Rate now: counter bytes against the previous poll's.
		var now = Date.now(), p = self.prev, b = {}, rate = {};
		[ 'down', 'up' ].forEach(function(k) {
			var rows = c.rows[k] || [], t = 0;
			if (!rows.length) return;
			rows.forEach(function(r) { t += r.bytes; });
			b[k] = t;
			if (p && p.b[k] !== undefined && now - p.t > 500 && t >= p.b[k]) rate[k] = (t - p.b[k]) * 8000 / (now - p.t);
		});
		self.prev = { t: now, b: b };
		function dir(k, kbps) {
			return !running ? [ '\u2014', '' ] : !(+kbps > 0) ? [ '\u2014', _('not shaped') ]
				: [ rate[k] !== undefined ? h.fmtRate(rate[k]) : '\u2026', _('of %s Mbps shaped').format(h.fmtMbps(kbps)) ];
		}
		var dn = dir('down', m.dl_kbps), up = dir('up', m.ul_kbps);

		// The server being played on, by the Dashboard's own rule.
		var lv = pfOn ? h.pickLive(pf.servers, self.liveIp, pf.active_pps) : null;
		self.liveIp = lv ? lv.ip : null;
		var mode = h.pfModeText(pf, true);

		return E('div', {}, [
			h.cssCopy(),
			E('div', { 'style': 'display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:0 0 10px' }, [
				pill(running ? 'on' : 'off', '\u25cf ' + (running ? _('Shaping') + ' \u00b7 ' + String(m.qdisc || g('settings', 'qdisc') || '').toUpperCase()
					: g('settings', 'enabled') === '1' ? _('Stopped') : _('Off'))),
				pill(pfOn ? 'on' : 'off', '\u25cf ' + _('Ping Filter') + ' ' + (pfOn ? _('ON') : _('OFF'))),
				!pfOn ? '' : pill(act === 'active' ? 'active' : act === 'matchmaking' ? 'matchmaking' : 'idle',
					(act === 'active' ? '\u29bf ' + _('active') : act === 'matchmaking' ? '\u29be ' + _('matchmaking') : '\u2299 ' + _('idle'))),
				!upd.length ? '' : E('a', { 'href': L.url('admin/network/qos-ex/system/maintenance'),
					'class': 'qos-ex-warn-text', 'style': 'margin-left:auto' }, '\u2b06 ' + _('Update available')),
				E('a', { 'href': L.url('admin/network/qos-ex'), 'style': upd.length ? '' : 'margin-left:auto' }, _('Overview') + ' \u2192')
			]),
			E('div', { 'class': 'qos-ex-tiles', 'style': 'margin:0' }, [
				tile(_('Download now'), dn[0], dn[1]),
				tile(_('Upload now'), up[0], up[1]),
				tile(_('Gaming devices'), String(n('gaming_mac') + n('gaming_ipv4') + n('gaming_ipv6')), _('priority')),
				tile(_('Ping Filter'), pfOn ? mode : _('off'),
					pfOn ? _('%d allowed \u00b7 %d blocked').format(cnt.allowed, cnt.blocked) : ''),
				tile(_('Now playing'), lv ? ([ lv.city, lv.country ].filter(Boolean).join(', ') || lv.ip) : '\u2014',
					lv ? (lv.ping > 0 ? lv.ping + ' ms \u00b7 ' : '') + (lv.state || '') : pfOn ? _('no game server') : '')
			])
		]);
	}
});
