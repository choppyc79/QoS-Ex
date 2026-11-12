'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require view.qos-ex._helpers as h';

// Logs (Network > QoS-Ex > System > Logs): the last nft load error of each
// ruleset, then the QoS-Ex log (/var/log/qos-ex.log: shaper and updates),
// the Ping Filter log (/var/log/qos-ex-pf-daemon.log) and the last update's
// output (/var/log/qos-ex-update.log; Maintenance shows only its progress).
// Kept live on the poll; Clear logs empties them all and removes the nft
// error files.

// Line counts on offer. The tail happens in the shim (logdump caps at 2000),
// so a bigger pick only costs what it shows.
var SIZES = [ 50, 200, 1000 ];

function noErr(t) { return !t || /^\((no recent|no output|log empty)/.test(t) || /^\s*$/.test(t) || /not installed/i.test(t); }

return view.extend({
	// The config is for h.pageHead's check of the menu this browser tab
	// kept; the page opens without it.
	load: function() {
		return Promise.all([
			h.rpcSafe(h.callLogdump(SIZES[0], 'shaper')),
			h.rpcSafe(h.callLogdump(SIZES[0], 'pf')),
			h.rpcSafe(h.callLogdump(SIZES[0], 'update')),
			h.rpcSafe(h.callNfterr()),
			h.rpcSafe(h.callPfText('nfterr', ''), {}),
			uci.load('qos-ex').catch(function() { return null; })
		]);
	},

	render: function(loaded) {
		var view = this;
		view.n = { shaper: SIZES[0], pf: SIZES[0], update: SIZES[0] };
		// Detached-at-first-paint refs; later writes re-resolve by id (an SPA
		// re-render detaches the first tree).
		view.el = {};

		// One log card: title with a line-count picker, the text, and the
		// scroll position kept across refreshes unless it sat at the bottom.
		function logCard(src, title, sub) {
			var pre = E('pre', { 'class': 'qos-ex-pre', 'id': 'qos-ex-log-' + src,
				'style': 'max-height:420px;overflow:auto;margin:0' }, '');
			view.el['qos-ex-log-' + src] = pre;
			var sel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto',
				'change': function(ev) {
					view.n[src] = parseInt(ev.target.value, 10) || SIZES[0];
					return view.pull(src);
				} }, SIZES.map(function(n) {
					return E('option', { 'value': String(n) }, _('Last %d lines').format(n));
				}));
			return E('div', { 'class': 'cbi-section qos-ex-card' }, [
				E('h3', { 'class': 'qos-ex-card-title' }, [ title,
					E('span', { 'class': 'qos-ex-muted', 'style': 'font-size:12px' }, sub),
					E('span', { 'class': 'qos-ex-tools' }, sel) ]),
				pre
			]);
		}

		var errBox = view.el['qos-ex-log-errs'] = E('div', { 'id': 'qos-ex-log-errs' });
		var head = h.pageHead(_('Logs'), null, { tools: [
				E('button', { 'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(view, function() { return view.poll(); }) }, _('Refresh')),
				E('button', { 'class': 'cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(view, function() {
						if (!confirm(_('Empty all QoS-Ex logs and the nft error files?'))) return;
						return h.callAction('clear_log').then(function(r) {
							(r && r.ok) ? h.notifyOk(_('Logs cleared')) : h.notifyErr(_('Clear logs failed'));
							return view.poll();
						}).catch(function(e) { h.notifyErr(_('Clear logs failed') + ' (' + ((e && e.message) || e) + ')'); });
					}) }, _('Clear logs')) ] });

		var page = E('div', { 'class': 'qos-ex-scope' }, [ head, errBox,
			logCard('shaper', _('QoS-Ex log'), '/var/log/qos-ex.log · ' + _('shaper')),
			logCard('pf', _('Ping Filter log'), '/var/log/qos-ex-pf-daemon.log · ' + _('daemon + actions')),
			logCard('update', _('Update log'), '/var/log/qos-ex-update.log · ' + _('the last update'))
		]);
		view.put('shaper', loaded[0]);
		view.put('pf', loaded[1]);
		view.put('update', loaded[2]);
		view.errs(loaded[3], loaded[4]);
		h.pollWhile(head, function() { return view.poll(); });
		return page;
	},

	// Write one log, following the tail only when the reader is already at
	// the bottom (or has not scrolled), so reading back up is not yanked.
	put: function(src, r) {
		var pre = document.getElementById('qos-ex-log-' + src) || this.el['qos-ex-log-' + src];
		if (!pre || !r || r._err) return;
		var atEnd = !pre.scrollTop || pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 8;
		var t = r.output || _('(log empty)');
		if (pre.__qxTxt === t) return;
		pre.__qxTxt = t;
		// [ERR ] lines in red, [WARN] in amber; the rest as they are.
		dom.content(pre, t.split('\n').map(function(l, i, a) {
			var c = /\[ERR|\bERROR\b|\bFAILED\b/.test(l) ? 'qx-log-err' : /\[WARN|\bwarn(ing)?\b/i.test(l) ? 'qx-log-warn' : null;
			l += (i < a.length - 1) ? '\n' : '';
			return c ? E('span', { 'class': c }, [ l ]) : l;
		}));
		if (atEnd) pre.scrollTop = pre.scrollHeight;
	},

	// nft load errors: a red card per ruleset that has one, else one quiet
	// line saying there are none.
	errs: function(q, p) {
		var box = document.getElementById('qos-ex-log-errs') || this.el['qos-ex-log-errs'];
		if (!box) return;
		var qt = (q && !q._err) ? String(q.output || '') : '';
		var pt = (p && !p._err && !p.error) ? String(p.output || '') : '';
		var list = [];
		if (!noErr(qt)) list.push([ _('Shaper — last nft load error'), '/var/run/qos-ex-nft.err', qt ]);
		if (!noErr(pt)) list.push([ _('Ping Filter — last nft error'), '/var/run/qos-ex-pingfilter-nft.err', pt ]);
		var sig = JSON.stringify(list);
		if (box.__qosExSig === sig) return;
		box.__qosExSig = sig;
		dom.content(box, list.length ? list.map(function(e) {
			return E('div', { 'class': 'cbi-section qos-ex-card qos-ex-card-err' }, [
				E('h3', { 'class': 'qos-ex-card-title' }, [ e[0],
					E('span', { 'class': 'qos-ex-muted', 'style': 'font-size:12px' }, e[1]) ]),
				E('pre', { 'class': 'qos-ex-pre qos-ex-pre-err', 'style': 'max-height:30vh;overflow:auto;margin:0' }, [ e[2] ])
			]);
		}) : E('div', { 'class': 'cbi-section qos-ex-card' }, [
			E('h3', { 'class': 'qos-ex-card-title' }, _('nft load errors')),
			E('div', { 'class': 'qos-ex-ok' }, '✔ ' + _('none — both rulesets loaded cleanly'))
		]));
	},

	pull: function(src) {
		var view = this;
		return h.rpcSafe(h.callLogdump(view.n[src], src)).then(function(r) { view.put(src, r); });
	},

	poll: function() {
		var view = this;
		return Promise.all([
			view.pull('shaper'), view.pull('pf'), view.pull('update'),
			h.rpcSafe(h.callNfterr()), h.rpcSafe(h.callPfText('nfterr', ''), {})
		]).then(function(r) { view.errs(r[3], r[4]); });
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
