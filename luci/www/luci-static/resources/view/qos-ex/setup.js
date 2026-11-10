'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require poll';
'require dom';
'require ui';
'require view.qos-ex._helpers as h';

// Setup: everything that is set once and saved -- the line, the devices
// and ports, the queue and the classifier rules -- on one page with four
// tabs (Line, Devices & Ports, Queue, Rules) and one Save. Each part is built by
// its own function below; both write onto the one .qos-ex-scope wrapper,
// whose data-qdisc / data-mss / data-nft attributes pick the fields
// qos-ex.css shows (depends() would delete hidden values on save).

// The line and the queue. loaded = [ , /sys/class/net list, status reply ].
function buildShaper(view, scope, loaded) {
	var ifaces = (loaded[1] || []).map(function(e) { return e.name; })
		.filter(function(n) { return n && n !== 'lo'; })
		.sort();
	var wanLive = (/^wan_live=(\S+)/m.exec((loaded[2] && loaded[2].output) || '') || [])[1] || '';
	var lanLive = (/^lan_live=(\S+)/m.exec((loaded[2] && loaded[2].output) || '') || [])[1] || '';

	// Two maps, one per page tab (Line, Queue); Save walks every map on the page.
	var mLine = new form.Map('qos-ex', '', ''), mQueue = new form.Map('qos-ex', '', '');
	var cur = mLine, s, o;

	// Which fields show is decided by data-qdisc on this wrapper and a few
	// rules in qos-ex.css, not by depends(): a field depends() hides is
	// DELETED from UCI on save, and switching the queue type must not
	// throw the other one's tuning away. The wrapper also outlives the
	// re-render LuCI does after Save.
	scope.setAttribute('data-qdisc', h.qdiscCfg());
	scope.setAttribute('data-mss', mssState());
	view.qosExRefresh = function() { refresh(); };

	function sec(name, type, title) {
		var x = cur.section(form.NamedSection, name, type, title);
		x.anonymous = true; x.addremove = false;
		return x;
	}

	// Live (unsaved) widget value, or null when the widget is not built.
	function live(opt, sid) {
		try {
			var u = opt && opt.getUIElement && opt.getUIElement(sid);
			if (u) {
				var v = u.getValue();
				if (v !== '' && v != null) return String(v);
			}
		} catch (e) { /* not rendered yet -- caller falls back to UCI */ }
		return null;
	}
	function txt(opt, sid, key, def, usec) {
		var v = live(opt, sid);
		if (v == null) v = uci.get('qos-ex', usec || sid, key);
		return (v == null || v === '') ? def : String(v);
	}

	var oDn, oUp, oHr, oOh, oQd, oAck, oRatio, oRatioN,
	    oPct, oFloor, oBurst, oGameQ, oPfMin, oPkt, oMaxDly, oBfMin, oDefQ;

	// The queue type on the page, saved or not: what the stylesheet and
	// the rate maths key on.
	function qdiscNow() { return txt(oQd, 'settings', 'qdisc', 'cake'); }

	// Shaped rates from everything on this page, saved or not.
	function rates() {
		function kb(opt) {
			var v = parseFloat(live(opt, 'settings'));
			return (isFinite(v) && v >= 0) ? String(Math.round(v * 1000)) : null;
		}
		var rsel = live(oRatio, 'settings');
		return h.shapedRates({
			upload_kbps:   kb(oUp),
			download_kbps: kb(oDn),
			bw_headroom:   live(oHr, 'settings'),
			overhead:      live(oOh, 'settings'),
			qdisc:         qdiscNow(),
			ack_filter:    live(oAck, 'settings'),
			bw_max_ratio:  (rsel === 'on') ? live(oRatioN, 'settings') : rsel
		});
	}

	// MSS gate field shows only while the clamp is active: a direction
	// (after headroom, before the ratio cap, as calc_mss) below the SAVED
	// gate. The typed gate is not read, or the field would hide mid-edit.
	function mssState() {
		var r = rates(), g = parseInt(uci.get('qos-ex', 'settings', 'mss_max_kbps'), 10);
		if (isNaN(g)) g = 3000;
		var dn = Math.floor(r.lineDn * r.headroom / 100);
		// 0 = that direction is not shaped, so never clamped.
		return ((r.up > 0 && r.up < g) || (dn > 0 && dn < g)) ? 'active' : 'inactive';
	}

	// Deferred, because a widget commits its value after its change handler.
	function refresh() {
		window.setTimeout(function() {
			scope.setAttribute('data-qdisc', qdiscNow());
			scope.setAttribute('data-mss', mssState());
		}, 0);
	}
	function watch(opt) { opt.onchange = refresh; return opt; }

	// sfq's divisor must be a power of two up to 65536; from 16, as the
	// backend holds it (a divisor of 1 left sfq a 1-packet limit).
	function validPow2(section_id, value) {
		if (value === '' || value == null) return true;
		var n = /^[0-9]+$/.test(String(value)) ? parseInt(value, 10) : 0;
		if (!(n >= 16) || n > 65536)
			return _('Enter a power of two between 16 and 65536.');
		if ((n & (n - 1)) !== 0)
			return _('Must be a power of two: 256, 512, 1024, 2048, ...');
		return true;
	}

	// ============================ Line ============================
	// The connection: device, speeds and what each packet costs on the wire.
	s = sec('settings', 'global', _('Link'));

	// The note shows the device the line is on now (the default route's);
	// the list holds plain device names.
	o = s.option(form.Value, 'wan', _('WAN interface'), wanLive
		? _('The device your internet line is on: %s.').format('<code>' + h.escHtml(wanLive) + '</code>')
		: _('The device your internet line is on.'));
	ifaces.forEach(function(i) { o.value(i); });
	o.default = wanLive || 'eth0';
	// Required: a cleared field deleted settings.wan, and the backend then
	// shaped its eth0 fallback while this page showed the live line.
	o.rmempty = false;
	// The rule load_config enforces at start.
	o.validate = function(section_id, value) {
		if (!value) return _('Pick the WAN device');
		return /^[A-Za-z0-9._-]{1,15}$/.test(value) ? true
			: _('1-15 characters: letters, digits, dot, underscore, dash');
	};

	// Entered in Mbps, stored in kbps under the original keys.
	var vBase = form.Value.prototype.cfgvalue;
	function mbps(key, title, descr, defMbps) {
		var opt = s.option(form.Value, key, title, descr);
		opt.datatype = 'ufloat';
		opt.default = defMbps;
		opt.placeholder = defMbps;
		// cfgvalue with two arguments is a setter and passes straight
		// through; only the read path converts.
		opt.cfgvalue = function(sid) {
			if (arguments.length > 1) return vBase.apply(this, arguments);
			var kb = parseFloat(vBase.call(this, sid));
			if (!isFinite(kb) || kb < 0) return null;
			return String(parseFloat((kb / 1000).toFixed(3)));
		};
		// 0 is kept: it leaves that direction unshaped.
		opt.write = function(sid, val) {
			var mb = parseFloat(val);
			if (!isFinite(mb) || mb < 0) return uci.unset('qos-ex', sid, key);
			return uci.set('qos-ex', sid, key, String(Math.round(mb * 1000)));
		};
		return watch(opt);
	}
	oDn = mbps('download_kbps', _('Download rate (Mbps)'),
		_('Your measured download speed. 0 = not shaped.'), '100');
	oUp = mbps('upload_kbps', _('Upload rate (Mbps)'),
		_('Your measured upload speed. 0 = not shaped.'), '100');

	oHr = watch(s.option(form.ListValue, 'bw_headroom', _('Headroom'),
		_('Shape a little under the line, so the queue stays here.')));
	oHr.value('100', _('100% — off'));
	[ '95', '90', '85', '80', '75', '70' ].forEach(function(p) { oHr.value(p, p + '%'); });
	// 90 matches the backend default.
	oHr.default = '90';
	oHr.rmempty = false;
	// A CLI value outside the presets gets its own entry instead of
	// rendering blank and being rewritten on save.
	var hrNow = String(uci.get('qos-ex', 'settings', 'bw_headroom') || '90');
	if (/^[0-9]+$/.test(hrNow) && !/^(100|95|90|85|80|75|70)$/.test(hrNow) &&
	    parseInt(hrNow, 10) >= 50 && parseInt(hrNow, 10) <= 100)
		oHr.value(hrNow, hrNow + '%');

	o = s.option(form.ListValue, 'linklayer', _('Link layer'),
		_('ATM for ADSL (53-byte cells); Ethernet for everything else.'));
	o.value('ethernet', _('Ethernet, VDSL, cable, fibre (default)'));
	o.value('atm',      _('ATM (ADSL)'));
	o.default = 'ethernet';
	o.rmempty = false;

	oOh = watch(s.option(form.Value, 'overhead', _('Overhead (bytes)'),
		_('Bytes each packet adds on the wire. Ethernet 38, +8 PPPoE.')));
	// load_config's range: over 256 it shapes with 44.
	oOh.datatype = 'range(0,256)'; oOh.default = '44';
	oOh.rmempty = false;   // always persist, so Overview never shows '?'

	// Stored in the cake section, which is where every queue type reads it.
	o = s.option(form.Value, 'mpu', _('MPU (bytes)'),
		_('Smallest packet size charged. 84 on Ethernet.'));
	o.ucisection = 'cake';
	o.datatype = 'range(0,256)'; o.default = '84'; o.placeholder = '84';
	o.rmempty = false;

	// ============================ Queue ===========================
	cur = mQueue;
	s = sec('settings', 'global', _('Root qdisc'));

	oQd = watch(s.option(form.ListValue, 'qdisc', _('Root qdisc'),
		_('CAKE: least tuning. HFSC / HTB: a Gaming class served first.')));
	oQd.value('cake',     _('CAKE (default)'));
	oQd.value('hfsc',     _('HFSC'));
	oQd.value('htb',      _('HTB'));
	oQd.default = 'cake';
	oQd.rmempty = false;

	// The download qdisc: on an IFB off the WAN (every LAN device), or on
	// the LAN device as the traffic leaves (no IFB; that device only).
	o = s.option(form.ListValue, 'download_on', _('Download shaped on'),
		_('LAN device: cheaper, that one only, router→LAN shaped too.'));
	o.value('wan', _('IFB off the WAN (default)'));
	o.value('lan', _('LAN device, as traffic leaves'));
	o.default = 'wan';
	o.rmempty = false;

	// The note shows the lan interface's device, as the WAN one shows the
	// line; with none found, what an empty field does.
	o = s.option(form.Value, 'lan', _('LAN device'), lanLive
		? _('The device your LAN is on: %s.').format('<code>' + h.escHtml(lanLive) + '</code>')
		: _('The device your LAN is on. Empty = found at each start.'));
	ifaces.forEach(function(i) { if (i !== wanLive) o.value(i); });
	// Found like the WAN: the lan interface's device (an older shaper
	// reports none and the field stays empty, found at each start).
	o.default = lanLive;
	o.depends('download_on', 'lan');
	o.retain = true;
	o.validate = function(section_id, value) {
		if (!value) return true;
		return /^[A-Za-z0-9._-]{1,15}$/.test(value) ? true
			: _('1-15 characters: letters, digits, dot, underscore, dash');
	};

	// ============================ CAKE ============================
	s = sec('cake', 'cake', _('CAKE'));
	s.tab('gen', _('General'));
	s.tab('adv', _('Advanced'));

	o = s.taboption('gen', form.ListValue, 'priority', _('Diffserv mode'),
		_('CAKE tin layout. diffserv4 = Bulk, Best Effort, Video, Voice.'));
	[ 'diffserv4', 'diffserv3', 'diffserv8', 'precedence', 'besteffort' ].forEach(function(v) { o.value(v); });
	o.default = 'diffserv4';
	o.rmempty = false;

	o = s.taboption('gen', form.Flag, 'host_isolation', _('Host isolation'),
		_('Fair share per LAN device. Off: triple-isolate.'));
	o.enabled = 'yes'; o.disabled = 'no'; o.default = 'yes'; o.rmempty = false;

	o = s.taboption('gen', form.Flag, 'ingress_mode', _('Ingress mode'),
		_('Download: dropped packets count against the rate.'));
	o.enabled = 'yes'; o.disabled = 'no'; o.default = 'yes'; o.rmempty = false;

	o = s.taboption('gen', form.Value, 'rtt', _('RTT'),
		_('How fast CAKE reacts. 100ms suits most lines.'));
	o.placeholder = '100ms'; o.default = '100ms';
	// Same shape load_config checks: a number, then ms, us or s.
	o.validate = function(section_id, value) {
		return (!value || /^[0-9]+(\.[0-9]+)?(ms|us|s)$/.test(value)) ? true
			: _('A time such as 100ms, 50ms or 1s');
	};

	o = s.taboption('adv', form.Flag, 'nat_ingress', _('NAT lookup, ingress'),
		_('Find each LAN device behind NAT on download (IFB only).'));
	o.enabled = 'yes'; o.disabled = 'no'; o.default = 'yes'; o.rmempty = false;

	o = s.taboption('adv', form.Flag, 'nat_egress', _('NAT lookup, egress'),
		_('Find each LAN device behind NAT on upload.'));
	o.enabled = 'yes'; o.disabled = 'no'; o.default = 'yes'; o.rmempty = false;

	o = s.taboption('adv', form.Value, 'extra_ingress', _('Extra CAKE args, ingress'),
		_('Added as is to the download CAKE, e.g. docsis.'));

	o = s.taboption('adv', form.Value, 'extra_egress', _('Extra CAKE args, egress'),
		_('Added as is to the upload CAKE.'));

	// ====================== Gaming class 1:10 =====================
	s = sec('hfsc', 'hfsc', _('Gaming class — 1:10'));
	s.tab('gen', _('General'));
	s.tab('adv', _('Advanced'));

	oPct = s.taboption('gen', form.Value, 'game_pct', _('Gaming rate (%)'),
		_('This % of each direction plus the floor; at most 85%.'));
	oPct.datatype = 'range(5,50)'; oPct.default = '15'; oPct.placeholder = '15';
	oPct.rmempty = false;

	oFloor = s.taboption('gen', form.Value, 'game_floor', _('Gaming rate floor (kbit)'),
		_('Added to the gaming rate (Adaptive may raise it).'));
	oFloor.datatype = 'range(0,10000)'; oFloor.default = '400'; oFloor.placeholder = '400';
	oFloor.rmempty = false;

	oBurst = s.taboption('gen', form.Value, 'game_burst', _('RT burst (× rate)'),
		_('HFSC: a short burst of this × the gaming rate.'));
	oBurst.datatype = 'range(1,20)'; oBurst.default = '10'; oBurst.placeholder = '10';
	oBurst.rmempty = false;

	// Advanced: the leaf queue first, then its sizing and tuning.
	oGameQ = s.taboption('adv', form.ListValue, 'game_qdisc', _('Gaming leaf qdisc'),
		_('Queue inside the Gaming class. sfq gives each flow its turn.'));
	oGameQ.value('pfifo',    _('pfifo'));
	oGameQ.value('bfifo',    _('bfifo'));
	oGameQ.value('sfq',      _('sfq (default)'));
	oGameQ.value('fq_codel', _('fq_codel'));
	oGameQ.default = 'sfq';
	oGameQ.rmempty = false;

	oMaxDly = s.taboption('adv', form.Value, 'max_delay', _('Max delay (ms)'),
		_('Longest a game packet waits; sizes the queue.'));
	oMaxDly.datatype = 'range(0,1000)'; oMaxDly.default = '5';
	oMaxDly.depends('game_qdisc', 'pfifo');
	oMaxDly.depends('game_qdisc', 'bfifo');

	oPfMin = s.taboption('adv', form.Value, 'pfifo_min', _('pfifo limit floor (packets)'),
		_('Packets added to the computed limit.'));
	oPfMin.datatype = 'range(0,10000)'; oPfMin.default = '5';
	oPfMin.depends('game_qdisc', 'pfifo');

	oPkt = s.taboption('adv', form.Value, 'packet_size', _('Packet size (bytes)'),
		_('Typical game packet size; sizes the gaming queue.'));
	oPkt.datatype = 'range(64,9000)'; oPkt.default = '576';

	oBfMin = s.taboption('adv', form.Value, 'bfifo_min', _('bfifo limit floor (bytes)'),
		_('Smallest byte limit of the queue.'));
	oBfMin.datatype = 'range(1500,33554432)'; oBfMin.default = '3000';
	oBfMin.depends('game_qdisc', 'bfifo');

	o = s.taboption('adv', form.Value, 'sfq_perturb', _('sfq perturb (s)'),
		_('Seconds between hash reseeds. 0 = never.'));
	o.datatype = 'range(0,3600)'; o.default = '10';
	o.depends('game_qdisc', 'sfq');

	o = s.taboption('adv', form.Value, 'sfq_quantum', _('sfq quantum (bytes)'),
		_('Bytes a flow sends per turn.'));
	o.datatype = 'range(1,65535)'; o.default = '300';
	o.depends('game_qdisc', 'sfq');

	o = s.taboption('adv', form.Value, 'fq_limit', _('fq_codel limit (packets)'),
		_('Most packets the queue holds.'));
	o.datatype = 'range(16,1000000)'; o.default = '10240';
	o.depends('game_qdisc', 'fq_codel');

	o = s.taboption('adv', form.Value, 'fq_flows', _('fq_codel flows'),
		_('Flow buckets.'));
	o.datatype = 'range(1,65536)'; o.default = '1024';
	o.depends('game_qdisc', 'fq_codel');

	o = s.taboption('adv', form.Value, 'fq_quantum', _('fq_codel quantum (bytes)'),
		_('Bytes a flow sends per turn.'));
	o.datatype = 'range(1,1048576)'; o.default = '300';
	o.depends('game_qdisc', 'fq_codel');

	o = s.taboption('adv', form.Value, 'fq_target', _('fq_codel target (ms)'),
		_('Queue delay to aim for.'));
	o.datatype = 'range(1,10000)'; o.default = '5';
	o.depends('game_qdisc', 'fq_codel');

	o = s.taboption('adv', form.Value, 'fq_interval', _('fq_codel interval (ms)'),
		_('How long a delay may last before drops start.'));
	o.datatype = 'range(2,10000)'; o.default = '100';
	o.depends('game_qdisc', 'fq_codel');

	// A field depends() hides is deleted on save unless it is retained:
	// keep the tuning of the queue that is not selected right now.
	function keep(sect) {
		sect.children.forEach(function(c) { if (c.deps && c.deps.length) c.retain = true; });
	}
	keep(s);

	// ==================== Other classes 1:11-1:15 =================
	s = sec('hfsc', 'hfsc', _('Classes 1:11 to 1:15'));

	// HFSC only (qos-ex.css).
	o = s.option(form.Flag, 'voice_rt', _('Voice RT curve'),
		_('HFSC: Voice (1:11) also gets a small guaranteed rate.'));
	o.enabled = 'yes'; o.disabled = 'no'; o.default = 'yes'; o.rmempty = false;

	oDefQ = s.option(form.ListValue, 'default_qdisc', _('Leaf qdisc'),
		_('Queue inside classes 1:11 to 1:15. sfq: less CPU.'));
	oDefQ.value('fq_codel', _('fq_codel (default)'));
	oDefQ.value('sfq',      _('sfq'));
	oDefQ.default = 'fq_codel';
	oDefQ.rmempty = false;

	o = s.option(form.ListValue, 'def_tune_mode', _('Leaf tuning'),
		_('Auto sizes the class queues from your line speed.'));
	o.value('auto',   _('Auto (default)'));
	o.value('manual', _('Manual'));
	o.default = 'auto';
	o.rmempty = false;

	var FQM = { default_qdisc: 'fq_codel', def_tune_mode: 'manual' };
	var SFM = { default_qdisc: 'sfq',      def_tune_mode: 'manual' };

	o = s.option(form.Value, 'def_fq_limit', _('fq_codel limit (packets)'),
		_('Most packets the queue holds.'));
	o.datatype = 'range(16,1000000)'; o.default = '10240'; o.placeholder = '10240';
	o.depends(FQM);

	o = s.option(form.Value, 'def_fq_flows', _('fq_codel flows'),
		_('Flow buckets.'));
	o.datatype = 'range(2,65536)'; o.default = '1024'; o.placeholder = '1024';
	o.depends(FQM);

	o = s.option(form.Value, 'def_fq_quantum', _('fq_codel quantum (bytes)'),
		_('Bytes a flow sends per turn.'));
	o.datatype = 'range(256,65535)'; o.default = '1514'; o.placeholder = '1514';
	o.depends(FQM);

	o = s.option(form.Value, 'def_fq_target', _('fq_codel target (ms)'),
		_('Queue delay to aim for, below the interval.'));
	o.datatype = 'range(1,10000)'; o.default = '5'; o.placeholder = '5';
	o.depends(FQM);

	o = s.option(form.Value, 'def_fq_interval', _('fq_codel interval (ms)'),
		_('How long a delay may last before drops start.'));
	o.datatype = 'range(1,10000)'; o.default = '100'; o.placeholder = '100';
	o.depends(FQM);

	o = s.option(form.Value, 'def_fq_memory_mb', _('fq_codel memory_limit (MB)'),
		_('Memory cap of the queue, in MB.'));
	o.datatype = 'range(1,4095)'; o.default = '4'; o.placeholder = '4';
	o.depends(FQM);

	o = s.option(form.Flag, 'def_fq_ecn', _('fq_codel ECN'),
		_('Mark ECN-capable packets instead of dropping them.'));
	o.enabled = 'ecn'; o.disabled = 'noecn'; o.default = 'ecn'; o.rmempty = false;
	o.depends(FQM);

	o = s.option(form.Value, 'def_sfq_limit', _('sfq limit (packets)'),
		_('Most packets the queue holds.'));
	o.datatype = 'range(16,65535)'; o.default = '127'; o.placeholder = '127';
	o.depends(SFM);

	o = s.option(form.Value, 'def_sfq_depth', _('sfq depth (packets)'),
		_('Most packets one flow may queue, up to 127.'));
	o.datatype = 'range(1,127)'; o.default = '127'; o.placeholder = '127';
	o.depends(SFM);

	o = s.option(form.Value, 'def_sfq_divisor', _('sfq divisor'),
		_('Hash buckets, a power of two.'));
	o.default = '1024'; o.placeholder = '1024'; o.validate = validPow2;
	o.depends(SFM);

	o = s.option(form.Value, 'def_sfq_flows', _('sfq flows'),
		_('Most flows queued at once.'));
	o.datatype = 'range(1,65408)'; o.default = '127'; o.placeholder = '127';
	o.depends(SFM);

	o = s.option(form.Value, 'def_sfq_quantum', _('sfq quantum (bytes)'),
		_('Bytes a flow sends per turn.'));
	o.datatype = 'range(256,65535)'; o.default = '1514'; o.placeholder = '1514';
	o.depends(SFM);

	o = s.option(form.Value, 'def_sfq_perturb', _('sfq perturb (s)'),
		_('Seconds between hash reseeds. 0 = never.'));
	o.datatype = 'range(0,3600)'; o.default = '10'; o.placeholder = '10';
	o.depends(SFM);

	o = s.option(form.Flag, 'def_sfq_headdrop', _('sfq headdrop'),
		_('Drop the oldest packet, not the newest.'));
	o.enabled = 'yes'; o.disabled = 'no'; o.default = 'no'; o.rmempty = false;
	o.depends(SFM);

	keep(s);

	// ============================ Tweaks ==========================
	// Still the Queue tab: how the queues treat ACKs and TCP segment size.
	s = sec('settings', 'global', _('Tweaks'));

	oAck = watch(s.option(form.ListValue, 'ack_filter', _('ACK filter'),
		_('Thin upload ACKs. Auto: on when download > 14 × upload.')));
	oAck.value('auto', _('Auto (default)'));
	oAck.value('on',   _('On'));
	oAck.value('off',  _('Off'));
	oAck.default = 'auto';
	oAck.rmempty = false;

	// Download cap: select + number, both writing bw_max_ratio. The
	// select stores auto/off; 'on' defers to the number field.
	oRatio = watch(s.option(form.ListValue, 'bw_max_ratio', _('Download ratio cap'),
		_('HFSC / HTB: cap download at upload × ratio, for its ACKs.')));
	oRatio.value('auto', _('Auto (default)'));
	oRatio.value('on',   _('Fixed ratio'));
	oRatio.value('off',  _('Off (no cap)'));
	oRatio.default = 'auto';
	oRatio.rmempty = false;
	oRatio.cfgvalue = function(section_id) {
		var v = String(uci.get('qos-ex', section_id, 'bw_max_ratio') || 'auto').toLowerCase();
		if (v === 'auto') return 'auto';
		if (v === '' || v === '0' || v === 'off') return 'off';
		return 'on';
	};
	oRatio.write = function(section_id, value) {
		if (value === 'on') return;   // the number field writes it
		return uci.set('qos-ex', section_id, 'bw_max_ratio', value === 'off' ? 'off' : 'auto');
	};
	oRatio.remove = function() {};

	oRatioN = watch(s.option(form.Value, 'bw_max_ratio_n', _('Ratio (1–99)'),
		_('Download capped at upload × this.')));
	oRatioN.depends('bw_max_ratio', 'on');
	oRatioN.datatype = 'range(1,99)';
	oRatioN.placeholder = '20';
	oRatioN.rmempty = false;
	oRatioN.cfgvalue = function(section_id) {
		var v = String(uci.get('qos-ex', section_id, 'bw_max_ratio') || '');
		return (/^[0-9]+$/.test(v) && v !== '0') ? v : '';
	};
	oRatioN.write = function(section_id, value) {
		return uci.set('qos-ex', section_id, 'bw_max_ratio', String(value));
	};
	oRatioN.remove = function() {};

	// MSS clamp: same select + number shape, both writing `mss`.
	o = s.option(form.ListValue, 'mss', _('TCP MSS clamp'),
		_('Smaller TCP packets on a slow line, so games wait less.'));
	o.value('auto', _('Auto (default)'));
	o.value('off',  _('Off'));
	o.value('on',   _('Fixed MSS'));
	o.default = 'auto';
	o.rmempty = false;
	o.cfgvalue = function(section_id) {
		var v = String(uci.get('qos-ex', section_id, 'mss') || 'auto').toLowerCase();
		if (v === 'auto') return 'auto';
		if (v === '' || v === '0' || v === 'off' || v === 'no') return 'off';
		return 'on';
	};
	o.write = function(section_id, value) {
		if (value === 'on') return;   // the number field writes it
		return uci.set('qos-ex', section_id, 'mss', value === 'auto' ? 'auto' : 'off');
	};
	o.remove = function() {};

	o = s.option(form.Value, 'mss_n', _('MSS (536–1460 bytes)'),
		_('Fixed MSS to clamp to.'));
	o.depends('mss', 'on');
	o.datatype = 'range(536,1460)';
	o.placeholder = '536';
	o.rmempty = false;
	o.cfgvalue = function(section_id) {
		var v = String(uci.get('qos-ex', section_id, 'mss') || '');
		return (/^[0-9]+$/.test(v) && v !== '0') ? v : '';
	};
	o.write = function(section_id, value) {
		return uci.set('qos-ex', section_id, 'mss', String(value));
	};
	o.remove = function() {};

	o = s.option(form.Value, 'mss_max_kbps', _('MSS gate (kbps)'),
		_('Only a direction shaped below this is clamped. 0 = never.'));
	o.depends('mss', 'auto');
	o.depends('mss', 'on');
	o.datatype = 'uinteger';
	o.default = '3000';
	o.placeholder = '3000';
	o.rmempty = false;

	return [ mLine, mQueue ];
}

