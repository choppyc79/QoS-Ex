'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require view.qos-ex._helpers as h';

// Auto Setup, its own tab while autosetup.done is 0: a fresh install, Reset
// to defaults, or System -> Maintenance -> Run Auto Setup. The menu shows
// the tab only then (menu.d uci depends) and Network -> QoS-Ex opens it
// first; Apply, Finish, Manual setup and a restore set done to 1 and it
// goes. The router check, the line's speed, the devices and the suggested
// settings: nothing changes until Apply. Nothing here polls but the speed
// test's progress, a file the router hands over as it is, so a small
// router gives the test all of its CPU. Backend: qos-ex.sh autosetup.

// key=value lines: the router check (suggest -p, probe) and the speed
// test's state file. The suggestion lines (set|... keep|... note|...) are
// not key=value.
function asKv(out) {
	var o = {};
	String(out || '').split(/\n/).forEach(function(l) {
		var m = /^([a-z0-9_]+)=(.*)$/.exec(l);
		if (m) o[m[1]] = m[2];
	});
	return o;
}
// suggest: "set|key|current|suggested|why", "keep|key|current|why" (the queue
// and rule set when they stay) and "note|text" lines.
function asSuggestions(out) {
	var r = { set: [], keep: [], note: [] };
	String(out || '').split(/\n/).forEach(function(l) {
		var f = l.split('|');
		if (f[0] === 'set' && f.length >= 5) r.set.push({ key: f[1], cur: f[2], val: f[3], why: f.slice(4).join('|') });
		else if (f[0] === 'keep' && f.length >= 4) r.keep.push({ key: f[1], cur: f[2], val: f[2], why: f.slice(3).join('|'), keep: true });
		else if (f[0] === 'note' && f[1]) r.note.push(f.slice(1).join('|'));
	});
	return r;
}

var AS_STEER = 'network.packet_steering';
var AS_NAMES = {
	'settings.wan': _('WAN device'),
	'settings.download_kbps': _('Download (line speed)'),
	'settings.upload_kbps': _('Upload (line speed)'),
	'settings.linklayer': _('Link layer'),
	'settings.overhead': _('Overhead'),
	'settings.qdisc': _('Queue'),
	'hfsc.default_qdisc': _('Leaf queue (HFSC / HTB)'),
	'settings.nft_mode': _('Rule set'),
	'settings.download_on': _('Download shaped on'),
	'settings.lan': _('LAN device'),
	'settings.live_refresh': _('Live pages refresh'),
	'pingfilter.lite': _('Ping Filter Lite'),
	'pingfilter.max_servers': _('Servers kept'),
	'pingfilter.persist_interval': _('Save the server list'),
	'network.packet_steering': _('Packet steering')
};
// The rows by what they set up; a key no group names goes last.
var AS_GROUPS = [
	[ _('Line'), [ 'settings.wan', 'settings.download_kbps', 'settings.upload_kbps', 'settings.linklayer', 'settings.overhead' ] ],
	[ _('Queue and rules'), [ 'settings.qdisc', 'hfsc.default_qdisc', 'settings.nft_mode', 'settings.download_on', 'settings.lan' ] ],
	[ _('This router'), [ 'settings.live_refresh' ] ],
	[ _('Ping Filter, if you use it'), [ 'pingfilter.lite', 'pingfilter.max_servers', 'pingfilter.persist_interval' ] ]
];
var AS_LIMIT = { line: _('the line'), port: _('the WAN port'), router: _('the router\'s CPU') };
var TIER = { low: _('low-spec'), mid: _('mid-range'), high: _('high-end') };
// The names consoles give the network (DHCP): set to Gaming when no gaming
// device is set yet. A guess the user sees before Apply.
var CONSOLE = /(^|[^a-z0-9])(ps[345]|playstation|xbox|nintendo|steam-?deck)/i;
var MAC = /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/;

