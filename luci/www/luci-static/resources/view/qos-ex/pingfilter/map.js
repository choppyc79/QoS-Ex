'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require poll';
'require view.qos-ex._helpers as h';

// Ping Filter → Map: the servers Ping Filter shows (h.pfVisible), grouped
// by location on a Leaflet map with the home pin and its radius ring. The
// legend chips filter the map; the controls above it (New game, Re-check
// cache, block mode, ping limit, radius and Ping Catch sliders) act at
// once. With Ping Filter off it is the setup map: the setup card, right-
// click or Pin home here (the cross at the centre) to set home, and the
// radius and Ping Catch sliders in Distance mode.

// Colour per state for map markers. Resolves the same CSS custom
// properties the .pf-badge classes use, so the map, the ladder and
// the Servers page cannot disagree, and dark mode is handled for free.
// Leaflet writes stroke/fill as SVG ATTRIBUTES, which do not accept
// var(), so the value is resolved once via getComputedStyle and cached.
// Manual whitelist/blacklist are NOT colours here -- they resolve to the
// verdict they force (green/red) and are distinguished by ringFor()'s
// white/black stroke, so one pinned address can never repaint a whole
// location cell and hide how its neighbours graded.
// Local alias for the shared escaper. Was a full implementation here, and
// before that two byte-identical copies inside buildPopupHtml and
// buildGroupPopupHtml plus a third partial one in the no-geo tray that
// missed r.state. It now lives in _helpers.js, because keeping it private
// to this view is why pingfilter/settings.js had no escaper at all.
function escHtml(s) { return h.escHtml(s); }

var COLOR_CACHE = null;
function themeColor(name, fallback) {
	if (COLOR_CACHE === null) COLOR_CACHE = {};
	if (COLOR_CACHE[name] !== undefined) return COLOR_CACHE[name];
	var v = '';
	try {
		if (typeof window !== 'undefined' && window.getComputedStyle)
			v = (getComputedStyle(document.documentElement)
				.getPropertyValue(name) || '').trim();
	} catch (e) { v = ''; }
	// An unresolved or non-literal value (a var() chain the browser could
	// not substitute) must not reach an SVG attribute.
	if (!v || v.indexOf('var(') === 0) v = fallback;
	COLOR_CACHE[name] = v;
	return v;
}

// Fill colour = what the filter DECIDED about this server. A manual pin
// resolves to the same colour as the verdict it forces, so a whitelisted
// server reads green exactly like any other allowed one -- the pin itself is
// carried by the ring below, not by recolouring the dot.
function colorFor(state) {
	switch (state) {
		case 'allowed':
		case 'whitelist':   return themeColor('--success-color-high',    '#3c763d');
		case 'blocked':
		case 'blacklist':   return themeColor('--error-color-high',  '#a94442');
		case 'cached':      return themeColor('--text-color-low', '#9aa0a6');
		default:            return '#cc9900';
	}
}

// Ring colour = manual list membership, and nothing else. Deliberately
// achromatic so it can never be confused with a quality/verdict colour, and
// so it survives both themes: white and black both sit on a saturated fill.
function ringFor(pin) {
	if (pin === 'wl') return '#ffffff';
	if (pin === 'bl') return '#000000';
	return '';
}

// A pinned row is a manual list entry. Pins are drawn on the map
// PERMANENTLY -- they do not depend on live traffic, because their geo
// comes from the daemon's reboot-persisted geo cache, not from a
// servers.tsv row that ages out after row_ttl.
// Every class the marker pulse can wear. Enumerated so a reused
// marker can be cleared of the one it wore last tick.
var PULSE_CLASSES = ['pf-marker-cached'];

function pinKindOf(state) {
	if (state === 'whitelist') return 'wl';
	if (state === 'blacklist') return 'bl';
	return '';
}

// A slider rail over a setting's whole Settings range, in uneven steps:
// fine where values are picked, coarse past them. The slider moves an
// index into the list; a value off the list sits at the nearest stop (its
// label still shows the true value).
function stops(runs) {
	var a = [];
	runs.forEach(function(r) { for (var v = r[0]; v <= r[1]; v += r[2]) if (a[a.length - 1] !== v) a.push(v); });
	return a;
}
function stopAt(list, v) {
	var i = 0;
	while (i < list.length - 1 && (list[i] + list[i + 1]) / 2 < v) i++;
	return i;
}
var THR_STOPS = stops([ [ 0, 300, 5 ], [ 350, 1000, 50 ], [ 1500, 5000, 500 ] ]);
var RAD_STOPS = stops([ [ 50, 1000, 50 ], [ 1100, 10000, 100 ], [ 11000, 20000, 1000 ] ]);
// A slider's value label: the number with its unit, or a word for 0.
function numLabel(el, unit, v, zero) {
	el.textContent = v > 0 ? String(v) : zero;
	unit.style.display = v > 0 ? '' : 'none';
}

// ---------------------------------------------------------------------
// POPUP INTERACTION GUARD (v1.7.8)
//
// drawMarkers() used to clearLayers() and rebuild every marker on each
// poll tick, which destroyed any OPEN popup -- click a dot to read it and
// it was yanked away within five seconds, and a click on +W could land
// on a button that no longer existed. Same bug class as the scroll-jump
// the scroll guard fixed in 1.7.6: a poll-driven DOM rebuild fighting
// the user.
//
// Markers are now cached by location cell and mutated in place, and this
// guard reports whether the user is actively inside an open popup, in
// which case even the in-place content swap is deferred a tick.
// ---------------------------------------------------------------------
function popupBusy(marker) {
	if (!marker || !marker.isPopupOpen || !marker.isPopupOpen()) return false;
	var pop = marker.getPopup && marker.getPopup();
	var el  = pop && pop.getElement && pop.getElement();
	if (!el) return false;
	// Keyboard focus inside the popup, or a pending in-flight action.
	try {
		if (document.activeElement && el.contains(document.activeElement)) return true;
	} catch (e) { /* detached node */ }
	if (el.querySelector('button:disabled')) return true;
	// A live text selection inside the popup dies the instant we swap.
	var sel = (typeof window !== 'undefined' && window.getSelection)
		? window.getSelection() : null;
	if (sel && sel.rangeCount && !sel.isCollapsed) {
		var n = sel.anchorNode;
		if (n && n.nodeType !== 1) n = n.parentNode;
		if (n && el.contains(n)) return true;
	}
	return false;
}

// The Leaflet build. Its script takes window.L, which is LuCI's own global:
// cbi.js E() -- and so ui.addNotification -- reads it on every call. Left in
// place, every banner on this tab threw once the map was up, and whatever
// followed the banner (close the popup, refetch) never ran. noConflict()
// hands window.L back; Leaflet is kept here.
var LF = null;
function takeLeaflet() {
	if (!LF && window.L && window.L.map && window.L.noConflict) LF = window.L.noConflict();
	return LF;
}

// Lazy-load Leaflet if not already present: the router's copy, else the
// unpkg copy pinned by SRI. Resolves with Leaflet (LF), or rejects if
// loading fails (network blocked, etc).
// anchor is the node this load is for; if it leaves the document while we
// are still waiting, the wait is abandoned rather than left ticking against
// a view the operator has already navigated away from.
function loadLeaflet(anchor) {
	if (takeLeaflet()) return Promise.resolve(LF);

	function gone() {
		return !!(anchor && anchor.ownerDocument &&
		          !anchor.ownerDocument.contains(anchor));
	}
	return new Promise(function(resolve, reject) {
		if (!document.querySelector('link[href*="leaflet.css"]')) {
			var link = document.createElement('link');
			link.rel  = 'stylesheet';
			link.href = L.resource('qos-ex/leaflet.css');
			// Not vendored (the install had no internet): the pinned CDN copy.
			link.onerror = function() {
				link.onerror = null;
				link.integrity   = 'sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=';
				link.crossOrigin = 'anonymous';
				link.href = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css';
			};
			document.head.appendChild(link);
		}
		if (document.querySelector('script[src*="leaflet.js"]')) {
			var t0 = Date.now();
			var p2 = setInterval(function() {
				if (takeLeaflet()) {
					clearInterval(p2); resolve(LF);
				} else if (gone()) {
					clearInterval(p2); reject(new Error('Leaflet load abandoned'));
				} else if (Date.now() - t0 > 10000) {
					clearInterval(p2); reject(new Error('Leaflet load timeout'));
				}
			}, 100);
			return;
		}
		// The copy the installer verified and put on the router; failing
		// that, the CDN copy pinned by SRI to the same published 1.9.4 hash
		// (this runs with the admin's session, so a tampered copy must be
		// refused rather than executed).
		function add(local) {
			var s = document.createElement('script');
			if (local) s.src = L.resource('qos-ex/leaflet.js');
			else {
				s.src = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js';
				s.integrity   = 'sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=';
				s.crossOrigin = 'anonymous';
			}
			s.async = true;
			s.onload  = function() { takeLeaflet() ? resolve(LF) : reject(new Error('Leaflet failed to load')); };
			s.onerror = function() { s.remove(); local ? add(false) : reject(new Error('Leaflet failed to load')); };
			document.head.appendChild(s);
		}
		add(true);
	});
}