// Devices, ports and the classifier. loaded = [ , ruleset reply, host hints ].
function buildRules(view, scope, loaded) {
	var active = uci.get('qos-ex', 'settings', 'nft_mode') || 'adaptive';
	var hints = (loaded && loaded[2]) || {};
	// Two maps, one per page tab (Devices & Ports, Rules); Save walks every map on the page.
	var mDev = new form.Map('qos-ex', '', ''), mCls = new form.Map('qos-ex', '', '');
	var cur = mDev, s, o;

	// Simple and Advanced rules are both on the page; data-nft and
	// qos-ex.css show the set for the selected classifier. depends() would
	// delete the hidden set's switches from UCI on save.
	scope.setAttribute('data-nft', active);

	function sec(name, type, title) {
		var x = cur.section(form.NamedSection, name, type, title);
		x.anonymous = true; x.addremove = false;
		return x;
	}

	// ============================ Devices =========================
	s = sec('ips', 'ips', _('Devices'));

	// One list per class. An entry is a MAC (a ticked device: matches
	// every IPv4 and IPv6 address it uses) or, for a device whose MAC the
	// router cannot see, a typed address. Saved split by kind into
	// <cls>_mac / _ipv4 / _ipv6, which the backend reads unchanged.
	var macRe = /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/;
	// The backend's rules exactly (pf_valid_ip4 / pf_valid_ip6): an entry it
	// would drop must not be shown as a Gaming or Low device. No leading
	// zeros; IPv6 groups of 1-4 hex digits, 8 of them or at most 7 with
	// one '::', no lone colon at either end.
	var octet = '(0|[1-9]\\d{0,2})';
	var ip4Re = new RegExp('^' + octet + '\\.' + octet + '\\.' + octet + '\\.' + octet + '(?:\\/(0|[1-9]\\d?))?$');
	function isIp4(v) {
		var m = ip4Re.exec(v);
		return !!m && +m[1] < 256 && +m[2] < 256 && +m[3] < 256 && +m[4] < 256 && (m[5] == null || +m[5] <= 32);
	}
	function v6groups(x) {
		if (x === '') return 0;
		var g = x.split(':');
		for (var i = 0; i < g.length; i++)
			if (!/^[0-9a-f]{1,4}$/.test(g[i])) return -1;
		return g.length;
	}
	function isIp6(v) {
		var m = /^([0-9a-f:]+)(?:\/(0|[1-9]\d{0,2}))?$/.exec(v);
		if (!m || macRe.test(v) || (m[2] != null && +m[2] > 128)) return false;
		var a = m[1];
		if (a.indexOf(':') < 0 || a.indexOf(':::') >= 0 || /[0-9a-f]:$/.test(a) || /^:[0-9a-f]/.test(a)) return false;
		var p = a.split('::');
		if (p.length > 2) return false;
		if (p.length === 2) {
			var hd = v6groups(p[0]), tl = v6groups(p[1]);
			return hd >= 0 && tl >= 0 && hd + tl <= 7;
		}
		return v6groups(a) === 8;
	}
	function kind(v) { return macRe.test(v) ? 'mac' : isIp4(v) ? 'ipv4' : isIp6(v) ? 'ipv6' : ''; }

	// Every device the router knows (DHCP leases and neighbours). addrMac
	// maps a known address to its MAC, so a saved address of a device the
	// router can see is ticked as that device (saved by MAC on Save).
	var devs = {}, addrMac = {};
	Object.keys(hints).forEach(function(mac) {
		var hh = hints[mac] || {}, m = String(mac).toLowerCase();
		var a4 = [].concat(hh.ipaddrs || hh.ipv4 || []), a6 = [].concat(hh.ip6addrs || hh.ipv6 || []);
		if (!macRe.test(m) || !(hh.name || a4[0] || a6[0])) return;
		devs[m] = { name: hh.name || '', ip: a4[0] || a6[0] || '' };
		a4.concat(a6).forEach(function(ip) { addrMac[String(ip).toLowerCase()] = m; });
	});

	// Saved entries of one class, newest form: MACs, then addresses that
	// map to a known MAC, then the rest. A malformed entry is dropped
	// (the backend ignores it).
	function saved(cls) {
		var out = [];
		[ '_mac', '_ipv4', '_ipv6' ].forEach(function(sfx) {
			L.toArray(uci.get('qos-ex', 'ips', cls + sfx)).forEach(function(v) {
				v = String(v || '').trim().toLowerCase();
				if (!kind(v)) return;
				if (addrMac[v]) v = addrMac[v];
				if (out.indexOf(v) < 0) out.push(v);
			});
		});
		return out;
	}
	var keep = { gaming: saved('gaming'), lowprio: saved('lowprio') };
	// A saved entry the router does not know now stays in the list.
	keep.gaming.concat(keep.lowprio).forEach(function(v) {
		if (devs[v]) return;
		devs[v] = macRe.test(v) ? { name: '', ip: '', off: true } : { name: '', ip: '', addr: true };
	});
	var devKeys = Object.keys(devs).sort(function(a, b) {
		var x = devs[a], y = devs[b], r = function(d) { return d.addr ? 2 : d.off ? 1 : 0; };
		return (r(x) - r(y)) || (x.name || '\uffff').localeCompare(y.name || '\uffff') ||
			(x.ip || '').localeCompare(y.ip || '', undefined, { numeric: true }) ||
			a.localeCompare(b, undefined, { numeric: true });
	});

	// Write a list only when it changed, so an untouched Save adds nothing.
	function putList(sid, opt, arr) {
		var was = L.toArray(uci.get('qos-ex', sid, opt)).filter(function(v) { return String(v || '').trim(); });
		if (was.join(' ') === arr.join(' ')) return;
		uci.set('qos-ex', sid, opt, arr.length ? arr : null);
	}

	// One table, one row per device, one choice each: Normal, Gaming or
	// Low priority -- a device cannot be in both classes. Set devices sort
	// first; ten rows show, more scroll. pick: entry -> 'gaming' |
	// 'lowprio' | '' (Normal; kept so a row keeps its place in the order).
	var pick = {};
	keep.gaming.forEach(function(v) { pick[v] = 'gaming'; });
	keep.lowprio.forEach(function(v) { if (!pick[v]) pick[v] = 'lowprio'; });
	function picked() {
		return Object.keys(pick).filter(function(v) { return pick[v]; })
			.map(function(v) { return pick[v] + '=' + v; }).join(' ');
	}
	var pick0 = picked();
	// Saved split by kind into <cls>_mac / _ipv4 / _ipv6, which the
	// backend reads unchanged. Always written (forcewrite): a saved
	// address now known by MAC moves to _mac.
	function saveClass(sid, cls) {
		var by = { mac: [], ipv4: [], ipv6: [] };
		Object.keys(pick).forEach(function(v) {
			var k = pick[v] === cls ? kind(v) : '';
			if (k && by[k].indexOf(v) < 0) by[k].push(v);
		});
		Object.keys(by).forEach(function(k) { putList(sid, cls + '_' + k, by[k]); });
	}
	// Ping Filter's Watched devices are ticked by the user only (on its
	// setup card / Settings -> Devices): a device newly set to Gaming here
	// is not added, one that is no longer Gaming is dropped, the rest stay.
	// was: the Gaming entries before this save. moved: a saved Gaming
	// address -> the MAC saveClass now saves it as, so a watched address
	// stays watched as that MAC.
	function pfWatch(was, moved) {
		if (!uci.get('qos-ex', 'pingfilter')) return;
		var now = Object.keys(pick).filter(function(v) { return pick[v] === 'gaming'; });
		var out = [], have = [];
		L.toArray(uci.get('qos-ex', 'pingfilter', 'pf_devices')).forEach(function(v) {
			var k = String(v || '').trim().toLowerCase();
			if (!k) return;
			if (moved[k]) v = k = moved[k];
			if (have.indexOf(k) < 0 && (was.indexOf(k) < 0 || now.indexOf(k) >= 0)) { out.push(v); have.push(k); }
		});
		putList('pingfilter', 'pf_devices', out);
	}

	o = s.option(form.Value, '_devices');
	o.rmempty = true; o.forcewrite = true;
	o.cfgvalue = function() { return pick0; };
	o.formvalue = function() { return picked(); };
	o.write = function(sid) {
		var was = saved('gaming'), moved = {};
		[ 'gaming_ipv4', 'gaming_ipv6' ].forEach(function(opt) {
			L.toArray(uci.get('qos-ex', 'ips', opt)).forEach(function(v) {
				v = String(v || '').trim().toLowerCase();
				if (addrMac[v]) moved[v] = addrMac[v];
			});
		});
		saveClass(sid, 'gaming'); saveClass(sid, 'lowprio');
		pfWatch(was, moved);
	};
	o.remove = o.write;
	o.renderWidget = function() {
		var CH = [ [ '', _('Normal') ], [ 'gaming', _('Gaming') ], [ 'lowprio', _('Low priority') ] ];
		var rows = E('div', { 'class': 'qos-ex-dev-rows' }), rowOf = {};
		var sum = E('span', { 'class': 'qos-ex-muted' });
		var err = E('span', { 'class': 'qos-ex-err' });
		var q = E('input', { 'type': 'search', 'class': 'cbi-input-text qos-ex-dev-q',
			'placeholder': _('Filter by name, IP or MAC'), 'aria-label': _('Filter devices') });
		var add = E('input', { 'type': 'text', 'class': 'cbi-input-text qos-ex-dev-q',
			'placeholder': _('MAC or IP address'), 'aria-label': _('Add a device') });
		function count() {
			var n = { gaming: 0, lowprio: 0 };
			Object.keys(pick).forEach(function(v) { if (pick[v]) n[pick[v]]++; });
			h.setText(sum, _('%d gaming · %d low priority').format(n.gaming, n.lowprio));
		}
		function paint(seg, cls) {
			seg.querySelectorAll('button').forEach(function(b) {
				var on = b.getAttribute('data-v') === cls;
				b.classList.toggle('sel', on);
				b.setAttribute('aria-pressed', on ? 'true' : 'false');
			});
		}
		function row(v) {
			var d = devs[v], name = d.name || (d.addr ? v : d.ip) || v;
			var sub = d.addr ? _('by address') : [ d.off ? _('not on the network now') : (d.name ? d.ip : ''),
				name === v ? '' : v ].filter(Boolean).join(' · ');
			var seg = E('span', { 'class': 'qos-ex-seg', 'role': 'group', 'aria-label': name },
				CH.map(function(c) {
					return E('button', { 'type': 'button', 'class': 'btn cbi-button', 'data-v': c[0],
						'click': function() { pick[v] = c[0]; paint(seg, c[0]); count(); } }, c[1]);
				}));
			paint(seg, pick[v] || '');
			return rowOf[v] = E('div', { 'class': 'qos-ex-dev-row', 'data-q': [ d.name, d.ip, v ].join(' ').toLowerCase() }, [
				E('div', { 'class': 'qos-ex-dev-id' }, [
					E('div', { 'class': 'qos-ex-dev-name' }, [ name ]),
					E('div', { 'class': 'qos-ex-dev-sub qos-ex-muted' }, [ sub || ' ' ]) ]),
				seg ]);
		}
		function filter() {
			var t = q.value.trim().toLowerCase();
			Object.keys(rowOf).forEach(function(v) { rowOf[v].hidden = !!t && rowOf[v].getAttribute('data-q').indexOf(t) < 0; });
		}
		var rank = { gaming: 0, lowprio: 1 };
		devKeys.slice().sort(function(a, b) {
			var x = rank[pick[a]] != null ? rank[pick[a]] : 2, y = rank[pick[b]] != null ? rank[pick[b]] : 2;
			return (x - y) || (devKeys.indexOf(a) - devKeys.indexOf(b));
		}).forEach(function(v) { rows.appendChild(row(v)); });
		var none = devKeys.length ? null : rows.appendChild(
			E('div', { 'class': 'qos-ex-dev-row qos-ex-muted' }, _('No devices found yet — add one below.')));
		// A device the router does not list: a MAC, or an address when the
		// router cannot see its MAC (behind another router). Goes to the top
		// as Normal, ready to set.
		function doAdd() {
			var v = add.value.trim().toLowerCase();
			h.setText(err, '');
			if (!kind(v)) return h.setText(err, _('Expecting a MAC (aa:bb:cc:dd:ee:ff) or an IP address'));
			if (addrMac[v]) v = addrMac[v];
			if (!devs[v]) devs[v] = macRe.test(v) ? { name: '', ip: '', off: true } : { name: '', ip: '', addr: true };
			if (!(v in pick)) pick[v] = '';
			if (none && none.parentNode) rows.removeChild(none);
			if (!rowOf[v]) rows.insertBefore(row(v), rows.firstChild);
			add.value = ''; q.value = ''; filter();
			rowOf[v].scrollIntoView({ block: 'nearest' });
			rowOf[v].querySelector('button[data-v="gaming"]').focus();
		}
		add.addEventListener('keydown', function(ev) { if (ev.key === 'Enter') { ev.preventDefault(); doAdd(); } });
		q.addEventListener('input', filter);
		count();
		return E('div', { 'class': 'qos-ex-dev' }, [
			E('div', { 'class': 'qos-ex-dev-bar' }, [ q, sum ]),
			rows,
			E('div', { 'class': 'qos-ex-dev-bar' }, [ add,
				E('button', { 'type': 'button', 'class': 'btn cbi-button cbi-button-add', 'click': doAdd }, _('Add')), err ]),
			E('div', { 'class': 'cbi-value-description' },
				_('Gaming first, Low priority last. Not listed? Add its MAC or IP.'))
		]);
	};

	// ============================ Ports ===========================
	s = sec('ports', 'ports', _('Port lists'));

	o = s.option(form.Value, 'http', _('Web ports'),
		_('Web traffic, never Gaming (QUIC counts too). Ranges allowed.'));
	o.placeholder = '80,443'; o.default = '80,443';
	o.validate = h.validPorts;

	o = s.option(form.Value, 'tcp_bulk', _('Bulk TCP ports'),
		_('Ports sent to Bulk (LE), either end. Empty = off.'));
	o.placeholder = _('off');
	o.validate = h.validPorts;

	o = s.option(form.Value, 'udp_bulk', _('Bulk UDP ports'),
		_('Ports sent to Bulk (LE), either end. Empty = off.'));
	o.placeholder = _('off');
	o.validate = h.validPorts;

	o = s.option(form.Value, 'vidconf', _('Video-call ports'),
		_('To this port: UDP → CS4 (CAKE: AF41), TCP → AF41. Empty = off.'));
	o.placeholder = _('off');
	o.validate = h.validPorts;

	// ========================== Classifier ========================
	cur = mCls;
	s = sec('settings', 'global', _('Classifier'));

	var oMode = s.option(form.ListValue, 'nft_mode', _('nft ruleset'),
		_('Adaptive: per connection. Advanced: per packet. Simple: SGS.'));
	oMode.value('adaptive', _('Adaptive (default)'));
	oMode.value('advanced', _('Advanced'));
	oMode.value('simple',   _('Simple (SGS)'));
	oMode.default = 'adaptive';
	// rmempty false, or LuCI strips a value equal to the default on save.
	oMode.rmempty = false;
	oMode.onchange = function() {
		// Deferred: the widget commits after its change handler.
		window.setTimeout(function() {
			var v = null;
			try { v = oMode.getUIElement('settings').getValue(); } catch (e) {}
			scope.setAttribute('data-nft', v || active);
		}, 0);
	};

	function flag(sect, name, title, desc, tab) {
		var f = tab ? sect.taboption(tab, form.Flag, name, title, desc)
		            : sect.option(form.Flag, name, title, desc);
		f.enabled = 'yes'; f.disabled = 'no'; f.default = 'yes'; f.rmempty = false;
		return f;
	}
	flag(s, 'wash_down', _('Wash DSCP Down'),
		_('Clear DSCP marks on download traffic to your devices.'));
	flag(s, 'wash_up', _('Wash DSCP Up'),
		_('Clear DSCP marks on traffic leaving to the internet.'));

	// ============================= Rules ==========================
	// One section, bound to `advanced`. The Simple switches live in the
	// `simple` UCI section and are redirected there per option; sim_ and
	// adv_ name prefixes are what qos-ex.css shows or hides.
	s = sec('advanced', 'advanced', _('DSCP rules'));
	s.tab('rules', _('Rules'));
	s.tab('thr',   _('Thresholds'));

	function sim(key, title, desc) {
		var f = flag(s, 'sim_' + key, title, desc, 'rules');
		f.ucisection = 'simple'; f.ucioption = key;
		return f;
	}
	function adv(key, title, desc) {
		var f = flag(s, 'adv_' + key, title, desc, 'rules');
		f.ucioption = key;
		return f;
	}
	sim('gaming_ip', _('Set DSCP EF — gaming devices'),
		_('Gaming devices\' UDP, not to web ports → EF (Gaming).'));
	sim('vidconf', _('Set DSCP CS4 / AF41 — video-call ports'),
		_('UDP → CS4 (Voice; CAKE: AF41, Video), TCP → AF41 (Video).'));
	sim('lowprio_ip', _('Set DSCP CS1 — low-priority devices'),
		_('Low-priority devices\' UDP → CS1 (Low).'));
	sim('bulk_ports', _('Set DSCP LE — bulk ports'),
		_('Bulk TCP / UDP ports → LE (Bulk).'));
	sim('udp_rate', _('Set DSCP AF11 — fast UDP'),
		_('UDP over the fast-flow rate → AF11, unless Gaming or lower.'));
	sim('tcp_500ms', _('Set DSCP AF11 — new TCP'),
		_('TCP still under 500 ms of line rate in bytes → AF11.'));
	sim('tcp_upgrade', _('Set DSCP AF41 — slow TCP'),
		_('TCP under the slow-flow rate → AF41 (Video).'));
	sim('tcp_10s', _('Set DSCP LE — bulk TCP'),
		_('TCP past 10 s of line rate in bytes → LE (Bulk).'));

	adv('gaming_ip', _('Set DSCP EF — gaming devices'),
		_('Gaming devices\' UDP, not to web ports → EF, at any rate.'));
	adv('lowprio_ip', _('Set DSCP CS1 — low-priority devices'),
		_('Low-priority devices\' UDP → CS1 (Low).'));
	adv('meter_down', _('Meter download packets'),
		_('Count download packets for the web-TCP rates. Off: less CPU.'));
	adv('tcp_upgrade', _('Set DSCP AF42 — slow web TCP'),
		_('Web TCP under the slow-flow rate → AF42 (Video).'));
	adv('tcp_10s', _('Set DSCP LE — bulk web TCP'),
		_('Heavy web TCP past the bulk window → LE while it stays heavy.'));
	var advAbout = s.taboption('rules', form.DummyValue, 'adv_about', _('Per packet'));
	advAbout.cfgvalue = function() {
		return _('Web: small CS0, mid-size AF42, fast AF11. Other TCP AF41, UDP CS5; over their rate CS0 / AF41.');
	};

	// Adaptive: no switches. Listed traffic (the device and port lists,
	// VPN, DNS, ping) is decided once; the rest is moved by its flags.
	// Its four settings live in the `adaptive` UCI section.
	var about = s.taboption('rules', form.DummyValue, 'ada_about', _('Adaptive'));
	about.cfgvalue = function() {
		return _('The lists decide once (Gaming, Low, bulk, calls, VPN). The rest: slow TCP AF42, busy UDP AF11, heavy LE.');
	};
	function ada(name, title, desc, range, def) {
		var n = s.taboption('rules', form.Value, 'ada_' + name, title, desc);
		n.ucisection = 'adaptive'; n.ucioption = name;
		if (range) n.datatype = 'range(' + range + ')';
		n.default = def; n.placeholder = def;
		return n;
	}
	ada('heavy_pct', _('Bulk: share of the line (%)'),
		_('A connection or device over this % of the rate is heavy.'), '1,100', '25');
	ada('heavy_secs', _('Bulk: sustained for (s)'),
		_('How long it stays heavy before it goes to Bulk.'), '1,60', '10');
	var oP2p = ada('p2p_rate', _('P2P: new connections a minute'),
		_('A device opening more than this a minute is P2P → Bulk. 0 = off.'), null, '120');
	oP2p.validate = function(sid, v) {
		var n = parseInt(v, 10);
		return (v === '' || (String(n) === String(v).trim() && (n === 0 || (n >= 10 && n <= 10000)))) ? true : _('0, or 10 to 10000');
	};
	var oVpn = ada('vpn_ports', _('VPN ports'),
		_('VPN tunnels stay Default, never demoted (they may carry a game).'), null, '51820,1194');
	oVpn.validate = h.validPorts;

	// Defaults repeat the backend's load_config fallbacks. Only the rate
	// reset and the sticky timeout take 0 (off): nft rejects a zero burst.
	function numf(name, key, title, desc, range, def) {
		var n = s.taboption('thr', form.Value, name, title, desc);
		if (key !== name) n.ucioption = key;
		n.datatype = 'range(' + range + ')'; n.default = def; n.placeholder = def;
		return n;
	}
	numf('udp_fast_pps', 'udp_fast_pps', _('UDP fast-flow rate (pps)'),
		_('UDP over this is fast → AF11; a gaming flow loses EF.'), '1,100000', '450');
	numf('udp_fast_burst', 'udp_fast_burst', _('UDP fast-flow burst (packets)'),
		_('Packets allowed before the fast-flow rate applies.'), '1,100000', '225');
	numf('adv_udp_small_avgpkt', 'udp_small_avgpkt', _('UDP small-packet ceiling (bytes)'),
		_('UDP with average packets this size or less → CS5.'), '1,9000', '576');
	numf('slow_flow_pps', 'slow_flow_pps', _('TCP slow-flow rate (pps)'),
		_('TCP under this many packets a second is slow → AF42.'), '1,100000', '150');
	numf('adv_heavy_flow_pps', 'heavy_flow_pps', _('TCP heavy-flow rate (pps)'),
		_('TCP over this, sustained, is heavy (about 12 Mbit/s).'), '1,100000', '1000');
	var oNew = numf('tcp_new_cap_mbit', 'tcp_new_cap_mbit', _('New-TCP window cap (Mbit)'),
		_('New TCP (AF11) window: 500 ms of download, capped here.'), '1,1000', '80');
	var oBulk = numf('tcp_bulk_cap_mbit', 'tcp_bulk_cap_mbit', _('Bulk-TCP window cap (Mbit)'),
		_('Bulk (LE) window: 10 s of download, capped here.'), '1,1000', '400');

	// Live readout beside each cap: the window it gives at the saved
	// download rate, as calc_bandwidth sizes it (unshaped download = the
	// cap itself; the bulk window always above the new one).
	var winDn = h.shapedRates().dn;
	function winOut() { return E('span', { 'class': 'qos-ex-muted', 'style': 'margin-left:8px;white-space:nowrap' }); }
	function winSize(b) {
		return b >= 1e9 ? (b / 1e9).toFixed(2) + ' GB' : b >= 1e6 ? (b / 1e6).toFixed(1) + ' MB' : Math.round(b / 1e3) + ' kB';
	}
	function winPaint(sid) {
		function cap(o, d) {
			var w = o.section.getUIElement(sid, o.option), v = parseInt(w ? w.getValue() : '', 10);
			return v >= 1 && v <= 1000 ? v : d;
		}
		var ref = function(c) { return winDn > 0 ? Math.min(winDn, c * 1000) : c * 1000; };
		var nw = Math.floor(ref(cap(oNew, 80)) * 500 / 8), bk = ref(cap(oBulk, 400)) * 1250;
		if (bk <= nw) bk = nw * 2;
		var at = winDn > 0 ? _('at your %s Mbit download').format(h.fmtMbps(winDn)) : _('download unshaped');
		h.setText(oNew.winEl, '= ' + winSize(nw) + ' ' + at);
		h.setText(oBulk.winEl, '= ' + winSize(bk) + ' ' + at);
	}
	[ oNew, oBulk ].forEach(function(o) {
		o.winEl = winOut();
		o.renderWidget = function(sid) {
			var w = form.Value.prototype.renderWidget.apply(this, arguments);
			var inp = w.querySelector('input');
			if (inp) inp.addEventListener('input', function() { winPaint(sid); });
			window.requestAnimationFrame(function() { winPaint(sid); });
			return E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap' }, [ w, o.winEl ]);
		};
	});
	numf('adv_web_pps', 'web_pps', _('Web rate (pps)'),
		_('Web connection over this, mid-size packets: excess → AF11.'), '1,100000', '200');
	numf('adv_tcp_pps', 'tcp_pps', _('TCP rate (pps)'),
		_('Non-web TCP over this: the excess → CS0.'), '1,100000', '200');
	numf('adv_udp_pps', 'udp_pps', _('UDP rate (pps)'),
		_('Non-web UDP over this: the excess → AF41.'), '1,100000', '250');
	var oSmall = numf('adv_small_len', 'small_len', _('Small packet (bytes)'),
		_('Web packets this size or less stay CS0.'), '40,8999', '84');
	var oMax = numf('adv_max_len', 'max_len', _('Largest classed packet (bytes)'),
		_('Packets over this size keep CS0.'), '128,9000', '1256');
	// load_config refuses a small size at or over the largest (it uses 84).
	oSmall.validate = function(sid, v) {
		if (v === '' || v == null) return true;
		var w = oMax.section.getUIElement(sid, oMax.option), m = parseInt(w ? w.getValue() : '', 10);
		if (isNaN(m)) m = parseInt(uci.get('qos-ex', 'advanced', 'max_len'), 10) || 1256;
		return parseInt(v, 10) < m ? true : _('Must be below the largest classed packet (%d bytes)').format(m);
	};
	numf('adv_reset_pm', 'reset_pm', _('Rate reset (per 1000)'),
		_('Over-rate packets in 1000 sent the normal way. 0 = off.'), '0,999', '5');
	numf('adv_bulk_timeout', 'bulk_timeout', _('Bulk sticky timeout (s)'),
		_('A bulk pair stays LE this long after. 0 = off.'), '0,86400', '120');

	// ====================== Live ruleset (saved mode) =============
	// Full `nft list table` of the running table, collapsed by default
	// and polled only while open.
	var tbl = h.nftTable(active);
	var rsEmpty = _('(table not loaded — is QoS-Ex running?)');
	var rsText = (loaded && loaded[1] && loaded[1].output) || '';
	var pre = E('pre', {
		'class': 'qos-ex-pre',
		'style': 'max-height:60vh;overflow:auto;margin:0;white-space:pre'
	}, [ rsText || rsEmpty ]);

	// Outside the scroll box, so a paused pane never looks hung.
	var rsHint = E('span', { 'class': 'qos-ex-muted', 'style': 'font-size:11px;margin-left:8px' });

	var det = E('details', { 'class': 'qos-ex-raw' }, [
		E('summary', {}, [ _('nft list table inet ') + tbl, rsHint ]),
		pre
	]);

	function refreshRs() {
		// The dynamic sets gain and lose lines every few seconds, so the
		// text moves under a reader. Stop writing once scrolled in.
		if (pre.scrollTop > 0) {
			h.setText(rsHint, _('paused — scroll to the top to resume'));
			return Promise.resolve();
		}
		h.setText(rsHint, '');
		return h.callRuleset().then(function(r) {
			h.setText(pre, (r && r.output) || rsEmpty);
		});
	}

	det.addEventListener('toggle', function() { if (det.open) refreshRs(); });
	h.pollWhile(det, function() {
		if (!det.open) return Promise.resolve();
		return refreshRs();
	});

	var rsCard = E('div', { 'class': 'cbi-section qos-ex-card' }, [
		E('h3', { 'class': 'qos-ex-card-title' }, [
			_('Active ruleset — '), E('code', {}, [ tbl ]),
			E('span', { 'class': 'qos-ex-muted' }, [ ' ' + h.nftModeDisplay(active) ])
		]),
		det
	]);

	return { maps: [ mDev, mCls ], rsCard: rsCard };
}

