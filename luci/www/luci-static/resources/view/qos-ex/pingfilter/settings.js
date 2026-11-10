'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require dom';
'require ui';
'require view.qos-ex._helpers as h';

// Ping Filter → Settings: the Settings tab in setup order (Devices, Mode,
// Home; the fields of the mode in use only) with the Advanced options fold,
// and the Tools tab (actions and diagnostics with their output; the setup
// card while Ping Filter is off). Links can open a tab or a section:
// settings#tools, #devices, #mode, #home.
// Ping Filter Advanced (1.3.1.6 and older) lives here now: its tuning
// options under the Advanced options fold, its actions on the Tools tab.

// Single shared <pre> reference for the result panel. Each action pipes its
// stdout in. Errors render in the danger style.
var resultBox = null;
var resultMeta = null;
var runningVerb = null;

function setResult(text, isErr) {
	if (!resultBox) return;
	resultBox.textContent = text || '(no output)';
	resultBox.className = isErr
		? 'qos-ex-pre qos-ex-pre-err'
		: 'qos-ex-pre';
}

function setMeta(text, kind) {
	if (!resultMeta) return;
	resultMeta.textContent = text || '';
	resultMeta.className = 'qos-ex-pf-adv-meta';
	if (kind === 'err') resultMeta.classList.add('qos-ex-err');
	else if (kind === 'ok') resultMeta.classList.add('qos-ex-ok');
	else resultMeta.classList.add('qos-ex-muted');
}

// Run a pf_text RPC verb. Captures full stdout into the result box. Returns
// a promise that resolves once finished so caller can chain (e.g. refresh).
function runText(verb, ip) {
	if (runningVerb) {
		ui.addNotification(null, E('p', _('Another action is still running \u2014 please wait.')), 'info');
		return Promise.resolve(null);
	}
	runningVerb = verb;
	setMeta(_('Running: ') + verb + (ip ? ' ' + ip : '') + ' \u2026', 'info');
	setResult(_('(running, please wait...)'), false);
	if (resultBox && resultBox.scrollIntoView) resultBox.scrollIntoView({ block: 'nearest' });
	// Two backing methods, one runner. pf_text is granted under the ACL's
	// read section and accepts only read-only diagnostics; everything that
	// changes state goes through pf_run, which is write-granted. Deciding it
	// here, from the verb, keeps every button below unaware of the split --
	// and keeps the split impossible to forget when a button is added.
	var MUTATING = { scan: 1, clear: 1, refresh_lists: 1,
	                 session_reset: 1, reclassify: 1,
	                 geo_check: 1, livecap: 1 };
	var call = MUTATING[verb] ? h.callPfRun(verb, ip || '') : h.callPfText(verb, ip || '');
	return call.then(function(r) {
		runningVerb = null;
		if (r && r.error) {
			setResult(r.error, true);
			setMeta(_('Failed: ') + verb, 'err');
			return r;
		}
		var out = (r && r.output) ? r.output : '';
		setResult(out, false);
		setMeta(_('Done: ') + verb + (ip ? ' ' + ip : ''), 'ok');
		return r;
	}).catch(function(e) {
		runningVerb = null;
		setResult(_('RPC error: ') + (e && e.message ? e.message : String(e)), true);
		setMeta(_('Failed: ') + verb, 'err');
		return null;
	});
}

// One action row, as System -> Maintenance: button left, what it does right.
// confirmMsg set = destructive, asks first.
function row(label, kind, verb, descr, confirmMsg) {
	return [
		E('div', {}, E('button', {
			'class': 'cbi-button cbi-button-' + kind + ' qos-ex-pf-adv-btn',
			'click': ui.createHandlerFn(this, function() {
				if (confirmMsg && !confirm(confirmMsg + '\n\n' + _('Continue?'))) return;
				return runText(verb);
			})
		}, label)),
		E('div', { 'class': 'cbi-value-description' }, descr)
	];
}
function rows(list) {
	return E('div', { 'class': 'qos-ex-grid qos-ex-pf-adv-rows' },
		list.reduce(function(a, b) { return a.concat(b); }, []));
}