return view.extend({
	data: [],
	thr: 50,
	enabled: false,
	activity: 'idle',
	map: null,
	layerGroup: null,
	fitted: false,

	load: function() {
		// pf_servers already includes an `enabled` field reflecting the live
		// disk-truth — the gating check uses it, and UCI only when the call
		// failed or was busy (h.pfOn in render).
		return Promise.all([
			uci.load('qos-ex'),
			h.rpcSafe(h.callPfServers(), { servers: [] })
		]);
	},

	render: function(loaded) {
		var view = this;
		var pfServers = loaded[1] || {};

		// v1.0.1: when PF is disabled, the Map is still useful as a
		// way to set the home location graphically (right-click).
		// Without this, the user is stuck — they need home set BEFORE
		// they can enable PF, but the typed-coordinate path on
		// Settings is the only other option. Render a stripped-down
		// "setup mode" map: tile layer + home pin + right-click
		// handler, no server markers, no daemon polling.
		// A failed or busy first call must not drop the page into setup mode
		// for good (it then never polled): fall back to UCI (h.pfOn).
		var en = h.pfOn(pfServers);
		view.setupMode = !en;

		view.data     = en ? (pfServers.servers || []) : [];
		// v1.0.1: keep threshold 0 (= ping blocking disabled / visibility
		// only). The old `|| 50` coerced 0 to 50, which made the map slider
		// claim a 50 ms limit when blocking was actually off. parseInt keeps
		// it numeric; only a missing/blank value falls back to 50.
		view.thr      = (function(t) { t = parseInt(t, 10); return isNaN(t) ? 50 : t; })(pfServers.threshold);
		view.enabled  = en;
		view.activity = pfServers.activity  || 'idle';
		view.actPps   = parseInt(pfServers.active_pps, 10) || 20;
		view.playStart = parseInt(pfServers.play_start, 10) || 0;
		view.fitted   = false;
		// Home pin info — null if not yet set. Server returns the literal
		// JSON `null` when home_lat/home_lon are unset; everything else
		// is a number.
		view.homeLat  = (pfServers.home_lat === null || pfServers.home_lat === undefined)
			? null : parseFloat(pfServers.home_lat);
		view.homeLon  = (pfServers.home_lon === null || pfServers.home_lon === undefined)
			? null : parseFloat(pfServers.home_lon);
		if (isNaN(view.homeLat)) view.homeLat = null;
		if (isNaN(view.homeLon)) view.homeLon = null;
		view.homeRadiusKm = parseInt(pfServers.home_radius_km || 1000, 10);
		view.blockMode    = String(pfServers.block_mode || 'ping');
		view.pingCatch   = parseInt(pfServers.ping_catch, 10) || 0;
		if (view.setupMode) view.takeUci();

		var hdr = h.pageHead(_('Ping Filter Map'), 'pf');

		// v1.7.8: the colour key doubles as the layer filter. Each chip
		// owns one state, shows its live count, and toggles that state off
		// the map. Whitelist and blacklist are drawn permanently, so being
		// able to hide the transient states (and see nothing but your own
		// pins) is what keeps a busy map readable.
		view.filters = { allowed: true, blocked: true, cached: true,
			whitelist: true, blacklist: true };
		var legendChips = {};
		var mkChip = function(state, label, dotClass, ringColor) {
			var count = E('span', { 'class': 'pf-legend-count' }, '0');
			var chip = E('button', {
				'class': 'btn cbi-button cbi-button-neutral pf-legend-chip',
				'type': 'button',
				'aria-pressed': 'true',
				// The two pin chips key off the marker RING, not the fill, so
				// the legend says the same thing the map does.
				'style': 'color:' + (ringColor || colorFor(state)),
				'title': _('Show or hide these on the map')
			}, [
				E('span', { 'class': 'pf-legend-dot' + (dotClass ? ' ' + dotClass : '') }),
				E('span', { 'style': 'color:var(--text-color-high, inherit)' }, label),
				count
			]);
			chip.addEventListener('click', function() {
				view.filters[state] = !view.filters[state];
				chip.setAttribute('aria-pressed', view.filters[state] ? 'true' : 'false');
				view.drawMarkers();
			});
			legendChips[state] = { chip: chip, count: count };
			return chip;
		};
		var legend = E('div', { 'class': 'pf-legend' }, [
			mkChip('allowed',   _('allowed'),   ''),
			mkChip('blocked',   _('blocked'),   ''),
			mkChip('whitelist', _('always allowed'), 'ring', ringFor('wl')),
			mkChip('blacklist', _('always blocked'), 'ring', ringFor('bl')),
			mkChip('cached',    _('cached'),    ''),
			E('span', { 'class': 'qos-ex-muted', 'style': 'font-size:11px;margin-left:4px' }, [
				E('span', { 'class': 'pf-badge-connected pf-live' }), ' ', _('playing now')
			])
		]);
		view.legendChips = legendChips;

		var descr = E('div', { 'class': 'qos-ex-muted pf-keyline' },
			_('Right-click: set home · click a server: allow, block, forget'));

		// Map element — fixed size, adjustable via size buttons.
		// In setup mode a cross marks the centre, where Pin home here drops
		// the pin.
		var mapEl = E('div', { 'id': 'pf-map', 'class': view.setupMode ? 'qx-cross' : null }, '');
		var noGeoBadge = E('div', {
			'class': 'qos-ex-muted',
			'style': 'margin:6px 4px;font-size:12px;display:none'
		}, '');
		var mapWrap = E('div', { 'class': 'pf-map-only', 'data-size': 'large' }, [ mapEl, noGeoBadge ]);

		// Map size picker — small / medium / large
		var sizes = [
			['small', _('S')], ['medium', _('M')], ['large', _('L')]
		];
		var sizeBtns = [];
		sizes.forEach(function(pair) {
			var sz = pair[0], lbl = pair[1];
			var btn = E('button', {
				'class': 'btn cbi-button cbi-button-' + (sz === 'large' ? 'action' : 'neutral'),
				'click': function() {
					mapWrap.setAttribute('data-size', sz);
					sizeBtns.forEach(function(b) { b.className = 'btn cbi-button cbi-button-' + ((b.textContent === lbl) ? 'action' : 'neutral'); });
					setTimeout(function() { if (view.map) view.map.invalidateSize(); }, 50);
				}
			}, lbl);
			sizeBtns.push(btn);
		});
		var sizer = E('div', { 'class': 'pf-map-sizer' }, [
			E('span', { 'class': 'qos-ex-muted', 'style': 'font-size:11px' }, _('Map size: '))
		].concat(sizeBtns));

		// v1.0.1: "New game" button — drops the discovered-server cache
		// + flushes the block set so the next scan rebuilds fresh state.
		// Geo cache is preserved (fast repopulation). Use this when
		// switching games (e.g. Fortnite → CoD) to clear the old game's
		// servers from the map without doing a full destructive clear.
		// Whitelist/blacklist UCI lists are NOT touched.
		var newGameBtn = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'style': 'margin-left:12px;font-size:12px',
			'title': _('Clear the quality ladder + discovered servers and re-scan from current traffic. ' +
				'Use when switching games. Always allow / block lists are kept; geo cache is kept too.'),
			'click': ui.createHandlerFn(view, function() {
				if (!confirm(_('Reset the session?\n\n' +
					'Clears the quality ladder, the discovered servers list and the firewall block set, ' +
					'then re-scans current traffic. Use this when switching games.\n\n' +
					'Your always allow / block lists are NOT affected. Geo cache is kept.\n\n' +
					'Continue?'))) return;
				return h.callPfAction('session_reset', '', 0).then(function(res) {
					if (res && res.ok) {
						h.notifyOk(_('Session reset \u2014 rescanning'));
						// Force an immediate refresh; the daemon's scan
						// will have populated by the time this returns.
						setTimeout(function() { view.refetch(); }, 1500);
					} else {
						h.notifyErr(_('Session reset failed'));
					}
				}).catch(function() { h.notifyErr(_('Session reset failed')); });
			})
		}, '\u21bb ' + _('New game'));

		// v1.0.2: "Re-check cache" — re-evaluate every already-discovered
		// server against the CURRENT ping limit / mode without waiting for
		// live traffic, then re-ping them to refine. Lets a ping-limit change
		// (e.g. 50 -> 100ms) flip cached servers allowed/blocked on the map
		// without restarting the game. Newly-blocked live flows are cut via
		// conntrack; whitelist + blacklist are never touched. Distinct from
		// "New game", which throws the cache away — this keeps and re-grades it.
		var recheckBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:8px;font-size:12px',
			'title': _('Re-grade and re-ping every server. Can cut one that fails.'),
			'click': ui.createHandlerFn(view, function() {
				return h.callPfRun('reclassify').then(function(r) {
					var out = (r && r.output) ? r.output : '';
					if (out) {
						h.notifyOk(E('div', {}, [
							E('strong', {}, _('Cache re-checked')),
							E('pre', {
								'style': 'margin:6px 0 0;white-space:pre-wrap;' +
									'font-size:11px;line-height:1.4'
							}, [ out ])
						]));
					} else {
						h.notifyOk(_('Cache re-checked'));
					}
					// Markers recolour once the daemon's next scan reflects the
					// rewritten states; nudge a refresh so it feels immediate.
					setTimeout(function() { view.refetch(); }, 1200);
				}).catch(function() { h.notifyErr(_('Re-check failed')); });
			})
		}, '\u21ba ' + _('Re-check cache'));

		// v1.0.8: live BLOCK-MODE toggle. The map already exposes "Re-check
		// cache" plus live ping-limit and radius sliders, all of which act on
		// COMMITTED uci the instant they're used. Block mode used to be
		// changeable only in the Settings form (staged behind a global
		// "Save & Apply"), so switching to ping there and then hitting
		// Re-check on the map BEFORE applying reclassified against the still-
		// committed "distance" — servers that should have flipped to allowed
		// stayed blocked. This toggle commits immediately (pingfilter mode
		// <m> -> pf_reload -> pf_reclassify), so the recheck/sliders never act
		// on a stale mode. Flipping it also shows/hides the ping vs radius
		// controls to match.
		var modeSel = E('select', {
			'id': 'pf-mode-sel',
			'class': 'cbi-input-select',
			'style': 'font-size:12px;padding:1px 4px'
		}, [
			E('option', { 'value': 'ping' }, _('Ping')),
			E('option', { 'value': 'distance' }, _('Distance'))
		]);
		modeSel.value = (view.blockMode === 'distance') ? 'distance' : 'ping';
		modeSel.addEventListener('change', function() {
			var m = (modeSel.value === 'distance') ? 'distance' : 'ping';
			// Optimistic local flip so the dependent controls react instantly.
			view.blockMode = m;
			view.syncSliders();
			view.drawHome();              // ring style differs ping vs distance
			// Hold poll-sync off the selector while the commit + reload lands.
			view._modeSuppressUntil = Date.now() + 3000;
			h.callPfAction('mode', m, 0).then(function(res) {
				if (res && res.ok) {
					h.notifyOk(m === 'distance'
						? _('Block mode: distance from home')
						: _('Block mode: ping'));
					view.refetch();
				} else {
					h.notifyErr(_('Failed to set block mode'));
				}
			}).catch(function() { h.notifyErr(_('Failed to set block mode')); });
		});
		var modeWrap = E('div', {
			'id': 'pf-mode-wrap',
			'style': 'display:flex;align-items:center;gap:6px;margin-left:12px;font-size:12px'
		}, [
			E('span', { 'class': 'qos-ex-muted' }, _('Mode:')),
			modeSel
		]);

		// The sliders commit like this: 500 ms after the last move, one
		// pf_action, then a refetch (setup mode: UCI again). While one is
		// dragged, and 2.5 s after, the poll leaves it alone (syncSliders).
		function commit(key, verb, n, fail) {
			view['_' + key + 'SuppressUntil'] = Date.now() + 2500;
			clearTimeout(view['_' + key + 'Timer']);
			view['_' + key + 'Timer'] = setTimeout(function() {
				h.callPfAction(verb, '', n).then(function(res) {
					if (!(res && res.ok)) h.notifyErr(fail);
					else if (view.setupMode) view.fromUci(true);
					else view.refetch();
				}).catch(function() { h.notifyErr(fail); });
			}, 500);
		}
		function slider(id, max, step) {
			return E('input', { 'type': 'range', 'min': '0', 'max': String(max), 'step': String(step),
				'id': id, 'style': 'vertical-align:middle;width:160px;max-width:42vw' });
		}
		function wrap(id, label, kids) {
			return E('div', { 'id': id, 'style': 'display:flex;align-items:center;gap:6px;margin-left:12px;font-size:12px' },
				[ E('span', { 'class': 'qos-ex-muted' }, label) ].concat(kids));
		}

		// v1.0.x: live PING-LIMIT SLIDER, ping mode only. Dragging shows the
		// value at once; the commit reclassifies the whole cache against
		// it, so servers flip allowed/blocked on the map within a scan. The
		// rail covers the Settings range (THR_STOPS); 0 = watch only.
		var thrLabel = E('strong', { 'id': 'pf-thr-val' });
		var thrUnit  = E('span', { 'class': 'qos-ex-muted', 'id': 'pf-thr-unit' }, _('ms'));
		var thrSlider = slider('pf-thr-slider', THR_STOPS.length - 1, 1);
		thrSlider.addEventListener('input', function() {
			var ms = THR_STOPS[thrSlider.value | 0];
			view.thr = ms;
			numLabel(thrLabel, thrUnit, ms, _('watch only'));
			commit('thr', 'threshold', ms, _('Failed to set ping limit'));
		});
		var thrWrap = wrap('pf-thr-wrap', _('Ping limit:'), [ thrSlider, thrLabel, thrUnit ]);

		// v1.0.x: live RADIUS SLIDER. In distance mode the ring lets servers
		// in; in ping mode it is only drawn. Dragging redraws the ring at
		// once. Shown once a home exists (setup mode: in Distance only). The
		// rail covers the Settings range (RAD_STOPS); the label shows the
		// true km.
		var radLabel  = E('strong', { 'id': 'pf-rad-val' });
		var radUnit   = E('span', { 'class': 'qos-ex-muted', 'id': 'pf-rad-unit' }, _('km'));
		var radSlider = slider('pf-rad-slider', RAD_STOPS.length - 1, 1);
		radSlider.addEventListener('input', function() {
			var km = RAD_STOPS[radSlider.value | 0];
			radLabel.textContent = String(km);
			view.homeRadiusKm = km;
			view.drawHome();             // live resize of the radius ring
			commit('rad', 'radius', km, _('Failed to set radius'));
		});
		var radWrap = wrap('pf-rad-wrap', _('Radius:'), [ radSlider, radLabel, radUnit ]);

		// Ping Catch slider, Distance only: outside the radius, a server at
		// or under this is let in. 0-250 ms as on Settings; 0 = off.
		var ctcLabel  = E('strong', { 'id': 'pf-ctc-val' });
		var ctcUnit   = E('span', { 'class': 'qos-ex-muted' }, _('ms'));
		var ctcSlider = slider('pf-ctc-slider', 250, 5);
		ctcSlider.addEventListener('input', function() {
			var ms = ctcSlider.value | 0;
			view.pingCatch = ms;
			numLabel(ctcLabel, ctcUnit, ms, _('off'));
			commit('ctc', 'catch', ms, _('Failed to set Ping Catch'));
		});
		var ctcWrap = wrap('pf-ctc-wrap', _('Ping Catch:'), [ ctcSlider, ctcLabel, ctcUnit ]);

		// Phones have no right-click: Pin home here drops the pin at the
		// cross in the middle of the map. The whole world in view centres
		// on 0, 0, which is no home: zoom in first.
		var pinBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action', 'style': 'font-size:12px',
			'click': function() {
				if (!view.map) return;
				if (view.map.getZoom() < 5) { h.notifyErr(_('Zoom in on your home first, then Pin home here')); return; }
				var c = view.map.getCenter().wrap();
				view.saveHome(c.lat, c.lng);
			}
		}, _('Pin home here'));

		// In setup mode there is no daemon: Pin home here and, in Distance,
		// the radius and Ping Catch sliders (they only write UCI then). The
		// map-size picker lives at the bottom of the map in both modes.
		var controls = E('div', {
			'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:8px;margin:4px 0'
		}, view.setupMode ? [ pinBtn, radWrap, ctcWrap ]
			: [ newGameBtn, recheckBtn, modeWrap, thrWrap, radWrap, ctcWrap ]);
		// The sliders apply at once, even mid-match: say so while one is on.
		view.warn = h.pfMatchWarn();

		view.refs = {
			mapEl: mapEl, noGeoBadge: noGeoBadge, legend: legend,
			modeSel: modeSel, modeWrap: modeWrap,
			thrSlider: thrSlider, thrLabel: thrLabel, thrUnit: thrUnit, thrWrap: thrWrap,
			radSlider: radSlider, radLabel: radLabel, radWrap: radWrap,
			ctcSlider: ctcSlider, ctcLabel: ctcLabel, ctcUnit: ctcUnit, ctcWrap: ctcWrap
		};
		view.syncSliders();
		view.renderStats();
		view.warn.qxSet(view.enabled && view.activity === 'active');

		// Wait until the map element has measurable height, then load Leaflet.
		view.waitForMapEl(mapEl).then(function() {
			return loadLeaflet(mapEl);
		}).then(function(L) {
			view.initMap(L);
			view.drawMarkers();
			setTimeout(function() { if (view.map) view.map.invalidateSize(); }, 300);
		}).catch(function(err) {
			dom.content(mapEl, E('div', { 'class': 'qos-ex-err', 'style': 'padding:20px' }, [
				_('Map library missing: this browser must reach unpkg.com.'),
				E('br'), E('span', { 'class': 'qos-ex-muted' }, String(err))
			]));
		});

		// One cadence for the whole app -- LuCI's own poll interval, the
		// way LuCI itself runs every poller. In setup mode too: it only
		// watches for Ping Filter coming on (the page then rebuilds live).
		h.pollWhile(view.refs.mapEl, function() { return view.refetch(); });

		// Setup mode: the setup card above the map, step 2 (home) being
		// this page.
		if (view.setupMode)
			view.setup = h.pfSetup({ sw: true, map: true });
		// v1.0.8: bottom bar under the map — the map-size picker and the
		// legend/help text live here now, so the top of the card is just the
		// action buttons + sliders.
		var bottomBar = E('div', {
			'style': 'display:flex;flex-direction:column;gap:8px;margin-top:10px'
		}, [ sizer, legend, descr ]);

		var mapCard = E('div', { 'class': 'cbi-section qos-ex-card' }, [
			E('h3', { 'class': 'qos-ex-card-title' }, _('QoS-Ex Ping Filter Map')),
			controls,
			view.warn,
			mapWrap,
			bottomBar
		]);

		return E([], [ hdr, view.setupMode ? view.setup : E([]), mapCard ]);
	},

	// Setup mode reads home, mode, radius and catch from UCI: the setup
	// card, the pin and the sliders change them there, and there is no
	// daemon to ask.
	takeUci: function() {
		var c = h.pfUci();
		var la = parseFloat(uci.get('qos-ex', 'pingfilter', 'home_lat'));
		var lo = parseFloat(uci.get('qos-ex', 'pingfilter', 'home_lon'));
		this.homeLat = isNaN(la) || isNaN(lo) ? null : la;
		this.homeLon = isNaN(la) || isNaN(lo) ? null : lo;
		this.blockMode = c.block_mode;
		this.homeRadiusKm = c.home_radius_km;
		this.pingCatch = c.ping_catch;
	},
	// Setup mode, after a change: take UCI again (reload: fetched fresh
	// first, and the setup card repainted), then the sliders and the ring.
	fromUci: function(reload) {
		var view = this, p = Promise.resolve();
		if (reload) {
			uci.unload('qos-ex');
			p = uci.load('qos-ex').catch(function() {});
		}
		return p.then(function() {
			view.takeUci();
			if (reload && view.setup) view.setup.qxPaint();
			view.syncSliders();
			view.drawHome();
		});
	},

	// The sliders and their labels from view.thr / homeRadiusKm /
	// pingCatch, except one being dragged, and which show: the ping limit
	// in ping mode, the radius once home is set (setup mode: in Distance
	// only), Ping Catch in Distance once home is set.
	syncSliders: function() {
		var view = this, r = view.refs, now = Date.now();
		if (!r) return;
		var dist = view.blockMode === 'distance', home = view.homeLat != null && view.homeLon != null;
		if (now > (view._thrSuppressUntil || 0)) {
			var ms = parseInt(view.thr, 10) || 0;
			r.thrSlider.value = String(stopAt(THR_STOPS, ms));
			numLabel(r.thrLabel, r.thrUnit, ms, _('watch only'));
		}
		if (now > (view._radSuppressUntil || 0)) {
			var km = parseInt(view.homeRadiusKm, 10) || 1000;
			r.radSlider.value = String(stopAt(RAD_STOPS, km));
			r.radLabel.textContent = String(km);
		}
		if (now > (view._ctcSuppressUntil || 0)) {
			r.ctcSlider.value = String(view.pingCatch | 0);
			numLabel(r.ctcLabel, r.ctcUnit, view.pingCatch | 0, _('off'));
		}
		r.thrWrap.style.display = dist ? 'none' : 'flex';
		r.radWrap.style.display = home && (dist || !view.setupMode) ? 'flex' : 'none';
		r.ctcWrap.style.display = dist && home ? 'flex' : 'none';
	},

	// A state is plotted unless its legend chip is switched off. Unknown
	// states (a future backend verdict) default to visible rather than
	// silently vanishing from the map.
	stateVisible: function(state) {
		var f = this.filters;
		if (!f || f[state] === undefined) return true;
		return !!f[state];
	},

	waitForMapEl: function(el) {
		return new Promise(function(resolve) {
			var t0 = Date.now();
			(function tick() {
				if (el && el.offsetHeight > 0 && document.body.contains(el)) return resolve();
				if (Date.now() - t0 > 5000) return resolve();
				setTimeout(tick, 50);
			})();
		});
	},

	initMap: function(L) {
		var view = this;
		// v1.1.1.0: pan + zoom, hard-clamped to one world (viscosity 1:
		// drag stops dead at the edge, no bounce, no wrapped copies).
		// Popups never auto-pan the map.
		// v1.1.1.2: the world always fills the box. Min zoom is the
		// fractional level where the 256px world tile spans the box's
		// longer side, so the map edge is the box edge (no grey). Redone
		// on every resize (window, S/M/L); a map sitting at the old floor
		// follows the new one.
		var W = [[-85.0511, -180], [85.0511, 180]];
		view.map = L.map(view.refs.mapEl, {
			center: [20, 0], zoom: 2, zoomSnap: 0,
			maxBounds: W, maxBoundsViscosity: 1.0
		});
		function fillZoom() {
			var sz = view.map.getSize();
			return Math.log(Math.max(sz.x, sz.y, 256) / 256) / Math.LN2;
		}
		view.map.setMinZoom(fillZoom());
		view.map.setView([20, 0], view.map.getMinZoom());
		view.map.on('movestart zoomstart', function() { view.mapBusy = true; });
		view.map.on('moveend zoomend', function() { view.mapBusy = false; });
		view.map.on('resize', function() {
			var floor = view.map.getZoom() <= view.map.getMinZoom() + 0.01;
			view.map.setMinZoom(fillZoom());
			if (floor) view.map.setZoom(view.map.getMinZoom());
		});
		// OpenStreetMap tiles; CARTO's when those fail (blocked or down)
		// before any has loaded.
		var TILES = [
			[ 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', '\u00a9 OpenStreetMap contributors' ],
			[ 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png', '\u00a9 OpenStreetMap contributors \u00a9 CARTO' ]
		];
		(function tiles(i) {
			var loaded = false, gone = false, failed = 0;
			var t = L.tileLayer(TILES[i][0], { attribution: TILES[i][1], maxZoom: 18, noWrap: true, bounds: W });
			t.on('tileload', function() { loaded = true; });
			t.on('tileerror', function() {
				if (gone || loaded || ++failed < 4 || i + 1 >= TILES.length) return;
				gone = true;
				view.map.removeLayer(t);
				tiles(i + 1);
			});
			t.addTo(view.map);
		})(0);
		view.layerGroup = L.layerGroup().addTo(view.map);
		// Separate layer for the home pin + radius circle: drawHome() clears
		// and redraws it alone, never the cached server markers on layerGroup.
		view.homeLayer = L.layerGroup().addTo(view.map);

		// Delegated click handler for popup action buttons.
		view.refs.mapEl.addEventListener('click', function(ev) {
			var b = ev.target;
			if (!b || b.tagName !== 'BUTTON') return;
			var verb = b.getAttribute('data-pf-action');
			var ip   = b.getAttribute('data-pf-ip');
			if (!verb || !ip) return;
			ev.preventDefault();
			view.runAction(verb, ip, b);
		});

		// The ungeolocated-pin tray is a SIBLING of the map element, not a
		// child, so the handler above never sees its Locate buttons.
		if (view.refs.noGeoBadge) {
			view.refs.noGeoBadge.addEventListener('click', function(ev) {
				var b = ev.target;
				if (!b || b.tagName !== 'BUTTON') return;
				var verb = b.getAttribute('data-pf-action');
				var ip   = b.getAttribute('data-pf-ip');
				if (!verb || !ip) return;
				ev.preventDefault();
				view.runAction(verb, ip, b);
			});
		}

		// v1.1.1.3: open toward the free space -- below a marker in the top
		// half of the map, above it (Leaflet default) in the bottom half.
		view.map.on('popupopen', function(e) {
			var el = e.popup.getElement();
			if (!el) return;
			var y = view.map.latLngToContainerPoint(e.popup.getLatLng()).y;
			el.classList.toggle('pf-pop-below', y < view.map.getSize().y / 2);
		});

		// Right-click anywhere on the map: drop or move home pin here.
		// (Phones: Pin home here while Ping Filter is off, or type lat/lon
		// on the Ping Filter Settings tab.)
		view.map.on('contextmenu', function(ev) {
			view.saveHome(ev.latlng.lat, ev.latlng.lng);
		});

		view.drawHome();
	},

	// Render (or update) the home pin + radius circle. Called from initMap
	// once at startup, and again from refetch() each poll cycle so the
	// circle reflects radius/mode changes made on the Ping Filter Settings tab without
	// requiring a page reload.
	drawHome: function() {
		var view = this;
		if (!view.map || !view.homeLayer || !LF) return;
		var L = LF;
		view.homeLayer.clearLayers();

		// No home set → nothing to draw.
		if (view.homeLat == null || view.homeLon == null) return;

		// Always draw the radius circle: in distance mode it decides (solid,
		// the app's accent), in ping mode it is only drawn (dashed, muted).
		// Blue stays for the match in play.
		var radiusM = (view.homeRadiusKm || 1000) * 1000;
		var isDistMode = (view.blockMode === 'distance');
		var ringC = isDistMode ? themeColor('--qx-acc', '#087a68') : themeColor('--text-color-medium', '#808080');
		var circle = L.circle([view.homeLat, view.homeLon], {
			radius: radiusM,
			color: ringC,
			weight: isDistMode ? 2 : 1,
			dashArray: isDistMode ? null : '6 4',
			fillColor: ringC,
			fillOpacity: isDistMode ? 0.06 : 0.04,
			interactive: false
		});
		circle.addTo(view.homeLayer);

		// Home marker — clean restart.
		//
		// The previous home pin used an L.divIcon (an HTML <div> containing an
		// inline SVG). A divIcon needs its container forced transparent or it
		// shows a box; despite three layers of defence (CSS class, cache-busted
		// stylesheet, inline !important styles) it kept rendering as a dark box
		// with the house inside it whenever any of those defences lost the race
		// (stale CSS cache, getElement() timing, etc.).
		//
		// The fix is to stop using a divIcon entirely. A circleMarker — exactly
		// what every server marker below already uses — is a plain SVG <circle>
		// painted directly into Leaflet's shared overlay pane. There is NO HTML
		// container element, so there is nothing that can ever take a background
		// and become a box. It reads clearly on both light and dark tiles, needs
		// no custom CSS, and stays put when the map zooms.
		//
		// Home marker — a small black dot with a thin white ring so it
		// stays legible on both light and dark tiles. Right-click to remove;
		// right-click empty map to relocate.
		var marker = L.circleMarker([view.homeLat, view.homeLon], {
			radius: 5,
			color: '#ffffff',
			weight: 1.5,
			fillColor: '#000000',
			fillOpacity: 1,
			title: _('Home — right-click to remove, right-click empty map to relocate'),
			pane: 'markerPane'
		});

		marker.bindPopup(
			'<div class="pf-popup">' +
			'<div class="pf-popup-head"><strong>' + _('Home') + '</strong></div>' +
			'<div>' + view.homeLat.toFixed(4) + ', ' + view.homeLon.toFixed(4) + '</div>' +
			'<div>' + _('Radius:') + ' <code>' + escHtml(view.homeRadiusKm) + ' km</code></div>' +
			'<div>' + _('Mode:') + ' <code>' + escHtml(view.blockMode) + '</code></div>' +
			'<div class="pf-popup-src">' +
			_('Right-click the pin to remove it, or the map to move it.') +
			'</div></div>',
			{ minWidth: 220, autoPan: false }
		);
		// Right-click the marker itself to remove the home pin.
		// L.DomEvent.stopPropagation prevents the contextmenu from bubbling
		// up to the map handler (which would re-create the pin at the click).
		marker.on('contextmenu', function(ev) {
			L.DomEvent.stopPropagation(ev);
			view.clearHome();
		});
		marker.addTo(view.homeLayer);
	},

	// Persist home pin coords to UCI + reload daemon. Debounced.
	saveHome: function(lat, lon) {
		var view = this;
		// Optimistic local update.
		view.homeLat = lat; view.homeLon = lon;
		view.drawHome();
		// The Radius slider shows the moment a home exists.
		view.syncSliders();

		clearTimeout(view._homeSaveTimer);
		view._homeSaveTimer = setTimeout(function() {
			h.callPfSetHome(String(lat.toFixed(6)), String(lon.toFixed(6)),
				view.homeRadiusKm || 0, view.blockMode || ''
			).then(function(res) {
				if (res && res.ok) {
					h.notifyOk(_('Home pin saved'));
					// Setup mode: step 3 is done and the switch may turn on.
					if (view.setupMode) view.fromUci(true);
				} else {
					h.notifyErr(_('Failed to save home pin'));
				}
			}).catch(function() {
				h.notifyErr(_('Failed to save home pin'));
			});
		}, 400);
	},

	// Clear the home pin: blank lat/lon in UCI and redraw.
	clearHome: function() {
		var view = this;
		view.homeLat = null; view.homeLon = null;
		view.drawHome();
		view.syncSliders();

		clearTimeout(view._homeSaveTimer);
		h.callPfSetHome('', '', view.homeRadiusKm || 0, view.blockMode || ''
		).then(function(res) {
			if (res && res.ok) {
				h.notifyOk(_('Home pin removed'));
				if (view.setupMode) view.fromUci(true);
			} else {
				h.notifyErr(_('Failed to remove home pin'));
			}
		}).catch(function() {
			h.notifyErr(_('Failed to remove home pin'));
		});
	},

	// The playing dot's pulse: the ring grows out and fades while the glow
	// under the dot swells. Styled here frame by frame, not with CSS
	// animation -- reduced-motion settings and theme resets switch those
	// off. It holds still while the map is being moved or zoomed, and
	// stops by itself when nothing is played or the map has left the page.
	pulse: function() {
		var view = this, p = view.play, el = view.halo && view.halo.getElement();
		if (!p || !el || !document.body.contains(view.map.getContainer())) { view.pulseOn = false; return; }
		if (!view.mapBusy) {
			var t = (Date.now() % p.ms) / p.ms, ring = el.firstChild.style, glow = el.lastChild.style;
			ring.transform = 'scale(' + (1 + 2.45 * t).toFixed(3) + ')';
			ring.opacity = (0.9 * (1 - t)).toFixed(3);
			glow.transform = 'scale(' + (1 + 0.55 * Math.sin(Math.PI * t)).toFixed(3) + ')';
		}
		requestAnimationFrame(function() { view.pulse(); });
	},

	drawMarkers: function() {
		var view = this;
		if (!view.map || !view.layerGroup || !LF) return;
		var L = LF;
		var bounds = [];
		var noGeoCount = 0;
		// v1.7.8: pins with no coordinates yet get their own tray with a
		// per-IP Locate button, instead of vanishing silently.
		var noGeoPins = [];
		if (!view.markers) view.markers = {};

		// v1.0.1: UDP-only, location-grouped rendering. Rows at the
		// same 1-decimal lat/lon cell (~11km, roughly one DC) collapse
		// into a single marker; the popup lists all IPs at that
		// location with their individual state + ping.
		var groups = {};
		var shown = h.pfVisible(view.data, view.playStart);
		for (var i = 0; i < shown.length; i++) {
			var r = shown[i];
			// Servers seen since play began stay plotted until Ping Filter has
			// been idle for map_keep (default 1 h; play_start 0 = closed),
			// independent of the 1 h ipset expiry. PINS are different: a manual
			// whitelist/blacklist entry is an explicit, durable statement of
			// intent, so it is drawn whether or not packets are flowing.
			// pf_servers_json hardcodes expiry_remaining = 0 for its W/L
			// canon rows (only the A/B ipset tags carry an expiry), so the
			// old liveness test dropped every pin that was not mid-game.
			// h.pfVisible applies that rule -- the same rows the Servers
			// page lists.
			if (!view.stateVisible(r.state)) continue;
			var lat = parseFloat(r.lat) || 0;
			var lon = parseFloat(r.lon) || 0;
			// No geolocation yet: keep the server in the Servers page's
			// list (rendered separately from view.data), but do NOT plot it.
			// Previously these were given a synthetic South-Atlantic coordinate
			// and drawn as dashed markers, which read as servers sitting "in
			// the sea". The list is the right home for them until geo resolves.
			if (!h.pfLocated(r)) {
				noGeoCount++;
				// A pin with no coordinates can NEVER appear on the map, so
				// it needs a visible home. The daemon backfills these on idle
				// ticks (PF 2.7.5); Locate forces one immediately.
				if (r.state === 'whitelist' || r.state === 'blacklist') noGeoPins.push(r);
				continue;
			}
			var key = lat.toFixed(1) + ',' + lon.toFixed(1);
			if (!groups[key]) groups[key] = { lat: lat, lon: lon, rows: [] };
			groups[key].rows.push(r);
		}

		// The server being played right now (null when not in a match).
		var playIp = h.liveIp(view, view.data, view.actPps);
		var playAt = null;

		view.markerCount = 0;
		view.udpServerCount = 0;
		view.locationCount = 0;
		// Pass token: markers still bearing the previous token at the end
		// of this pass no longer have a location cell and are removed.
		view.drawPass = (view.drawPass | 0) + 1;

		for (var k in groups) {
			if (!Object.prototype.hasOwnProperty.call(groups, k)) continue;
			var g = groups[k];
			view.locationCount++;
			view.udpServerCount += g.rows.length;

			// Pick a "primary" row to define the marker's visual state:
			// prefer connected → blocked → allowed → cached.
			var primary = g.rows[0];
			// anyConnected drives popup wording + primary preference;
			// anyPlaying drives the PULSE: the cell holding the server the
			// Dashboard's Now playing card shows (h.liveIp, same picker). A
			// PSN keepalive is "connected" but you are not playing on it,
			// so it must not pulse like the live game server does.
			var anyConnected = false, anyPlaying = false;
			for (var j = 0; j < g.rows.length; j++) {
				var rr = g.rows[j];
				var conn = (rr.connected === true || rr.connected === 'true');
				if (conn && !anyConnected) { primary = rr; anyConnected = true; }
				if (!anyPlaying && playIp && rr.ip === playIp) { primary = rr; anyPlaying = true; }
			}
			if (!anyConnected) {
				var order = { 'blocked': 0, 'blacklist': 0, 'allowed': 1, 'whitelist': 1, 'cached': 2 };
				g.rows.sort(function(a, b) {
					return (order[a.state] || 3) - (order[b.state] || 3);
				});
				primary = g.rows[0];
			}

			// Pin-ness is a property of the GROUP, not of `primary`. The
			// 1dp cell (~11 km) routinely collapses a pinned IP and a plain
			// discovered IP from the same datacenter into one marker, so
			// reading the pin off whichever row happened to sort first made
			// the ring style a coin toss.
			var hasWl = false, hasBl = false;
			for (var m = 0; m < g.rows.length; m++) {
				var pkr = pinKindOf(g.rows[m].state);
				if      (pkr === 'wl') hasWl = true;
				else if (pkr === 'bl') hasBl = true;
			}
			// Blacklist wins when one cell holds both: "you have explicitly
			// blocked something here" is the louder fact.
			var pin = hasBl ? 'bl' : (hasWl ? 'wl' : '');
			// FILL stays quality/verdict, RING carries the pin. The 1dp cell
			// (~11 km) routinely collapses a pinned IP together with freshly
			// discovered neighbours from the same datacenter; recolouring the
			// whole dot by list membership hid the fact that those neighbours
			// are graded perfectly well.
			var color = colorFor(primary.state);
			// A solid dot with a white edge; a pinned one wears its thicker
			// white / black ring instead.
			var ring  = ringFor(pin) || '#ffffff';

			var live = anyConnected || (primary.expiry_remaining_sec | 0) > 0;
			var classes = [];
			if (!anyConnected && !pin && primary.state === 'cached')
				classes.push('pf-marker-cached');
			var style = {
				radius: anyPlaying ? 11 : (g.rows.length > 1 ? 9 : 7),
				color: ring,
				weight: pin ? 3.5 : 1.5,
				fillColor: color,
				fillOpacity: live ? 1 : 0.75,
				// dashArray must still be set explicitly: it is a Leaflet path
				// option, and setStyle only clears what it is given.
				dashArray: null,
				className: classes.join(' ')
			};

			// v1.7.8: reuse the marker for this cell and mutate it. The old
			// clearLayers()-and-rebuild destroyed any OPEN popup on every
			// poll and restarted the pulse animation mid-cycle.
			var marker = view.markers[k];
			if (!marker) {
				marker = L.circleMarker([g.lat, g.lon], style);
				marker.bindPopup('', { minWidth: 260, maxWidth: 300, autoPan: false });
				marker.addTo(view.layerGroup);
				marker.__qosExHtml = '';
				view.markers[k] = marker;
			} else {
				marker.setStyle(style);
			}
			marker.__qosExSeen = view.drawPass;
			// Traffic to a BLACKLISTED server means the block is not holding
			// (a set-add hiccup): it pulses fast, as an alarm.
			if (anyPlaying) playAt = { ll: [g.lat, g.lon], color: pin ? ring : color, ms: pin === 'bl' ? 900 : 1600 };
			// Leaflet's setStyle() merges options -- INCLUDING className --
			// but only applies className in _initPath, i.e. once, at
			// creation. A reused marker would therefore keep whatever
			// pulse class it was born with, and a server that started
			// playing would never light up. Sync the SVG node directly.
			var mpath = marker._path;
			if (mpath && mpath.classList) {
				PULSE_CLASSES.forEach(function(c) {
					if (classes.indexOf(c) >= 0) mpath.classList.add(c);
					else mpath.classList.remove(c);
				});
			}
			var popHtml = view.buildGroupPopupHtml(g.rows, anyConnected, pin);
			// Defer the swap while the user is inside the popup: keyboard
			// focus, an in-flight action or a live selection all die on
			// replace. Unchanged HTML is skipped outright.
			if (popHtml !== marker.__qosExHtml && !popupBusy(marker)) {
				marker.__qosExHtml = popHtml;
				marker.setPopupContent(popHtml);
			}
			bounds.push([g.lat, g.lon]);
			view.markerCount++;
		}

		// Prune: a cached marker whose cell produced no group this pass
		// (server aged out, pin removed, legend chip switched off).
		for (var mk in view.markers) {
			if (!Object.prototype.hasOwnProperty.call(view.markers, mk)) continue;
			if (view.markers[mk].__qosExSeen === view.drawPass) continue;
			view.layerGroup.removeLayer(view.markers[mk]);
			delete view.markers[mk];
		}

		// The pulse of the dot being played on: a ring that grows out of it
		// and a glow that swells under it, animated by view.pulse(). It is
		// one small HTML marker (.pf-pulse, two 22px circles) in its own
		// pane under the dots -- NOT vector shapes: a map-sized SVG redrawn
		// every frame made the dots flash (1.2.7.1) and then blanked the
		// map (1.2.7.2) on some graphics cards. Non-interactive, so the dot
		// keeps its popup.
		view.play = playAt;
		if (playAt) {
			if (!view.halo) {
				if (!view.map.getPane('pfPulse')) view.map.createPane('pfPulse').style.zIndex = 390;
				view.halo = L.marker(playAt.ll, { pane: 'pfPulse', interactive: false, keyboard: false,
					icon: L.divIcon({ className: 'pf-pulse', html: '<i></i><b></b>', iconSize: [ 0, 0 ] }) }).addTo(view.map);
			}
			view.halo.setLatLng(playAt.ll).getElement().style.color = playAt.color;
			if (!view.pulseOn) { view.pulseOn = true; view.pulse(); }
		} else if (view.halo) {
			view.map.removeLayer(view.halo);
			view.halo = null;
		}

		// Map summary line:
		// - how many UDP servers visible + at how many locations
		// - how many UDP rows have no geo (in list but not on map)
		if (view.refs && view.refs.noGeoBadge) {
			var parts = [];
			parts.push('<strong>' + view.udpServerCount + '</strong> ' +
				_('UDP server') + (view.udpServerCount === 1 ? '' : 's') +
				_(' at ') + '<strong>' + view.locationCount + '</strong> ' +
				_('location') + (view.locationCount === 1 ? '' : 's'));
			var plainNoGeo = noGeoCount - noGeoPins.length;
			if (plainNoGeo > 0) {
				parts.push(plainNoGeo + ' ' +
					_('not located yet \u2014 on Servers, not on the map'));
			}
			var trayHtml = parts.join(' \u00b7 ');
			if (noGeoPins.length) {
				// A pin with no coordinates can never appear on the map, so
				// name it here instead of burying it in a count. Locate forces
				// the lookup the daemon would otherwise do on an idle tick.
				trayHtml += '<div style="margin-top:4px">' +
					_('Pinned, not yet located:') + ' ';
				for (var q = 0; q < noGeoPins.length && q < 12; q++) {
					var pr = noGeoPins[q];
					var pesc  = escHtml(pr.ip);
					// pr.state lands in a class attribute AND in text; it was
					// the one interpolation here that went out unescaped.
					var sesc  = escHtml(pr.state);
					trayHtml += '<span class="pf-nogeo-pin">' +
						'<span class="label pf-badge ' + sesc + '">' + sesc +
						'</span> <code>' + pesc + '</code>' +
						'<button class="btn cbi-button cbi-button-neutral pf-popup-btn" data-pf-action="locate" ' +
						'data-pf-ip="' + pesc + '">' + _('Locate') + '</button>' +
						'</span>';
				}
				if (noGeoPins.length > 12)
					trayHtml += '<span class="qos-ex-muted">+' +
						(noGeoPins.length - 12) + '</span>';
				trayHtml += '</div>';
			}
			view.refs.noGeoBadge.style.display = '';
			view.refs.noGeoBadge.innerHTML = trayHtml;
		}

		// v1.0.1: do NOT auto-fitBounds when servers appear. Previously
		// this snapped the view in to ~Europe on first scan, which the
		// user found jarring. Keep whatever zoom/center the user has
		// scrolled to (initial view comes from initMap: the whole world,
		// centred on 20, 0, at the smallest zoom that fills the box).
		// If they want to see all markers, they can pinch-to-fit
		// themselves.
	},

	// v1.0.2: location-grouped popup. When multiple UDP servers share
	// the same 1dp lat/lon cell (i.e. same datacenter), they collapse
	// to one marker — this builds the stacked popup that lists every
	// IP at that location with its state, ping, and a per-IP action row.
	buildGroupPopupHtml: function(rows, anyConnected, groupPin) {
		var esc = escHtml;
		var view = this;
		var primary = rows[0];
		var loc = (primary.country || primary.city)
			? esc((primary.city || '') + (primary.city && primary.country ? ', ' : '') + (primary.country || ''))
			: '?';
		// Distance is a PER-SERVER fact and is rendered on each row below.
		// It used to sit up here on the group header, where one number stood
		// in for every IP in the cell and read like a total.
		var home = (view.homeLat != null && view.homeLon != null)
			? { lat: parseFloat(view.homeLat), lon: parseFloat(view.homeLon) }
			: null;
		var header =
			'<div style="margin-bottom:6px">' +
				'<strong>' + loc + '</strong>' +
				'<div class="qos-ex-muted" style="font-size:11px">' +
				rows.length + _(' server') + (rows.length > 1 ? 's' : '') +
				'</div>' +
			'</div>';
		// A blacklisted cell that is carrying traffic is the one thing on
		// this map worth interrupting the user for.
		if (groupPin === 'bl' && anyConnected) {
			header = '<div style="margin-bottom:6px;font-weight:700;color:var(--error-color-high, #c43c35)">' +
				_('Blocked, but traffic is flowing') +
				'</div>' + header;
		}
		if (anyConnected) {
			header = '<div><span class="pf-badge-connected"></span> <strong>' +
				_('Currently connected') + '</strong></div>' + header;
		}

		// Measured = icmp (old rows: real). udp/tcp rows predate the
		// ICMP-only probe and count as unmeasured, exactly as the backend
		// treats them. Ping Catch (distance mode) takes the measurement,
		// else the estimate.
		var sourceTitle = {
			'real':     _('Source: measured ICMP round trip'),
			'icmp':     _('Source: measured ICMP round trip'),
			'udp':      _('Stale reading from a retired probe \u2014 counts as unmeasured'),
			'tcp':      _('Stale reading from a retired probe \u2014 counts as unmeasured'),
			'pending':  _('Not measured yet')
		};

		var PF_POPUP_MAX_ROWS = 4;
		var rowsHtml = '';
		for (var i = 0; i < rows.length; i++) {
			var r = rows[i];
			var ipEnc  = esc(r.ip);
			var fam6   = (r.fam === 'v6') ? ' <span class="label pf-fam6" title="IPv6 server">v6</span>' : '';
			var src = r.ping_src || r.ping_source;
			var pTxt;
			if (src === 'pending') pTxt = '\u2026';        // measuring
			else if (r.ping > 0)   pTxt = r.ping + 'ms';
			else                   pTxt = '\u2014';
			var pingTitleAttr = sourceTitle[src]
				? ' title="' + esc(sourceTitle[src]) + '"'
				: '';
			var stateBadge = '<span class="label pf-badge ' + esc(r.state) + '">' +
				esc(r.state) + '</span>';
			var isConn = (r.connected === true || r.connected === 'true');
			var connDot = isConn
				? '<span class="pf-badge-connected' + (r.ip === view._liveIp ? ' pf-live' : '') +
				  '" style="margin-right:3px"></span>'
				: '';
			// Second line: the telemetry the map used to throw away even
			// though every field already arrives in the pf_servers feed.
			// Score only for servers actually played (graded sessions, i.e.
			// on the Quality ladder) -- anything else has nothing to score.
			var meta = [];
			if (r.gname) meta.push(esc(r.gname));
			if ((r.hist_sessions | 0) > 0) {
				var sc = h.score(r);
				meta.push(_('grade') + ' <strong class="qx-gtxt ' + h.scoreBand(sc) + '" title="' +
					_('Score %d').format(sc) + '">' + h.grade(sc) + '</strong>');
			}
			var jv = (r.hist_jitter > 0) ? r.hist_jitter
				: ((r.jitter_live > 0) ? r.jitter_live : 0);
			if (jv > 0) meta.push(_('jitter') + ' ' + jv + ' ms');
			// This server's own distance from the home pin -- the same
			// h.haversineKm the server detail rows and the catch tag use, so
			// they can never disagree. Shown in both ping and distance mode:
			// it needs only a home pin, not a radius.
			if (home && r.lat && r.lon) {
				var rkm = h.haversineKm(home.lat, home.lon,
					parseFloat(r.lat), parseFloat(r.lon));
				if (rkm >= 0) meta.push(rkm + ' km');
			}
			if ((r.hist_sessions | 0) > 0)
				meta.push((r.hist_sessions | 0) + ' ' + _('sessions'));
			if (pinKindOf(r.state))
				meta.push(_('pinned manually'));
			else if ((r.expiry_remaining_sec | 0) > 0)
				meta.push(_('expires in') + ' ' +
					Math.max(1, Math.round(r.expiry_remaining_sec / 60)) + ' m');
			// One control per list. Already on that list -> it renders
			// pressed and unpins, so the button never silently no-ops.
			var onW = (r.state === 'whitelist'), onB = (r.state === 'blacklist');
			var listBtn = function(on, label, verb, title) {
				return '<button class="btn cbi-button cbi-button-neutral pf-popup-btn" ' +
					'aria-pressed="' + (on ? 'true' : 'false') + '" ' +
					'data-pf-action="' + (on ? 'forget' : verb) + '" ' +
					'data-pf-ip="' + ipEnc + '" title="' + title + '">' +
					label + '</button>';
			};
			rowsHtml +=
				'<div class="pf-prow"><div class="pf-prow-l">' +
					'<span class="pf-prow-ip">' + connDot + '<code>' + ipEnc + '</code>' + fam6 + '</span>' +
					stateBadge +
					'<span class="pf-prow-ms"' + pingTitleAttr + '>' + pTxt + '</span>' +
					'<span class="pf-prow-btns">' +
						listBtn(onW, 'A', 'whitelist',
							onW ? _('Remove from always allowed') : _('Always allow')) +
						listBtn(onB, 'B', 'blacklist',
							onB ? _('Remove from always blocked') : _('Always block')) +
					'</span>' +
				'</div><div class="pf-prow-m qos-ex-muted">' +
					meta.join(' \u00b7 ') +
				'</div></div>';
		}
		// A cluster marker can cover dozens of servers, and Leaflet sizes a
		// popup to its content — past a handful of rows the popup outgrows the
		// map itself and the actions at the bottom become unreachable. Above
		// PF_POPUP_MAX_ROWS the list becomes its own scroller.
		//
		// Rows are a fixed 46px (.pf-prow), so max-height = rows x 46 always
		// cuts BETWEEN rows: a half-row at the fold reads as a rendering fault.
		if (rows.length > PF_POPUP_MAX_ROWS) {
			rowsHtml = '<div class="pf-popup-scroll" style="max-height:' +
				(PF_POPUP_MAX_ROWS * 46) + 'px">' + rowsHtml + '</div>' +
				'<div class="pf-popup-src qos-ex-muted" style="font-size:11px">' +
					PF_POPUP_MAX_ROWS + ' ' + _('of') + ' ' + rows.length +
					' \u00b7 ' + _('scroll for more') +
				'</div>';
		}
		return header + rowsHtml;
	},

	runAction: function(verb, ip, btn) {
		var view = this;
		var orig = btn ? btn.textContent : null;
		if (btn) { btn.disabled = true; btn.textContent = '\u2026'; }
		// `locate` is not a list operation: it forces the geo lookup the
		// daemon would otherwise do on an idle tick, so a pin the user just
		// added can reach the map without waiting. Different rpc object
		// method (pf_run/geo_check), so it short-circuits here.
		if (verb === 'locate') {
			h.callPfRun('geo_check', ip).then(function(res) {
				if (btn) { btn.disabled = false; btn.textContent = orig; }
				var txt = (res && (res.stdout || res.text || res.output)) || '';
				// The daemon writes the geo cache as a side effect of the
				// lookup; the next poll picks the coordinates up.
				// Judge ONLY the final pf_geo_lookup line: the report always
				// contains the word "lat" and digits (reach-test URLs), so the
				// old test said "Located" for every failed lookup too.
				// pf_geo_lookup prints "lat<TAB>lon<TAB>co<TAB>ci"; a miss is
				// "0<TAB>0". Both coordinates 0 = not located.
				var gm = /lat lon country city:[ \t]*(-?[0-9.]+)[ \t]+(-?[0-9.]+)/.exec(txt);
				if (gm && (parseFloat(gm[1]) !== 0 || parseFloat(gm[2]) !== 0))
					h.notifyOk(_('Located') + ' \u2713 ' + ip);
				else
					h.notifyErr(_('No location found for') + ' ' + ip);
				view.refetch();
			}).catch(function() {
				if (btn) { btn.disabled = false; btn.textContent = orig; }
				h.notifyErr(_('Lookup failed for') + ' ' + ip);
			});
			return;
		}
		h.callPfAction(verb, ip, 0).then(function(res) {
			if (btn) { btn.disabled = false; btn.textContent = orig; }
			if (res && res.ok) {
				h.notifyOk(verb + ' \u2713 ' + ip);
				if (view.map && view.map.closePopup) view.map.closePopup();
				view.refetch();
			} else {
				h.notifyErr(verb + ' ' + _('failed') + ': ' + ip);
			}
		}).catch(function() {
			if (btn) { btn.disabled = false; btn.textContent = orig; }
			h.notifyErr(verb + ' ' + _('failed') + ': ' + ip);
		});
	},

	// The legend chips' counts, so the filter shows what it would hide
	// before you click it. Counted over the servers shown (h.pfVisible),
	// so the legend reads the same as the chips on the Servers page.
	renderStats: function() {
		var view = this;
		if (!view.legendChips) return;
		var shown = h.pfVisible(view.data, view.playStart);
		var lc = { allowed: 0, blocked: 0, cached: 0, whitelist: 0, blacklist: 0 };
		for (var n = 0; n < shown.length; n++) {
			var st = shown[n].state;
			if (lc[st] !== undefined) lc[st]++;
		}
		for (var ck in lc) {
			if (!Object.prototype.hasOwnProperty.call(lc, ck)) continue;
			if (view.legendChips[ck])
				view.legendChips[ck].count.textContent = String(lc[ck]);
		}
	},

	refetch: function() {
		var view = this;
		return h.callPfServers().then(function(j) {
			// A stand-in reply (failed / busy call) changes nothing; Ping
			// Filter turned on or off rebuilds the page for that state.
			if (!h.pfReal(j)) return;
			h.pfFlip(view, j, !view.setupMode);
			if (view.setupMode) return;
			if (Array.isArray(j.servers))                                    view.data     = j.servers;
			if (typeof j.threshold !== 'undefined' && j.threshold !== null)  view.thr      = parseInt(j.threshold, 10) || 0;
			if (typeof j.enabled   !== 'undefined') view.enabled  = (j.enabled === 1 || j.enabled === '1');
			if (typeof j.activity  !== 'undefined') view.activity = j.activity;
			if (typeof j.active_pps !== 'undefined') view.actPps  = parseInt(j.active_pps, 10) || 20;
			view.playStart = parseInt(j.play_start, 10) || 0;

			// Home pin, mode, radius and catch: re-read so changes made on
			// the Settings tab or the Dashboard reach the map without a page
			// reload. A value whose slider is being dragged keeps the drag's.
			var now = Date.now();
			var hl = (j.home_lat === null || j.home_lat === undefined) ? null : parseFloat(j.home_lat);
			var hg = (j.home_lon === null || j.home_lon === undefined) ? null : parseFloat(j.home_lon);
			if (isNaN(hl)) hl = null;
			if (isNaN(hg)) hg = null;
			var hr = parseInt(j.home_radius_km || 1000, 10);
			if (now < (view._radSuppressUntil || 0)) hr = view.homeRadiusKm;
			var bm = String(j.block_mode || 'ping');
			var changed = (hl !== view.homeLat || hg !== view.homeLon ||
			               hr !== view.homeRadiusKm || bm !== view.blockMode);
			view.homeLat = hl; view.homeLon = hg;
			view.homeRadiusKm = hr; view.blockMode = bm;
			if (now > (view._ctcSuppressUntil || 0)) view.pingCatch = parseInt(j.ping_catch, 10) || 0;

			// Keep the Block-mode selector in step with the backend, unless the
			// user just changed it and the commit/reload is still in flight.
			if (view.refs && view.refs.modeSel) {
				if (!view._modeSuppressUntil || Date.now() > view._modeSuppressUntil) {
					var msel = (bm === 'distance') ? 'distance' : 'ping';
					if (view.refs.modeSel.value !== msel)
						view.refs.modeSel.value = msel;
				}
			}
			view.syncSliders();
			view.warn.qxSet(view.enabled && view.activity === 'active');

			view.renderStats();
			view.drawMarkers();
			if (changed) view.drawHome();
		}).catch(function() {});
	},

	handleSave: null, handleSaveApply: null, handleReset: null
});