return view.extend({
	load: function() {
		return Promise.all([
			// Retired values a config the backend has not migrated yet may
			// still hold: SGS HFSC curves (1.2.9.2) become plain HFSC, the SGS
			// rule set (1.2.8.5) becomes Simple. In memory only -- written
			// with the next Save, never from load().
			uci.load('qos-ex').then(function(r) {
				if (uci.get('qos-ex', 'settings', 'qdisc') === 'hfsc_sgs')
					uci.set('qos-ex', 'settings', 'qdisc', 'hfsc');
				if (uci.get('qos-ex', 'hfsc', 'curves') != null)
					uci.unset('qos-ex', 'hfsc', 'curves');
				if (uci.get('qos-ex', 'settings', 'nft_mode') === 'sgs')
					uci.set('qos-ex', 'settings', 'nft_mode', 'simple');
				return r;
			}),
			// fs.list returns [{ name, type }] per entry: real WAN choices.
			fs.list('/sys/class/net').catch(function() { return []; }),
			// The full report: the live WAN and LAN devices are not in the
			// poll snapshot (state), only in status.
			h.rpcSafe(h.callStatus(), {}),
			h.rpcSafe(h.callRuleset()),
			h.callHostHints().catch(function() { return {}; })
		]);
	},

	render: function(loaded) {
		var scope = E('div', { 'class': 'qos-ex-scope' });
		var sm = buildShaper(this, scope, [ null, loaded[1], loaded[2] ]);
		var rr = buildRules(this, scope, [ null, loaded[3], loaded[4] ]);
		h.quietFlags(form, sm.concat(rr.maps));
		return Promise.all([ sm[0].render(), sm[1].render(), rr.maps[0].render(), rr.maps[1].render() ]).then(function(nodes) {
			// Port fields widen with their contents (qos-ex.css field-sizing);
			// browsers without it get a live size attribute instead.
			if (!(window.CSS && CSS.supports && CSS.supports('field-sizing', 'content')))
				nodes[2].querySelectorAll('#cbi-qos-ex-ports .cbi-value-field input').forEach(function(i) {
					function fit() { i.size = Math.max(20, (i.value || i.placeholder || '').length + 2); }
					i.addEventListener('input', fit);
					fit();
				});
			var tabs = E('div', {}, [
				E('div', { 'data-tab': 'line',  'data-tab-title': _('Line') }, [ nodes[0] ]),
				E('div', { 'data-tab': 'dev',   'data-tab-title': _('Devices & Ports') }, [ nodes[2] ]),
				E('div', { 'data-tab': 'queue', 'data-tab-title': _('Queue') }, [ nodes[1] ]),
				E('div', { 'data-tab': 'rules', 'data-tab-title': _('Rules') }, [ nodes[3], rr.rsCard ])
			]);
			// A link can open a tab: setup#line, #dev, #queue or #rules.
			var want = String(window.location.hash || '').slice(1);
			Array.prototype.forEach.call(tabs.childNodes, function(p) {
				if (want && p.getAttribute('data-tab') === want) p.setAttribute('data-tab-active', 'true');
			});
			scope.appendChild(h.pageHead(_('Setup')));
			scope.appendChild(tabs);
			ui.tabs.initTabGroup(tabs.childNodes);
			return scope;
		});
	},

	// The four maps share one uci change queue. LuCI's stock handleSave saves
	// them in parallel, so each flushes the same queue and every delete goes
	// out more than once -- the repeat is ubus code 4, "Resource not found".
	// One after the other, each flush carries its own changes only.
	handleSave: function() {
		var maps = document.getElementById('maincontent').querySelectorAll('.cbi-map');
		var self = this;
		return Array.prototype.reduce.call(maps, function(p, node) {
			return p.then(function() { return dom.callClassMethod(node, 'save'); });
		}, Promise.resolve()).then(function() {
			// A saved MSS gate decides whether its own field still shows.
			if (self.qosExRefresh) self.qosExRefresh();
		});
	}

	// Save & Apply is LuCI's stock flow on purpose: the commit fires the
	// service's procd reload trigger, and qos-ex.sh reload escalates to a full
	// rebuild when a shaping value moved and rebuilds the ruleset otherwise.
	// Calling restart from here ran before the commit and held the backend
	// lock against that reload.
});