return view.extend({
	load: function() {
		// Defensive: if /etc/config/qos-ex was created by an older qos-ex.sh that
		// didn't seed the pingfilter section, create it in memory with sensible
		// defaults before rendering, so the form.Map has a section to bind to.
		// These edits ride along with the next Save. Through 1.0.8.9 load()
		// staged them with uci.save() on merely opening the tab: a phantom
		// "Unsaved Changes" count, and a load failure for read-only ACL users.
		// Force a fresh fetch of committed UCI so Settings always MIRRORS
		// changes made elsewhere — the Dashboard profile buttons and the Map
		// sliders all commit via rpc. Without this, LuCI serves a cached copy
		// and the form shows stale values (e.g. ping target not following a
		// profile switch to observe/distance).
		uci.unload('qos-ex');
		var view = this;
		// Country names seen so far (region lock choices), and for the Devices
		// labels the address each MAC holds now (Ping Filter's lookup, else
		// the host hints) and its host name. Awaited: through 1.3.0.6 the
		// countries were filled after render had already read them.
		return Promise.all([
			h.rpcSafe(h.callPfServers(), { servers: [] }),
			h.rpcSafe(h.callPfStatus(), {}),
			h.callHostHints().catch(function() { return {}; })
		]).then(function(r) {
			var seen = {}, hm = h.hintMacMap(r[2]), pm = h.pfMacMap(h.parseState((r[1] && r[1].output) || '').state);
			view.pfOn = h.pingFilterEnabled(h.parseState((r[1] && r[1].output) || '').state);
			((r[0] && r[0].servers) || []).forEach(function(sv) { if (sv.country) seen[sv.country] = 1; });
			view.countries = Object.keys(seen).sort();
			view.macMap = {}; view.hostNames = {};
			Object.keys(hm).forEach(function(m) { view.macMap[m] = hm[m]; });
			Object.keys(pm).forEach(function(m) { view.macMap[m] = pm[m]; });
			Object.keys(r[2] || {}).forEach(function(m) { if (r[2][m] && r[2][m].name) view.hostNames[String(m).toLowerCase()] = r[2][m].name; });
			return uci.load('qos-ex');
		}).then(function(arr) {
			if (!uci.get('qos-ex', 'pingfilter')) {
				uci.add('qos-ex', 'pingfilter', 'pingfilter');
				uci.set('qos-ex', 'pingfilter', 'enabled', '0');
				uci.set('qos-ex', 'pingfilter', 'threshold_ms', '0');
				uci.set('qos-ex', 'pingfilter', 'max_servers', '250');
				uci.set('qos-ex', 'pingfilter', 'geoip_lookup', 'yes');
				uci.set('qos-ex', 'pingfilter', 'block_mode', 'ping');
			} else {
				// Keys the backend no longer reads go with the next Save (an
				// update removes them too: uci_migrate). The second group are
				// fixed in the Ping Filter since 2.0.7.4; the new-server policy
				// is set by the mode since 2.0.8.0; game names went in 2.0.8.4.
				var dead = [
					'ping_timeout', 'activity_poll', 'stale_timeout',
					'block_timeout', 'udp_port_min', 'udp_port_max',
					'distance_estimate', 'estimate_after_fails',
					'fallback_gap_sec', 'idle_reset_sec',
					'tcp_min_bps', 'tcp_min_age', 'scan_interval',
					'ping_count', 'probe_retries', 'catch_grace', 'hs_rtt',
					'area_km', 'area_min', 'geo_retry', 'dist_base_ms', 'dist_slope_us',
					'presence_pps', 'conn_min_pps', 'match_end_wait', 'rtt_probe',
					'gap_ms', 'session_min', 'tele_gap', 'prefix_ttl', 'map_keep',
					'set_timeout', 'learning', 'profile', 'unknown_ping', 'unknown_distance',
					'game_names', 'game_dns', 'game'
				];
				for (var i = 0; i < dead.length; i++) {
					if (uci.get('qos-ex', 'pingfilter', dead[i]) != null) {
						uci.unset('qos-ex', 'pingfilter', dead[i]);
					}
				}
				// Migrate old block_mode values to "ping".
				var bm = uci.get('qos-ex', 'pingfilter', 'block_mode');
				if (bm === 'either' || bm === 'both') {
					uci.set('qos-ex', 'pingfilter', 'block_mode', 'ping');
				}
			}
			return arr;
		});
	},

	render: function(loaded) {
		// --- Home coordinate validators (shared by lat/lon fields) --------
		// Home is NOT required to SAVE the form — it's only required to
		// TURN ON Ping Filter (the Dashboard's On/Off button gates on it).
		// So empty is valid here; only malformed or out-of-range values are
		// rejected, and threshold/probe/geo tweaks save before a home pin.
		// 0 on its own is a real place (the equator, Greenwich); only 0, 0
		// is refused. `this` is the option, so the other field is readable.
		function bothZero(opt, sid, other, v) {
			var o = opt.section.formvalue(sid, other);
			return v === 0 && o != null && o !== '' && parseFloat(o) === 0;
		}
		function validateLat(section_id, value) {
			if (value === '' || value == null) return true;
			if (!/^-?\d+(\.\d+)?$/.test(value))
				return _('Must be a decimal number, e.g. 51.5074');
			var v = parseFloat(value);
			if (v < -90 || v > 90) return _('Latitude must be between -90 and 90');
			if (bothZero(this, section_id, 'home_lon', v)) return _('0, 0 is not a home \u2014 set your real location');
			return true;
		}
		function validateLon(section_id, value) {
			if (value === '' || value == null) return true;
			if (!/^-?\d+(\.\d+)?$/.test(value))
				return _('Must be a decimal number, e.g. -0.1278');
			var v = parseFloat(value);
			if (v < -180 || v > 180) return _('Longitude must be between -180 and 180');
			if (bothZero(this, section_id, 'home_lat', v)) return _('0, 0 is not a home \u2014 set your real location');
			return true;
		}

		var m = new form.Map('qos-ex', '', '');

		// No On/Off in this form (1.0.9.7): the switch is on the Dashboard,
		// the Overview and, while off, the Tools tab's setup card. It was an
		// action button here too (pf_action enable|disable, never a form
		// field), so removing it changes nothing Save & Apply writes.

		var o;
		var countries = this.countries || [];
		function filled(v) { return String(v == null ? '' : v).trim() !== ''; }
		// One NamedSection per card, all of the one pingfilter section. key:
		// the section a link opens (settings#key); adv: in the Advanced fold.
		function sec(title, key, adv) {
			var x = m.section(form.NamedSection, 'pingfilter', 'pingfilter', title);
			x.anonymous = true; x.addremove = false;
			x.qxSec = key; x.qxAdv = !!adv;
			return x;
		}

		// ================================================================
		// Setup order: Devices, Mode, Home; the tuning goes in the
		// Advanced options fold below. The daemon clamps every number in
		// pf_load_config, so one set over SSH (qos-ex.pingfilter) is still
		// range-checked. A field hidden by the mode keeps its value
		// (retain): each mode keeps its own number.
		// ================================================================

		// ---- Devices ----------------------------------------------------------
		// Setup → Devices & Ports owns the gaming source set (a device newly
		// set to Gaming there is ticked here too). This selection decides which
		// of those devices Ping Filter watches -- it can subtract, never add,
		// and nothing ticked means Ping Filter has no sources and stays off.
		var s = sec(_('Devices'), 'devices');

		// Gaming devices are picked by MAC on Setup -> Devices & Ports; Ping Filter
		// watches the IPv4 a MAC holds. Offered: the MACs, then IPv4 typed
		// there by address. Typed IPv6 is not offered (servers reached over
		// IPv6 are not graded). Empty entries (old seed) are skipped.
		var mdg4 = L.toArray(uci.get('qos-ex', 'ips', 'gaming_ipv4')).filter(filled);
		var mdg6 = L.toArray(uci.get('qos-ex', 'ips', 'gaming_ipv6')).filter(filled);
		var mdgm = L.toArray(uci.get('qos-ex', 'ips', 'gaming_mac')).filter(filled).map(function(x) { return String(x).toLowerCase(); });
		var sel = L.toArray(uci.get('qos-ex', 'pingfilter', 'pf_devices')).filter(filled);
		var macMap = this.macMap || {}, names = this.hostNames || {}, offer = [];
		mdgm.forEach(function(mac) {
			offer.push([ mac, [ names[mac], macMap[mac] ? macMap[mac].join(', ') : _('not on the network now'), mac ].filter(Boolean).join(' \u00b7 ') ]);
		});
		mdg4.forEach(function(ip) { offer.push([ ip, ip + ' \u00b7 ' + _('by address') ]); });
		// A ticked entry not offered above stays listed so it can be
		// unticked: no longer a gaming device (the backend ignores it), or a
		// typed IPv6 ticked before 1.3.0.7.
		sel.forEach(function(v) {
			if (mdg4.indexOf(v) < 0 && mdgm.indexOf(String(v).toLowerCase()) < 0)
				offer.push([ v, mdg6.indexOf(v) < 0 ? v + ' \u00b7 ' + _('no longer a gaming device') : v ]);
		});
		// LuCI's dropdown throws on an empty choice list (the whole page
		// failed to render) -- with nothing to offer, say so instead.
		if (offer.length) {
			o = s.option(form.MultiValue, 'pf_devices', _('Watched devices'),
				_('Ping Filter watches only the devices ticked here.'));
			o.rmempty = true;
			o.placeholder = _('-- Tick devices --');
			offer.forEach(function(x) { o.value(x[0], x[1]); });
		} else {
			o = s.option(form.DummyValue, '_pf_devices', _('Watched devices'));
			o.renderWidget = function() {
				return E('div', {}, [ _('No gaming devices yet.') + ' ', h.go([ 'setup', '#dev' ], _('Pick one on Devices & Ports')) ]);
			};
		}

		// ---- Mode -------------------------------------------------------------
		s = sec(_('Mode'), 'mode');

		o = s.option(form.ListValue, 'block_mode', _('Block by'),
			_('Ping: each server\'s ping. Distance: your radius.'));
		o.value('ping',     _('Ping (default)'));
		o.value('distance', _('Distance from home'));
		o.default = 'ping'; o.rmempty = false;

		o = s.option(form.Value, 'threshold_ms', _('Ping limit (ms)'),
			_('Block servers above this. 0 = watch only.'));
		o.datatype = 'range(0,5000)'; o.default = '0';
		o.depends('block_mode', 'ping');
		o.retain = true;

		o = s.option(form.Value, 'home_radius_km', _('Radius (km)'),
			_('Servers inside it are allowed, those outside blocked.'));
		o.datatype = 'range(50,20000)'; o.default = '1000'; o.rmempty = false;
		o.depends('block_mode', 'distance');
		o.retain = true;

		o = s.option(form.Value, 'ping_catch_ms', _('Ping Catch (ms)'),
			_('Outside your radius, let in servers at or under this. 0 = off'));
		o.datatype = 'range(0,250)'; o.default = '0';
		o.depends('block_mode', 'distance');
		o.retain = true;

		o = s.option(form.DynamicList, 'allow_country', _('Only these countries'),
			_('Servers in other countries are blocked. Empty = off.'));
		o.rmempty = true; o.placeholder = _('e.g. United Kingdom');
		// An empty entry (seeded by qos-ex.sh before 3.1.5.3) drew a blank row.
		o.cfgvalue = function(sid) { return L.toArray(uci.get('qos-ex', sid, 'allow_country')).filter(filled); };
		countries.forEach(function(c) { o.value(c); });

		// ---- Home -------------------------------------------------------------
		// Needed to turn Ping Filter on, optional to save.
		s = sec(_('Home'), 'home');

		o = s.option(form.Value, 'home_lat', _('Latitude'),
			_('Or right-click the Map to drop a pin.'));
		o.placeholder = '51.5074';
		o.validate = validateLat;

		o = s.option(form.Value, 'home_lon', _('Longitude'));
		o.placeholder = '-0.1278';
		o.validate = validateLon;

		// A node, not markup in a description: some themes escape those.
		o = s.option(form.DummyValue, '_home_map', _('Map'));
		o.renderWidget = function() { return h.go([ 'pingfilter', 'map' ], _('Set on the Map')); };

		// ---- Advanced options (was Ping Filter -> Advanced -> Options) ----
		// Every value is clamped by the daemon when it loads the config
		// (pf_load_config); the ranges below mirror those clamps. These
		// sections are moved into the fold after render, inside the map so
		// the form still finds and saves them.
		(function() {
			function num(key, label, descr, lo, hi, def) {
				o = s.option(form.Value, key, label, descr);
				o.datatype = 'range(' + lo + ',' + hi + ')';
				o.default = String(def); o.placeholder = String(def); o.rmempty = false;
				return o;
			}
			// Stored in seconds, shown in a larger unit.
			function scaled(key, label, descr, div, lo, hi, def) {
				num(key, label, descr, lo, hi, def / div);
				o.cfgvalue = function(sid) {
					var v = parseInt(uci.get('qos-ex', sid, key), 10);
					if (isNaN(v)) v = def;
					return String(Math.min(hi, Math.max(lo, Math.round(v / div))));
				};
				o.write = function(sid, value) {
					uci.set('qos-ex', sid, key, String((parseInt(value, 10) || 0) * div));
				};
			}

			s = sec(_('Grading'), '', true);
			num('ping_var_pct', _('Ping tolerance (%)'), _('Margin over the limit: 5 = 80 ms passes at 84.'), 0, 50, 5);
			num('auto_pin', _('Auto-list /24 after'), _('Servers on one list before their /24 joins it. 0 = off.'), 0, 20, 2);
			num('area_adjust_pct', _('Area lower by (%)'), _('Lowers estimates taken from nearby servers.'), 0, 50, 5);
			num('active_pps', _('In-game rate (pps)'), _('UDP rate that counts as playing.'), 5, 500, 20);
			o = s.option(form.Flag, 'telemetry', _('Grade from gameplay'),
				_('Score servers from real games, not just pings.'));
			o.enabled = '1'; o.disabled = '0'; o.default = '1'; o.rmempty = false;
			o = s.option(form.Flag, 'lite', _('Lite (small routers)'),
				_('Limit or radius only: no gameplay grading or Ping Catch.'));
			o.enabled = '1'; o.disabled = '0'; o.default = '0'; o.rmempty = false;

			s = sec(_('Network'), '', true);
			o = s.option(form.Value, 'ignore_ports', _('Ignore UDP ports'),
				_('Voice and party chat, not game servers. Add Discord 50000-65535.'));
			o.placeholder = '3478-3481'; o.default = '3478-3481'; o.rmempty = true;
			o.validate = h.validPorts;
			o = s.option(form.Flag, 'geoip_lookup', _('Look up locations'),
				_('Country and city for the map, via a free public service.'));
			o.enabled = 'yes'; o.disabled = 'no'; o.default = 'yes'; o.rmempty = false;

			s = sec(_('Memory'), '', true);
			num('max_servers', _('Server list size'), _('Oldest unpinned servers are dropped above this.'), 50, 2000, 250);
			scaled('row_ttl', _('Keep servers (days)'), _('A server not seen for this long is forgotten.'), 86400, 1, 30, 604800);
			scaled('persist_interval', _('Save to flash every (min)'), _('How often the server list is saved to flash.'), 60, 1, 1440, 3600);
		})();

		var view = this;
		h.quietFlags(form, m);
		return m.render().then(function(mapNode) {
			// One rendered card per section, in order: tag the ones a link
			// opens, move the flagged ones into the fold.
			var secs = Array.prototype.filter.call(mapNode.children, function(n) { return n.classList.contains('cbi-section'); });
			var fold = E('details', { 'class': 'qos-ex-raw qx-adv' }, [ E('summary', {}, _('Advanced options')),
				E('div', { 'class': 'qos-ex-muted qx-sub', 'style': 'margin:6px 0 10px' },
					_('The defaults suit most games.')) ]);
			m.children.forEach(function(x, i) {
				if (!secs[i]) return;
				if (x.qxSec) secs[i].setAttribute('data-qx-sec', x.qxSec);
				if (x.qxAdv) fold.appendChild(secs[i]);
			});
			mapNode.appendChild(fold);
			var tools = view.pfOn ? view.tools() : [ h.pfSetup({ sw: true, macMap: view.macMap }) ];
			var tabs = E('div', {}, [
				E('div', { 'data-tab': 'settings', 'data-tab-title': _('Settings') }, [ mapNode ]),
				E('div', { 'data-tab': 'tools', 'data-tab-title': _('Tools') }, tools)
			]);
			// A link can open a tab (#tools) or a section of the Settings
			// tab (#devices, #mode, #home), scrolled to once on screen.
			var want = String(window.location.hash || '').slice(1);
			var to = want && want !== 'tools' ? mapNode.querySelector('[data-qx-sec="' + want + '"]') : null;
			Array.prototype.forEach.call(tabs.childNodes, function(p) {
				if (p.getAttribute('data-tab') === (to ? 'settings' : want)) p.setAttribute('data-tab-active', 'true');
			});
			var scope = E('div', { 'class': 'qos-ex-scope' }, [ h.pageHead(_('Ping Filter Settings'), 'pf'), tabs ]);
			ui.tabs.initTabGroup(tabs.childNodes);
			if (to) (function scroll(n) {
				if (document.body.contains(to)) to.scrollIntoView({ block: 'start' });
				else if (n < 20) window.requestAnimationFrame(function() { scroll(n + 1); });
			})(0);
			// A link to this page (the setup card's steps on the Tools tab)
			// changes the hash at most, which LuCI's tabs do not follow: open
			// its tab and section here.
			scope.addEventListener('click', function(ev) {
				if (ev.defaultPrevented || ev.button !== 0 || ev.ctrlKey || ev.metaKey || ev.shiftKey || ev.altKey) return;
				var a = ev.target.closest('a.qx-go');
				if (!a || !a.hash || a.pathname !== window.location.pathname) return;
				var key = a.hash.slice(1), sec = mapNode.querySelector('[data-qx-sec="' + key + '"]');
				var tab = scope.querySelector('.cbi-tabmenu > li[data-tab="' + (sec ? 'settings' : key) + '"] > a');
				ev.preventDefault();
				history.replaceState(null, '', a.hash);
				if (tab) tab.click();
				if (sec) sec.scrollIntoView({ block: 'start' });
			});
			return scope;
		});
	},

	// Actions and diagnostics: run one, read its output below.
	tools: function() {
		// Shared result panel -- declared first so the handlers can write into it.
		resultMeta = E('div', { 'class': 'qos-ex-pf-adv-meta qos-ex-muted' }, _('Idle. Run any action above.'));
		resultBox  = E('pre', { 'class': 'qos-ex-pre',
			'style': 'min-height:240px;max-height:520px' }, _('(no output yet)'));
		return [
			E('div', { 'class': 'cbi-section qos-ex-card' }, [
				E('h3', { 'class': 'qos-ex-card-title' }, _('Maintenance')),
				rows([
					row(_('Run scan now'), 'action', 'scan',
						_('Grade new servers now, not at the next pass.')),
					row(_('Re-check cache'), 'action', 'reclassify',
						_('Re-grade and re-ping every server. Can cut one that fails.'),
						_('Re-grade every cached server against the current settings.')),
					row(_('New game'), 'reset', 'session_reset',
						_('Clear found servers and blocks, then rescan. Lists stay.'),
						_('Clear the found servers and the block set, then rescan?')),
					row(_('Clear cache'), 'remove', 'clear',
						_('Forget every server, grade and location. Lists stay.'),
						_('Forget every server, grade, location and /24 memory?\n\nThe server you are on may be cut until it is graded again.'))
				])
			]),
			E('div', { 'class': 'cbi-section qos-ex-card' }, [
				E('h3', { 'class': 'qos-ex-card-title' }, _('Diagnostics')),
				rows([
					row(_('Show status'), 'neutral', 'status',
						_('Daemon state, set counts, prerequisites, cadence.')),
					row(_('Live capture (10s)'), 'action', 'livecap',
						_('Watch the game for 10 s: rate, jitter, gaps and a ping.')),
					row(_('Verify rules'), 'neutral', 'verify',
						_('Check the Ping Filter table, sets and chains are loaded.')),
					row(_('Rule errors'), 'neutral', 'nfterr',
						_('Last nft error the daemon captured, if any.'))
				])
			]),
			E('div', { 'class': 'cbi-section qos-ex-card' }, [
				E('h3', { 'class': 'qos-ex-card-title' }, _('Result')),
				resultMeta,
				resultBox
			])
		];
	}

	// Save & Apply is LuCI's stock flow on purpose. The commit fires the
	// service's procd reload trigger (qos-ex init, service_triggers), and
	// qos-ex.sh reload escalates to a full rebuild when shaping moved and
	// reloads PingFilter. Through 1.0.7.1 this view also called restart /
	// pf reload from here -- but view.handleSaveApply does not wait for
	// ui.changes.apply(), so that ran BEFORE the commit (old config) and
	// held the backend lock when the trigger's reload arrived, which then
	// skipped: the new settings silently never applied.
});