function mbit(kbps) { return h.fmtMbps(kbps) + ' Mbit'; }
function steerName(v) {
	return v === '0' ? _('off') : v === '2' ? _('on, all CPUs') : v === '1' ? _('on') : _('default (on)');
}
// A setting's value as Setup shows it.
function shown(key, v) {
	if (v == null || v === '') return key === AS_STEER ? steerName('') : '—';
	switch (key) {
	case 'settings.download_kbps':
	case 'settings.upload_kbps': return v === '0' ? _('not shaped') : mbit(v);
	case 'settings.qdisc': return h.qdiscDisplay(v);
	case 'settings.nft_mode': return h.nftModeDisplay(v);
	case 'settings.overhead': return v + ' ' + _('bytes');
	case 'settings.download_on': return v === 'lan' ? _('the LAN device') : _('the IFB off the WAN');
	case 'settings.live_refresh': return _('every %s s').format(v);
	case 'pingfilter.persist_interval': return _('every %s h').format(+(v / 3600).toFixed(1));
	case 'pingfilter.lite': return v === '1' ? _('on') : _('off');
	case AS_STEER: return steerName(v);
	}
	return v;
}
// MB as the router reports it: "512 MB", "7.7 GB".
function size(mb) {
	mb = +mb || 0;
	return mb >= 1024 ? +(mb / 1024).toFixed(1) + ' GB' : mb + ' MB';
}
// The ping's rise under load over the idle ping, graded as line tests grade
// bufferbloat: A+ under 5 ms, A under 30, B 60, C 200, D 400, else F.
function bloat(r) {
	var i = +r.ping_idle, d = +r.ping_down, u = +r.ping_up;
	if (!(i > 0) || !(d > 0 || u > 0)) return null;
	var x = Math.max(0, d > 0 ? d - i : 0, u > 0 ? u - i : 0);
	return { grade: x < 5 ? 'A+' : x < 30 ? 'A' : x < 60 ? 'B' : x < 200 ? 'C' : x < 400 ? 'D' : 'F',
		band: x < 30 ? 'good' : x < 200 ? 'ok' : 'poor' };
}
// A test result as fresh as suggest takes it: under an hour old (now= is
// the router's uptime when the shim read the file, at= when it was written).
function age(r) { return +r.now - +r.at; }
function fresh(r) { return r.phase === 'done' && age(r) >= 0 && age(r) < 3600; }

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('qos-ex'),
			h.rpcSafe(h.callState()),
			h.rpcSafe(h.callAutosetup('result'))
		]);
	},

	render: function(loaded) {
		var view = this;
		// The banner gets one state now and does not poll: nothing competes
		// with the speed test for the router's CPU.
		var head = h.pageHead(_('Auto Setup'), 'none', { fed: true });
		h.barFeed(loaded[1]);
		view.running = h.running(h.parseState((loaded[1] && loaded[1].output) || '').state);
		view.res = asKv(loaded[2] && loaded[2].output);
		view.pr = {};
		view.sg = null;
		view.typed = null;
		view.pick = null;
		view.peak = 0;
		// Set up before on this config (Run Auto Setup): Manual setup is
		// "keep what is there".
		view.again = !!uci.get('qos-ex', 'autosetup', 'hw');

		// ---- The choice: Auto Setup, Manual setup, or a settings file. ----
		var mTitle = view.again ? _('Keep current settings') : _('Manual setup');
		view.manual = function() {
			return h.callAutosetupRun('skip', '').then(function(r) {
				if (!(r && r.ok)) throw new Error((r && r.error) || 'rc=' + ((r && r.rc) || '?'));
				h.menuGo(view.again ? [ 'overview' ] : [ 'setup', '#line' ]);
			}).catch(function(e) { h.notifyErr(_('Action failed') + ': ' + ((e && e.message) || e)); });
		};
		function choice(cls, title, text, fn) {
			return E('div', { 'class': 'qx-mode' + cls }, E('button', { 'type': 'button', 'class': 'qx-mode-hd',
				'click': ui.createHandlerFn(view, fn) }, [ E('b', {}, title), E('span', {}, text) ]));
		}
		view.intro = E('div', { 'class': 'cbi-section qos-ex-card qx-pfoff' }, [
			E('div', { 'class': 'qx-now-title' }, _('Set up QoS-Ex')),
			E('div', { 'class': 'qx-sub' }, _('Nothing changes until you apply or restore.')),
			E('div', { 'class': 'qx-as-pick' }, [
				choice(' qx-as-rec', _('Auto Setup'), _('Tests the line and suggests every setting for this router.'), function() {
					view.open();
					return view.runTest(true);
				}),
				choice('', mTitle, view.again ? _('Change nothing and close Auto Setup.')
					: _('Start from the defaults; set the line and devices on Setup.'), view.manual),
				choice('', _('Restore a settings file'), _('A QoS-Ex Settings.cfg saved from Maintenance.'), function() { h.cfgRestore(); })
			])
		]);

		// ---- Your router: what the check found. --------------------------
		view.rt = {};
		function rtile(id, label) {
			var t = view.rt[id] = { lab: E('div', { 'class': 'qx-label' }, label),
				big: E('div', { 'class': 'qx-big qx-mid' }, '…'), sub: E('div', { 'class': 'qx-sub' }) };
			return E('div', { 'class': 'qx-tile' }, [ t.lab, t.big, t.sub ]);
		}
		view.rtWarn = E('div');
		var router = E('div', { 'class': 'cbi-section qos-ex-card' }, [
			E('h3', { 'class': 'qos-ex-card-title' }, _('Your router')),
			E('div', { 'class': 'qx-tiles qx-as-tiles' }, [ rtile('dev', _('Router')), rtile('cpu', _('CPU')),
				rtile('mem', _('Memory')), rtile('wan', _('WAN')) ]),
			view.rtWarn ]);

		// ---- The steps: line speed, devices, settings. --------------------
		function step(n, title, kids) {
			var num = E('span', { 'class': 'qx-as-n' }, String(n));
			var card = E('div', { 'class': 'cbi-section qos-ex-card qx-as-step' },
				[ E('h3', { 'class': 'qos-ex-card-title' }, [ num, title ]) ].concat(kids));
			card.qxNum = num;
			return card;
		}
		// Download / Upload: the Overview's arc gauges, against the WAN port's
		// speed. Bufferbloat: the idle and the loaded ping, graded.
		function gtile(label) {
			var g = h.qxGauge();
			var t = { g: g, big: E('div', { 'class': 'qx-big' }, '—'), sub: E('div', { 'class': 'qx-sub' }) };
			t.el = E('div', { 'class': 'qx-tile qx-gtile' }, [ E('div', { 'class': 'qx-label' }, label),
				E('div', { 'class': 'qx-gauge-wrap' }, [ g.svg, t.big ]), t.sub ]);
			return t;
		}
		view.gd = gtile(_('Download'));
		view.gu = gtile(_('Upload'));
		view.bl = { grade: E('div', { 'class': 'qx-grade' }, '—'), big: E('div', { 'class': 'qx-as-bloat-t' }),
			sub: E('div', { 'class': 'qx-sub' }) };
		var bloatTile = E('div', { 'class': 'qx-tile qx-wide' }, [
			E('div', { 'class': 'qx-label' }, _('Bufferbloat, unshaped')),
			E('div', { 'class': 'qx-as-bloat' }, [ view.bl.grade, E('div', {}, [ view.bl.big, view.bl.sub ]) ]) ]);
		view.prog = { txt: E('span'), pct: E('strong'), bar: E('i') };
		view.progBox = E('div', { 'class': 'qx-as-prog', 'style': 'display:none' }, [
			E('div', { 'class': 'qx-as-prog-t' }, [ view.prog.txt, view.prog.pct ]),
			E('div', { 'class': 'qx-meter' }, view.prog.bar) ]);
		view.lineErr = E('div');
		function num(label) {
			return E('input', { 'type': 'number', 'min': '0', 'step': '0.1', 'class': 'cbi-input-text',
				'placeholder': _('Mbit'), 'aria-label': label });
		}
		view.inDn = num(_('Download, Mbit'));
		view.inUp = num(_('Upload, Mbit'));
		view.btnTest = E('button', { 'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(view, function() { return view.runTest(false); }) }, _('Run speed test'));
		view.btnUse = E('button', { 'class': 'btn cbi-button',
			'click': ui.createHandlerFn(view, function() { return view.useTyped(); }) }, _('Use these speeds'));
		view.s1 = step(1, _('Line speed'), [
			E('div', { 'class': 'qx-tiles qx-as-tiles' }, [ view.gd.el, view.gu.el, bloatTile ]),
			view.progBox, view.lineErr,
			E('div', { 'class': 'qx-as-line' }, [ view.btnTest, E('span', { 'class': 'qos-ex-muted' }, _('or type them:')),
				E('span', {}, [ '↓ ', view.inDn ]), E('span', {}, [ '↑ ', view.inUp ]), view.btnUse ]) ]);
		view.devBox = E('div', {}, E('p', { 'class': 'qos-ex-muted' }, _('Finding devices…')));
		view.nextBar = E('div', { 'class': 'qx-as-next' }, [
			E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': function() {
				view.devNext = true;
				view.paintSteps(true);
			} }, _('Next')),
			E('span', { 'class': 'qx-sub' }, _('Set your consoles and gaming PCs to Gaming, then Next.')) ]);
		view.s2 = step(2, _('Devices'), [
			E('div', { 'class': 'qx-sub qx-as-lead' }, _('Gaming gets the fastest queue; Low priority gives way to the rest.')),
			view.devBox, view.nextBar ]);
		view.sgBox = E('div', {}, E('p', { 'class': 'qos-ex-muted' }, _('Working out the settings…')));
		view.s3 = step(3, _('Settings to apply'), [ view.sgBox ]);
		function link(label, fn) {
			return E('a', { 'href': '#', 'click': function(ev) { ev.preventDefault(); fn(); } }, label);
		}
		view.steps = E('div', { 'style': 'display:none' }, [ view.s1, view.s2, view.s3,
			E('div', { 'class': 'qx-as-alt qos-ex-muted' }, [ _('Not now?') + ' ', link(mTitle, view.manual), ' · ',
				link(_('Restore a settings file…'), function() { h.cfgRestore(); }) ]) ]);

		// One backend run brings the router check and the suggestions; the
		// devices come from LuCI's host list.
		h.rpcSafe(h.callHostHints(), {}).then(function(hints) { view.paintDevices(hints); });
		view.refresh();
		// A test running (the page was reloaded): follow it. A fresh result:
		// the steps open on it.
		var ph = view.res.phase;
		if (ph && ph !== 'done' && ph !== 'error') { view.open(); view.follow(); }
		else if (fresh(view.res)) view.open();
		view.paintLine();
		return E([], [ head, view.intro, router, view.steps ]);
	},

	open: function() {
		this.intro.style.display = 'none';
		this.steps.style.display = '';
		this.paintSteps();
	},

	// One step at a time: the devices show once the line speed is known (a
	// fresh test, or speeds typed in), the settings once the devices are
	// done (Next). A step once shown stays, so an earlier one can still be
	// changed; scroll: the step that just appeared scrolls into view. The
	// numbers: done green (✓), the one to do now in the accent.
	paintSteps: function(scroll) {
		var view = this, was = view.reached || 0;
		var done = [ fresh(view.res) || !!view.typed, !!view.devNext, false ];
		view.reached = Math.max(was, done[0] ? (done[1] ? 2 : 1) : 0);
		var cards = [ view.s1, view.s2, view.s3 ], cur = done.indexOf(false);
		cards.forEach(function(c, i) {
			c.style.display = i <= view.reached ? '' : 'none';
			c.classList.toggle('cur', i === cur);
			c.qxNum.className = 'qx-as-n' + (done[i] ? ' done' : i === cur ? ' cur' : '');
			h.setText(c.qxNum, done[i] ? '✓' : String(i + 1));
		});
		view.nextBar.style.display = view.devNext ? 'none' : '';
		if (scroll && view.reached > was && cards[view.reached].scrollIntoView)
			cards[view.reached].scrollIntoView({ behavior: 'smooth', block: 'start' });
	},

	paintRouter: function() {
		var pr = this.pr, rt = this.rt;
		if (!pr.cores) return;
		h.setText(rt.dev.big, pr.model || pr.board || '?');
		rt.dev.big.title = pr.model || pr.board || '';
		h.setText(rt.dev.sub, [ pr.release ? 'OpenWrt ' + pr.release : '', pr.arch ].filter(Boolean).join(' · '));
		dom.content(rt.dev.lab, [ _('Router'), TIER[pr.tier]
			? E('span', { 'class': 'label pf-pill qx-as-tier qx-right' }, [ TIER[pr.tier] ]) : '' ]);
		h.setText(rt.cpu.big, pr.cores === '1' ? _('1 core') : _('%s cores').format(pr.cores));
		h.setText(rt.cpu.sub, [ +pr.mhz ? pr.mhz + ' MHz' : '', pr.biglittle === 'yes' ? 'big.LITTLE' : '' ]
			.filter(Boolean).join(' · '));
		h.setText(rt.mem.big, +pr.mem_mb ? size(pr.mem_mb) : '?');
		h.setText(rt.mem.sub, +pr.flash_mb ? _('flash: %s free of %s').format(size(pr.flash_free_mb), size(pr.flash_mb)) : '');
		// The port is named only when it is not the WAN device itself.
		var sp = +pr.wan_speed;
		h.setText(rt.wan.big, pr.wan || '?');
		dom.content(rt.wan.sub, [ [ pr.wan_proto, pr.wan_vlan === 'yes' ? 'VLAN' : '',
			pr.wan_port && pr.wan_port !== pr.wan ? _('on %s').format(pr.wan_port) : '', pr.wan_driver,
			sp ? (sp >= 1000 ? +(sp / 1000).toFixed(1) + ' Gbit' : sp + ' Mbit') : '',
			+pr.wan_rxq ? _('%s rx / %s tx queues').format(pr.wan_rxq, pr.wan_txq) : '' ].filter(Boolean).join(' · '),
			pr.dsl ? E('div', {}, [ (pr.dsl === 'atm' ? 'ADSL (ATM)' : 'VDSL (PTM)') + ' · ' +
				_('synced at ↓ %s ↑ %s').format(mbit(pr.dsl_down_kbps), mbit(pr.dsl_up_kbps)) ]) : '' ]);
		var other = (pr.foreign_shaper && pr.foreign_shaper !== 'no') ? pr.foreign_shaper : '';
		dom.content(this.rtWarn, [
			pr.kmods_missing ? E('div', { 'class': 'qos-ex-err' }, [ _('Kernel modules missing') + ': ' + pr.kmods_missing ]) : '',
			pr.pkgs_missing ? E('div', { 'class': 'qos-ex-err' }, [ _('Packages missing') + ': ' + pr.pkgs_missing ]) : '',
			other ? E('div', { 'class': 'qos-ex-err' }, [ _('Another shaper is on %s: %s').format(pr.wan, other) ]) : '' ]);
	},

	// The gauges and the bufferbloat tile: s = a running test's state;
	// else the speeds typed in, else the last result.
	paintLine: function(s) {
		var view = this, r = s || view.res, port = (+view.pr.wan_speed || 0) * 1000;
		var dn = 0, up = 0, tdn, tup;
		if (s) {
			if (r.phase === 'down') { dn = +r.now_kbps || 0; tdn = _('testing…'); tup = _('next'); }
			else if (r.phase === 'up') {
				dn = +r.down_kbps || 0; up = +r.now_kbps || 0;
				tdn = _('limit: %s').format(AS_LIMIT[r.limit_down] || '?'); tup = _('testing…');
			} else tdn = tup = _('starting…');
		} else if (view.typed) {
			dn = view.typed.d; up = view.typed.u; tdn = tup = _('typed in');
		} else if (r.phase === 'done') {
			dn = +r.down_kbps || 0; up = +r.up_kbps || 0;
			tdn = _('limit: %s').format(AS_LIMIT[r.limit_down] || '?');
			tup = _('limit: %s').format(AS_LIMIT[r.limit_up] || '?');
		} else tdn = tup = _('not tested yet');
		// Against the port's speed; without one, against the highest rate
		// seen, so the arcs still compare the two directions. Empty until the
		// router check says which (no jump when it lands).
		view.peak = Math.max(view.peak, dn, up);
		var scale = port || Math.max(view.peak * 1.1, 1000);
		[ [ view.gd, dn, tdn ], [ view.gu, up, tup ] ].forEach(function(x) {
			h.setText(x[0].big, x[1] ? mbit(x[1]) : '—');
			h.setText(x[0].sub, x[2]);
			x[0].g.set(view.pr.cores ? x[1] / scale : 0);
		});
		var res = view.res, b = !s && res.phase === 'done' ? bloat(res) : null;
		view.bl.grade.className = 'qx-grade' + (b ? ' ' + b.band : '');
		h.setText(view.bl.grade, b ? b.grade : '—');
		h.setText(view.bl.big, s ? _('Measuring…') : b ? _('%s ms idle').format(res.ping_idle) : _('Measured by the speed test'));
		var a = age(res);
		h.setText(view.bl.sub, b ? [ _('%s ms downloading').format(res.ping_down || '?'), _('%s ms uploading').format(res.ping_up || '?'),
			a >= 0 ? (a < 60 ? _('just now') : a < 3600 ? _('%d min ago').format(Math.round(a / 60)) : _('over an hour ago')) : '' ].filter(Boolean).join(' · ')
			: s ? '' : _('QoS-Ex keeps the ping low under load.'));
	},

	// One bar for the whole test: start (shaping stopped, idle ping) to
	// 10%, download to 55%, upload to 100%.
	paintProg: function(s) {
		var ph = s.phase, p = +s.progress || 0, pct, txt, P = this.prog;
		if (ph === 'down')    { pct = 10 + p * 0.45; txt = _('Testing download'); }
		else if (ph === 'up') { pct = 55 + p * 0.45; txt = _('Testing upload'); }
		else                  { pct = 3; txt = _('Starting: pausing shaping, measuring the idle ping…'); }
		pct = Math.min(100, Math.round(pct));
		h.setText(P.txt, txt);
		h.setText(P.pct, pct + '%');
		P.bar.style.width = pct + '%';
		this.paintLine(s);
	},

	busy: function(on) {
		this.btnTest.disabled = this.btnUse.disabled = !!on;
		this.progBox.style.display = on ? '' : 'none';
		if (on) { dom.content(this.lineErr, []); this.paintProg({}); }
	},

	// Follow the state file until the test ends. A test that never writes
	// one did not start (System -> Logs says why). One poll at a time, and
	// the end is handled once: a slow reply landing after the next poll
	// went out showed the error banner several times.
	follow: function() {
		var view = this, none = 0, wait = false;
		if (view.following) return;
		view.following = true;
		view.busy(true);
		var t = window.setInterval(function() {
			if (!document.body.contains(view.progBox)) { window.clearInterval(t); view.following = false; return; }
			if (wait || !view.following) return;
			wait = true;
			h.callAutosetup('result').then(function(r) {
				wait = false;
				if (!view.following) return;
				var s = asKv(r && r.output);
				if (!s.phase && ++none > 15) s = { phase: 'error', msg: _('the speed test did not start - see System → Logs') };
				if (s.phase !== 'done' && s.phase !== 'error') { if (s.phase) view.paintProg(s); return; }
				window.clearInterval(t);
				view.following = false;
				if (s.phase === 'done') {
					// The bar ends at 100% for 2 s before the results.
					h.setText(view.prog.txt, _('Complete'));
					h.setText(view.prog.pct, '100%');
					view.prog.bar.style.width = '100%';
					window.setTimeout(function() {
						view.busy(false);
						view.res = s;
						view.typed = null;
						view.paintLine();
						view.paintSteps(true);
						view.refresh();
					}, 2000);
					return;
				}
				// The reason stays in the card, beside the boxes to type the
				// speeds in.
				view.busy(false);
				view.res = s;
				view.paintLine();
				dom.content(view.lineErr, E('div', { 'class': 'qos-ex-err qx-as-err' },
					[ _('Speed test') + ': ' + (s.msg || _('failed')) ]));
				view.inDn.focus();
			}).catch(function() { wait = false; });
		}, 1000);
	},

	// noAsk: started from the Auto Setup choice, which says what it does.
	runTest: function(noAsk) {
		var view = this;
		var secs = +uci.get('qos-ex', 'autosetup', 'test_secs') || 10;
		var mb = +uci.get('qos-ex', 'autosetup', 'test_mb') || 1500;
		if (!noAsk && !confirm(_('Run a speed test now?') + '\n\n' +
			_('About %d s, up to %d MB each way. Shaping pauses while it runs.').format(2 * secs + 10, mb))) return;
		return h.callAutosetupRun('speedtest', '').then(function(r) {
			if (!(r && r.ok)) throw new Error((r && r.error) || '?');
			view.follow();
		}).catch(function(e) {
			h.notifyErr(_('Speed test') + ': ' + ((e && e.message) || e));
		});
	},

	useTyped: function() {
		var d = parseFloat(this.inDn.value), u = parseFloat(this.inUp.value);
		if (!(d >= 0) || !(u >= 0) || (d === 0 && u === 0)) {
			h.notifyErr(_('Type the download and upload speed in Mbit (0 = not shaped)'));
			return;
		}
		this.typed = { d: Math.round(d * 1000), u: Math.round(u * 1000) };
		dom.content(this.lineErr, []);
		this.paintLine();
		this.paintSteps(true);
		return this.refresh();
	},

	// New suggestions, with the router check: from the speed test or the DSL
	// line, or from the speeds typed in (kbps). An older shaper answers
	// without the check: then it is asked for on its own.
	refresh: function() {
		var view = this, t = view.typed;
		return h.rpcSafe(h.callAutosetupRun('suggest', '', t ? String(t.d) : '', t ? String(t.u) : '')).then(function(r) {
			if (r._err) {
				dom.content(view.sgBox, E('p', { 'class': 'qos-ex-muted' }, [ _('No suggestions') + ': ' + r._err ]));
				return;
			}
			var kv = asKv(r.output);
			view.sg = asSuggestions(r.output);
			return (kv.cores ? Promise.resolve(kv) : h.rpcSafe(h.callAutosetup('probe')).then(function(p) {
				return asKv(p.output);
			})).then(function(pr) {
				view.pr = pr;
				view.paintRouter();
				view.paintLine();
				view.paintSugg();
				view.paintSteps();
			});
		});
	},

	// Gaming and low-priority devices for apply: dev= / low= words, an empty
	// one for an empty list. None until the device list is up.
	extra: function() {
		var p = this.pick;
		if (!p) return '';
		var g = [], l = [];
		Object.keys(p).forEach(function(m) {
			if (p[m] === 'gaming') g.push('dev=' + m);
			else if (p[m] === 'lowprio') l.push('low=' + m);
		});
		return (g.length ? g : [ 'dev=' ]).concat(l.length ? l : [ 'low=' ]).join(' ');
	},

	// Apply (or Finish) completes the setup: the shaper is then turned on and
	// the bar waits until it runs; 100% Complete, then after(). Packet
	// steering alone is not the setup.
	act: function(keys, what, after) {
		var view = this, setup = keys !== 'steering';
		if (view.applyErr) h.setText(view.applyErr, '');
		return h.progressRun(what, [
			[ _('Saving the settings'), setup ? 50 : 90, function() {
				return h.callAutosetupRun('apply', keys).then(function(r) {
					if (!(r && r.ok)) throw new Error((r && r.error) || 'rc=' + ((r && r.rc) || '?'));
				});
			} ] ].concat(setup ? [ [ _('Starting the shaper'), 95, function() {
				var on = uci.get('qos-ex', 'settings', 'enabled') === '1';
				return (on ? Promise.resolve({ ok: true }) : h.callAction('enable')).then(function(e) {
					if (!(e && e.ok)) throw new Error(_('could not start — check the WAN and speeds on Setup'));
					return h.waitShaper();
				});
			} ] ] : []),
			after
		).catch(function(e) {
			var msg = what + ': ' + _('failed') + ' (' + ((e && e.message) || e) + ')';
			h.notifyErr(msg);
			// Beside the button as well: the page's notice is out of sight here.
			if (view.applyErr) h.setText(view.applyErr, msg);
		});
	},

	// The suggestions, grouped: a change has a tick box (a click anywhere on
	// its row ticks it); the settings that stay, with why, are folded.
	paintSugg: function() {
		var view = this, sg = view.sg;
		if (!sg) return;
		var main = sg.set.filter(function(s) { return s.key !== AS_STEER; });
		var steer = sg.set.filter(function(s) { return s.key === AS_STEER; })[0];
		var boxes = [], kids = [];
		function row(s) {
			var cb = '';
			if (!s.keep) {
				cb = E('input', { 'type': 'checkbox', 'checked': '', 'aria-label': AS_NAMES[s.key] || s.key });
				cb.qosExKey = s.key;
				boxes.push(cb);
			}
			var el = E('div', { 'class': 'qx-as-set' + (s.keep ? ' keep' : '') }, [
				E('span', {}, [ cb ]),
				E('span', { 'class': 'qx-as-what' }, [ E('b', {}, [ AS_NAMES[s.key] || s.key ]), E('span', { 'class': 'qx-sub' }, [ s.why ]) ]),
				E('span', { 'class': 'qx-as-val' }, s.keep ? [ shown(s.key, s.val) ] : [
					E('span', { 'class': 'qos-ex-muted' }, [ shown(s.key, s.cur) ]), ' → ', E('strong', {}, [ shown(s.key, s.val) ]) ]) ]);
			if (cb) el.addEventListener('click', function(ev) { if (ev.target !== cb) cb.checked = !cb.checked; });
			return el;
		}
		var named = {};
		AS_GROUPS.forEach(function(g) {
			g[1].forEach(function(k) { named[k] = true; });
			var rows = main.filter(function(s) { return g[1].indexOf(s.key) >= 0; });
			if (rows.length) kids.push(E('div', { 'class': 'qx-label qx-as-grp' }, g[0]),
				E('div', { 'class': 'qx-as-sets' }, rows.map(row)));
		});
		var rest = main.filter(function(s) { return !named[s.key]; });
		if (rest.length) kids.push(E('div', { 'class': 'qx-as-sets' }, rest.map(row)));
		if (!main.length) kids.push(E('p', { 'class': 'qos-ex-muted' }, _('Nothing needs to change.')));
		if (sg.keep.length)
			kids.push(E('details', { 'class': 'qx-as-keep' }, [ E('summary', {}, _('Settings that stay (%d)').format(sg.keep.length)),
				E('div', { 'class': 'qx-as-sets' }, sg.keep.map(row)) ]));
		// Packet steering is a network setting: applied on its own.
		if (steer) kids.push(E('div', { 'class': 'qx-as-steer' }, [
			E('span', {}, [ _('Packet steering') + ': ' + shown(AS_STEER, steer.cur) + ' → ' + shown(AS_STEER, steer.val) + ' (' + steer.why + ')' ]),
			E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(view, function() {
				if (!confirm(_('Turn packet steering on? No network restart is needed.'))) return;
				return view.act('steering', _('Packet steering'), function() { ui.hideModal(); view.refresh(); });
			}) }, _('Turn on')) ]));
		if (sg.note.length)
			kids.push(E('ul', { 'class': 'qos-ex-muted qx-as-notes' }, sg.note.map(function(n) { return E('li', {}, [ n ]); })));
		// Nothing to change still completes the setup (and turns the shaper on).
		var label = main.length ? (view.running ? _('Apply') : _('Apply and start'))
			: (view.running ? _('Finish') : _('Finish and start'));
		view.applyErr = E('div', { 'class': 'qos-ex-err qx-as-err' });
		kids.push(E('div', { 'class': 'qx-as-apply' }, [
			E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(view, function() {
				var keys = boxes.filter(function(b) { return b.checked; }).map(function(b) { return b.qosExKey; });
				var x = view.extra();
				return view.act((keys.length ? keys.join(' ') : 'none') + (x ? ' ' + x : ''), _('Auto Setup'),
					function() { h.menuGo([ 'overview' ]); });
			}) }, label),
			E('span', { 'class': 'qx-sub' }, _('Undo it any time: System → Maintenance.')) ]), view.applyErr);
		dom.content(view.sgBox, kids);
	},

	// The devices LuCI knows (DHCP leases, neighbours) and the ones already
	// set, one row each: Normal, Gaming or Low priority (Setup's table).
	// With no gaming device set yet, consoles are set to Gaming by name.
	paintDevices: function(hints) {
		var view = this, devs = {}, pick = {}, guess = [];
		function saved(opt) {
			return L.toArray(uci.get('qos-ex', 'ips', opt)).map(function(v) { return String(v || '').trim().toLowerCase(); })
				.filter(function(v) { return MAC.test(v); });
		}
		Object.keys(hints || {}).forEach(function(k) {
			var x = hints[k] || {}, m = String(k).toLowerCase();
			var a = [].concat(x.ipaddrs || x.ipv4 || [], x.ip6addrs || x.ipv6 || []);
			if (MAC.test(m) && (x.name || a[0])) devs[m] = { name: x.name || '', ip: a[0] || '' };
		});
		saved('gaming_mac').forEach(function(m) { pick[m] = 'gaming'; });
		saved('lowprio_mac').forEach(function(m) { if (!pick[m]) pick[m] = 'lowprio'; });
		Object.keys(pick).forEach(function(m) { if (!devs[m]) devs[m] = { name: '', ip: '', off: true }; });
		var anyGaming = [ 'gaming_mac', 'gaming_ipv4', 'gaming_ipv6' ].some(function(o) {
			return L.toArray(uci.get('qos-ex', 'ips', o)).some(function(v) { return String(v || '').trim(); });
		});
		if (!anyGaming) Object.keys(devs).forEach(function(m) {
			if (!pick[m] && CONSOLE.test(devs[m].name)) { pick[m] = 'gaming'; guess.push(devs[m].name); }
		});
		view.pick = pick;
		var keys = Object.keys(devs);
		if (!keys.length) {
			dom.content(view.devBox, E('p', { 'class': 'qos-ex-muted' }, _('No devices found: set them later on Setup → Devices & Ports.')));
			view.paintSteps();
			return;
		}
		var CH = [ [ '', _('Normal') ], [ 'gaming', _('Gaming') ], [ 'lowprio', _('Low priority') ] ];
		var rows = E('div', { 'class': 'qos-ex-dev-rows' }), rowOf = {};
		var sum = E('span', { 'class': 'qos-ex-muted' });
		var q = E('input', { 'type': 'search', 'class': 'cbi-input-text qos-ex-dev-q',
			'placeholder': _('Filter by name, IP or MAC'), 'aria-label': _('Filter devices') });
		function count() {
			var n = { gaming: 0, lowprio: 0 };
			keys.forEach(function(m) { if (pick[m]) n[pick[m]]++; });
			h.setText(sum, _('%d gaming · %d low priority').format(n.gaming, n.lowprio));
		}
		function paint(seg, cls) {
			seg.querySelectorAll('button').forEach(function(b) {
				var on = b.getAttribute('data-v') === cls;
				b.classList.toggle('sel', on);
				b.setAttribute('aria-pressed', on ? 'true' : 'false');
			});
		}
		function row(m) {
			var d = devs[m], name = d.name || d.ip || m;
			var sub = [ d.off ? _('not on the network now') : (d.name ? d.ip : ''), name === m ? '' : m ].filter(Boolean).join(' · ');
			var seg = E('span', { 'class': 'qos-ex-seg', 'role': 'group', 'aria-label': name }, CH.map(function(c) {
				return E('button', { 'type': 'button', 'class': 'btn cbi-button', 'data-v': c[0], 'click': function() {
					pick[m] = c[0]; paint(seg, c[0]); count(); view.paintSteps();
				} }, c[1]);
			}));
			paint(seg, pick[m] || '');
			return rowOf[m] = E('div', { 'class': 'qos-ex-dev-row', 'data-q': [ d.name, d.ip, m ].join(' ').toLowerCase() }, [
				E('div', { 'class': 'qos-ex-dev-id' }, [
					E('div', { 'class': 'qos-ex-dev-name' }, [ name ]),
					E('div', { 'class': 'qos-ex-dev-sub qos-ex-muted' }, [ sub || ' ' ]) ]),
				seg ]);
		}
		// Gaming first, then Low priority, then by name and address.
		var rank = { gaming: 0, lowprio: 1 };
		keys.sort(function(a, b) {
			var x = rank[pick[a]] != null ? rank[pick[a]] : 2, y = rank[pick[b]] != null ? rank[pick[b]] : 2;
			return (x - y) || (devs[a].name || '￿').localeCompare(devs[b].name || '￿') ||
				(devs[a].ip || '').localeCompare(devs[b].ip || '', undefined, { numeric: true }) ||
				a.localeCompare(b, undefined, { numeric: true });
		}).forEach(function(m) { rows.appendChild(row(m)); });
		q.addEventListener('input', function() {
			var t = q.value.trim().toLowerCase();
			keys.forEach(function(m) { rowOf[m].hidden = !!t && rowOf[m].getAttribute('data-q').indexOf(t) < 0; });
		});
		count();
		dom.content(view.devBox, [
			E('div', { 'class': 'qos-ex-dev' }, [ E('div', { 'class': 'qos-ex-dev-bar' }, [ q, sum ]), rows ]),
			guess.length ? E('div', { 'class': 'qx-as-guess' }, [ _('Set to Gaming from their names: %s. Check them before you apply.').format(guess.join(', ')) ]) : '',
			E('div', { 'class': 'qx-sub qx-as-lead' }, _('Not listed? Add it on Setup → Devices & Ports after.')) ]);
		view.paintSteps();
	},

	handleSave:      null,
	handleSaveApply: null,
	handleReset:     null
});
