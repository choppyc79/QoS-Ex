'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require view.qos-ex._helpers as h';

// Maintenance (Network > QoS-Ex > System > Maintenance): versions and
// updates from GitHub, diagnostics (the debug report for a problem report,
// flow offloading off), the settings backup, and the danger zone (reset to
// defaults, uninstall). No Save & Apply: each control acts at once.

return view.extend({
	// Live replies, not the last-known ones (h.loadC): this page renders
	// once, and after Update now it reloads to show the new versions.
	// The config is for h.pageHead's check of the menu this browser tab
	// kept; the page opens without it.
	load: function() {
		return Promise.all([
			h.rpcSafe(h.callState()),
			h.rpcSafe(h.callPfStatus(), {}),
			uci.load('qos-ex').catch(function() { return null; })
		]);
	},

	render: function(loaded) {
		var self = this;
		var st = h.parseState((loaded[0] && loaded[0].output) || '').state;
		var pf = h.parseState((loaded[1] && loaded[1].output) || '').state;

		// ----------------------------------------------------------------
		// Diagnostics: sanitized debug report + flow-offload guard. Everything
		// renders INSIDE the panel below — no modal popups. The report streams
		// into checkPre; Copy uses clipboard API with execCommand fallback.
		// (Service control lives on the Overview, beside Now playing.)
		// ----------------------------------------------------------------
		var checkPre = E('pre', { 'class': 'qos-ex-pre', 'style': 'max-height:340px' },
			_('(press Generate debug report)'));

		// All buttons disable while a call is in flight and the panel shows a
		// busy line, so it's obvious something is happening (the calls are
		// fast, so previously the output looked unchanged).
		var btnGen, btnCopy, btnForum, btnSave, btnOff;
		function setBusy(on, msg) {
			[ btnGen, btnCopy, btnForum, btnSave, btnOff ].forEach(function(b) {
				if (b) b.disabled = !!on;
			});
			if (on && msg) checkPre.textContent = msg;
		}

		// Generate the sanitized debug report (qos-ex.sh debug). Read-only —
		// nothing on the router is changed. The backend redacts it before we
		// see it (QoS-Ex.sh qos_ex_debug lists what goes).
		function runDebug() {
			setBusy(true, _('Generating debug report\u2026'));
			return h.callDebug().then(function(r) {
				checkPre.textContent = (r && r.output) ? r.output : _('(no output)');
			}).catch(function() {
				checkPre.textContent = _('(debug report failed)');
			}).finally(function() { setBusy(false); });
		}

		// The report, or null while the panel holds a placeholder line.
		function report() {
			var text = checkPre.textContent || '';
			return (!text || text.charAt(0) === '(') ? null : text;
		}
		// Forum post: two lines to fill in, then the report in a code block.
		// Plain Markdown, so it pastes into the OpenWrt forum, Reddit and
		// GitHub alike. A four-backtick fence survives any ``` in the report.
		var FORUM_MAX = 30000;
		function forumText(text) {
			return '**QoS-Ex problem report**\n\n' +
				'**What went wrong:** (what you did, what you expected, what happened instead)\n\n' +
				'**Game and device:** (for example Fortnite on PS5, wired - delete this line if it is not about a game)\n\n' +
				'**Debug report:**\n\n````text\n' + text.replace(/\s+$/, '') + '\n````\n';
		}
		// Copy the report, or the forum post. navigator.clipboard needs a
		// secure context, which a LAN router UI over plain http is not —
		// fall back to the textarea + execCommand('copy') trick in that case.
		function copyReport(forum) {
			var text = report(), btn = forum ? btnForum : btnCopy;
			var label = forum ? _('Copy for forum') : _('Copy report');
			if (!text) return;
			if (forum) text = forumText(text);
			function done(ok) {
				btn.textContent = ok ? _('Copied!') : _('Copy failed');
				window.setTimeout(function() { btn.textContent = label; }, 1500);
				if (ok && forum) h.setText(forumNote, text.length > FORUM_MAX
					? _('Copied %d characters. Too long for a post? Save .txt and attach it.').format(text.length)
					: _('Copied %d characters. Paste it into a post and fill in the top two lines.').format(text.length));
			}
			if (navigator.clipboard && navigator.clipboard.writeText) {
				navigator.clipboard.writeText(text).then(function() { done(true); },
					function() { done(false); });
				return;
			}
			var ta = E('textarea', { 'style': 'position:fixed;left:-9999px;top:0' });
			ta.value = text;
			document.body.appendChild(ta);
			ta.select();
			var ok = false;
			try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
			document.body.removeChild(ta);
			done(ok);
		}

		// The report as a file, for a forum that will not take it as text.
		function saveReport() {
			var text = report();
			if (!text) return;
			var a = E('a', { 'download': 'qos-ex-debug.txt',
				'href': URL.createObjectURL(new Blob([ text ], { type: 'text/plain' })) });
			document.body.appendChild(a); a.click(); document.body.removeChild(a);
			window.setTimeout(function() { URL.revokeObjectURL(a.href); }, 1000);
		}

		function disableOffload() {
			if (!confirm(_('Turn off flow offloading and reload the firewall?'))) return;
			setBusy(true, _('Disabling flow offloading\u2026'));
			return h.callAction('disable_offload').then(function(r) {
				checkPre.textContent = (r && r.ok)
					? _('Flow offloading is off.')
					: _('(disable offloading failed)');
			}).catch(function() {
				checkPre.textContent = _('(disable offloading failed)');
			}).finally(function() { setBusy(false); });
		}

		btnGen = E('button', { 'class': 'cbi-button cbi-button-action',
			'click': ui.createHandlerFn(self, function() { return runDebug(); }) }, _('Generate debug report'));
		btnCopy = E('button', { 'class': 'cbi-button cbi-button-neutral',
			'click': ui.createHandlerFn(self, function() { return copyReport(false); }) }, _('Copy report'));
		btnForum = E('button', { 'class': 'cbi-button cbi-button-neutral',
			'click': ui.createHandlerFn(self, function() { return copyReport(true); }) }, _('Copy for forum'));
		btnSave = E('button', { 'class': 'cbi-button cbi-button-neutral',
			'click': ui.createHandlerFn(self, function() { return saveReport(); }) }, _('Save .txt'));
		var forumNote = E('div', { 'class': 'cbi-value-description', 'style': 'margin-bottom:8px' });
		btnOff = E('button', { 'class': 'cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(self, function() { return disableOffload(); }) }, _('Disable flow offloading'));

		// The report is what the GitHub issue form asks for: its "Debug
		// report" box takes the copied text as it is.
		var issueUrl = 'https://github.com/choppyc79/QoS-Ex/issues/new?template=bug_report.yml';
		var checkSection = E('div', { 'class': 'cbi-section qos-ex-card' }, [
			E('h3', { 'class': 'qos-ex-card-title' }, [ _('Diagnostics'),
				E('span', { 'class': 'qos-ex-tools' }, E('a', { 'href': issueUrl, 'target': '_blank', 'rel': 'noopener' },
					_('Report an issue \u2192'))) ]),
			E('div', { 'style': 'margin-bottom:8px' }, [
				btnGen, ' ', btnCopy, ' ', btnForum, ' ', btnSave, ' ', btnOff
			]),
			E('div', { 'class': 'cbi-value-description', 'style': 'margin-bottom:8px' },
				_('Generate a report, then paste it into a forum post or the issue form. Your own addresses and names are removed.')),
			forumNote,
			checkPre
		]);

		// ----------------------------------------------------------------
		// Versions & updates. The three counters drift independently, so an
		// issue report needs all three. The latest come from the update
		// branch on GitHub, main or dev (update_check: cached on the router
		// for 1 h, Check now refetches). A branch other than the installed
		// one is a switch: Switch to installs its files, older or newer.
		// Update now runs QoS-Ex-install.sh on the router: it downloads all three,
		// verifies them and installs the ones that changed; a LuCI app install
		// ends this session.
		// ----------------------------------------------------------------
		var repo = 'https://github.com/choppyc79/QoS-Ex';
		var LOCAL = { shaper: st.version || '', luci: '__VERSION__'.replace(/^v/, ''), pf: pf.version || '' };
		// By module: the LuCI app (1.x) first, the shaper (3.x) last.
		var NAMES = [ [ 'luci', _('LuCI app'), 'v' ], [ 'pf', _('Ping Filter'), pf.ver_tag || 'v' ],
		              [ 'shaper', _('Shaper'), st.ver_tag || 'v' ] ];
		var upd = null, updating = false;
		// The branch picked differs from the one installed.
		function switching() { var r = upd || {}; return !!(r.branch && r.installed && r.branch !== r.installed); }
		function differs() {
			var r = upd || {};
			return NAMES.map(function(n) { return n[0]; }).filter(function(k) {
				return r[k] && LOCAL[k] && h.verCmp(r[k], LOCAL[k]) !== 0;
			});
		}
		var updGrid = E('div', { 'class': 'qos-ex-upd' });
		var updNote = E('span', { 'class': 'qos-ex-muted' }, _('Checking GitHub…'));
		// An update shows its progress here; its output is on System -> Logs.
		var progTxt = E('span'), progPct = E('strong', { 'style': 'float:right' }), progBar = E('i');
		var updProg = E('div', { 'style': 'display:none;margin-top:10px' }, [ E('div', {}, [ progTxt, progPct ]),
			E('div', { 'class': 'qx-meter', 'style': 'height:8px;margin-top:6px' }, progBar) ]);
		var updFail = E('div', { 'class': 'qos-ex-err', 'style': 'display:none;margin-top:10px' }, '');
		var logsUrl = L.url('admin', 'network', 'qos-ex', 'system', 'logs');
		// The steps QoS-Ex-install.sh and the installers it runs print, in
		// order: the furthest one in the log is the progress. Each takes the
		// line of an installer from before shaper 3.2.0.9 too (a branch can
		// still have one).
		var STEPS = [
			[ /qos-ex: source |ok {2}GitHub /, 10, _('Connecting to GitHub') ],
			[ /qos-ex: fetched |ok {2}downloaded and checked/, 25, _('Downloaded and checked') ],
			[ /QoS-Ex v[0-9.]+ install|ok {2}stopped /, 35, _('Installing the shaper') ],
			[ /packages:/, 45, _('Installing the shaper: packages') ],
			[ /config:|ok {2}settings:/, 55, _('Installing the shaper: settings') ],
			[ /procd init|ok {2}shaper v/, 65, _('Installing the shaper: service') ],
			[ /QoS-Ex-PF v|qos-ex: PingFilter|ok {2}Ping ?Filter/, 75, _('Installing Ping Filter') ],
			[ /QoS-Ex-luci v|qos-ex: LuCI app|ok {2}LuCI/, 85, _('Installing the LuCI app') ],
			[ /service started|ok {2}QoS-Ex started/, 95, _('Starting QoS-Ex') ]
		];
		function paintProg(pct, label) {
			updProg.style.display = '';
			h.setText(progTxt, label);
			h.setText(progPct, pct + '%');
			progBar.style.width = pct + '%';
		}
		function progOf(out) {
			var best = [ 5, _('Starting the update') ];
			STEPS.forEach(function(s) { if (s[1] > best[0] && s[0].test(out)) best = [ s[1], s[2] ]; });
			return best;
		}
		function failed(msg) {
			updFail.style.display = '';
			dom.content(updFail, [ '⚠ ' + msg + ' ', E('a', { 'href': logsUrl }, _('System → Logs')) ]);
		}
		// Plain handlers, not ui.createHandlerFn: that one turns its button
		// back on once the handler's promise settles, which for Update now is
		// as soon as the update has started. check() and busy() set these.
		var btnChk = E('button', { 'class': 'cbi-button cbi-button-neutral',
			'click': function() { check(true); } }, _('Check now'));
		var btnUpd = E('button', { 'class': 'cbi-button cbi-button-apply', 'disabled': '',
			'click': function() { runUpdate(); } }, _('Update now'));
		// Automatic checks: saved straight away (update_cfg), no Save & Apply,
		// and no shaper reload. Its state comes from the first check reply.
		var cbAuto = E('input', { 'type': 'checkbox', 'disabled': '', 'change': function() {
			var on = cbAuto.checked;
			cbAuto.disabled = true;
			h.callUpdateCfg(on ? 1 : 0).then(function(r) {
				if (!r || !r.ok) throw new Error((r && r.error) || '?');
				if (upd) upd.off = !on;
				paintUpd();
			}).catch(function(e) {
				cbAuto.checked = !on;
				h.notifyErr(_('Automatic update check') + ': ' + ((e && e.message) || e));
			}).finally(function() { cbAuto.disabled = false; });
		} });

		function ago(ts) {
			var s = Math.max(0, Math.round(Date.now() / 1000 - ts));
			return s < 90 ? _('just now') : s < 5400 ? _('%d min ago').format(Math.round(s / 60))
				: _('%d h ago').format(Math.round(s / 3600));
		}
		var selBr = E('select', { 'class': 'cbi-input-select', 'disabled': '',
			'title': _('Update from main (release) or dev (testing).'),
			'change': function() {
				var b = selBr.value, was = (upd && upd.branch) || 'main';
				selBr.disabled = true;
				h.callUpdateBranch(b).then(function(r) {
					if (!r || !r.ok) throw new Error((r && r.error) || '?');
					return check(true);
				}).catch(function(e) {
					selBr.value = was;
					h.notifyErr(_('Update branch') + ': ' + ((e && e.message) || e));
				}).finally(function() { selBr.disabled = updating; });
			} }, [ E('option', { 'value': 'main' }, _('main — releases (default)')),
			       E('option', { 'value': 'dev' }, _('dev — testing')) ]);
		function paintUpd() {
			var r = upd || {}, sw = switching(), newer = sw ? differs() : h.updNewer(r, LOCAL);
			if (r.branch) selBr.value = r.branch;
			var kids = [ _('Component'), _('Installed'), r.branch ? _('Latest (%s)').format(r.branch) : _('Latest'), '' ].map(function(t) {
				return E('div', { 'class': 'qos-ex-upd-h' }, t);
			});
			NAMES.forEach(function(n) {
				var loc = LOCAL[n[0]], rem = r[n[0]] || '', c = h.verCmp(rem, loc), st;
				if (!loc)       st = E('span', { 'class': 'qos-ex-muted' }, _('not installed'));
				else if (!rem)  st = E('span', { 'class': 'qos-ex-muted' }, '—');
				else if (sw && c !== 0) st = E('span', { 'class': 'qos-ex-warn-text' }, '⇄ ' + _('changes on switch'));
				else if (c > 0) st = E('span', { 'class': 'qos-ex-warn-text' }, '⬆ ' + _('update available'));
				else if (c < 0) st = E('span', { 'class': 'qos-ex-muted' }, _('newer than GitHub'));
				else            st = E('span', { 'class': 'qos-ex-ok' }, '✔ ' + _('up to date'));
				kids.push(E('div', {}, n[1]), E('div', {}, E('code', {}, [ loc ? n[2] + loc : '?' ])),
					E('div', {}, rem ? E('code', {}, [ n[2] + rem ]) : '—'), E('div', {}, st));
			});
			dom.content(updGrid, kids);
			if (updating) return;
			btnUpd.textContent = sw ? _('Switch to %s').format(r.branch) : _('Update now');
			btnUpd.disabled = sw ? !(r.checked && !r.error) : !newer.length;
			dom.content(updNote, r.error ? E('span', { 'class': 'qos-ex-err' }, [ '⚠ ' + r.error ])
				: (sw && r.checked) ? _('Installed from %s — Switch to %s installs its files').format(r.installed, r.branch)
				: r.checked ? (newer.length ? _('Update available — checked %s').format(ago(r.checked))
				                           : _('Up to date — checked %s').format(ago(r.checked)))
				: r.off ? _('Automatic check off — use Check now') : _('Not checked yet'));
		}
		function check(force) {
			btnChk.disabled = true;
			return h.rpcSafe(h.callUpdateCheck(force ? 1 : 0), {}).then(function(r) {
				upd = r._err ? { error: r._err } : r;
				if (!force && !r._err) { cbAuto.checked = !r.off; cbAuto.disabled = false; }
				if (!r._err && !updating) selBr.disabled = false;
				paintUpd();
			}).finally(function() { btnChk.disabled = updating; });
		}
		// The versions on this card are read once at load, so a finished
		// update shows 100% and Update complete, then reloads the page, or
		// opens the login page when the app was reinstalled (its job ends the
		// sessions 8 s after the update). A failed one stays put and points
		// to its log.
		var luciUpd = false;
		function finish(msg, ok) {
			var next = function() {
				if (luciUpd) window.location.replace(L.url('admin', 'logout'));
				else window.location.reload();
			};
			btnUpd.classList.remove('spinning');
			if (ok) paintProg(100, _('Update complete'));
			else failed(msg);
			// A finished update moves on by itself (next, below): no button.
			// A failed one stays put, so it keeps one.
			dom.content(updNote, [ E('span', { 'class': ok ? 'qos-ex-ok' : 'qos-ex-err' },
					ok ? msg + ' ' + (luciUpd ? _('Log in again to load the new app…') : _('Reloading…')) : _('Update failed')) ]
				.concat(ok ? [] : [ ' ', E('button', { 'class': 'cbi-button cbi-button-action', 'click': next },
					luciUpd ? _('Log in') : _('Reload')) ]));
			if (ok) window.setTimeout(next, 2500);
		}
		// Follow the log until it ends (@@RC=). While the router does not
		// answer (three polls in a row) nothing is known about the update, so
		// nothing is claimed: the note says so and the page keeps asking.
		// resumed: an update this page did not start. The log may be an older
		// run's (one from SSH writes none), so its end is the router's
		// running flag, and the reload shows how it went.
		function follow(resumed) {
			var fails = 0, t = window.setInterval(function() {
				if (!document.body.contains(updProg)) { window.clearInterval(t); return; }
				h.callUpdateLog().then(function(r) {
					var out = (r && r.output) || '', m = /@@RC=(\d+)/.exec(out), p = progOf(out);
					if (fails >= 3) dom.content(updNote, E('span', { 'class': 'qos-ex-muted' },
						resumed ? _('An update is running…') : _('Updating — do not close this page…')));
					fails = 0;
					if (resumed) {
						if (r && r.running) { if (!m) paintProg(p[0], p[1]); return; }
						window.clearInterval(t);
						window.location.reload();
						return;
					}
					if (!m) { paintProg(p[0], p[1]); return; }
					window.clearInterval(t);
					luciUpd = luciUpd || /QoS-Ex-luci v[0-9.]+ installed|ok {2}LuCI app v/.test(out);
					finish(m[1] === '0' ? _('Update finished.')
						: _('The update failed (exit %s); its log is on').format(m[1]), m[1] === '0');
				}).catch(function() {
					if (++fails === 3) dom.content(updNote, E('span', { 'class': 'qos-ex-warn-text' },
						_('No answer from the router — waiting for it…')));
				});
			}, 2000);
		}
		// Every control greyed out while an update runs: this page's, or one
		// found running. Update now spins, as LuCI's own busy buttons do,
		// until the bar reaches 100% (finish).
		function busy() {
			updating = true;
			btnUpd.disabled = btnChk.disabled = selBr.disabled = true;
			btnUpd.classList.add('spinning');
			updFail.style.display = 'none';
		}
		// An update this page did not start (another tab, before a reload or a
		// new login, QoS-Ex-install.sh from SSH): followed to its end.
		function resume(out) {
			busy();
			if (out && !/@@RC=/.test(out)) { var p = progOf(out); paintProg(p[0], p[1]); }
			dom.content(updNote, E('span', { 'class': 'qos-ex-muted' }, _('An update is running…')));
			follow(true);
		}
		function runUpdate() {
			// Only the changed components are installed (QoS-Ex-install.sh compares the files).
			var sw = switching(), br = (upd && upd.branch) || 'main';
			var nw = sw ? differs() : h.updNewer(upd || {}, LOCAL), has = function(k) { return nw.indexOf(k) >= 0; };
			var what = NAMES.filter(function(n) { return has(n[0]); }).map(function(n) { return n[1]; }).join(', ');
			if (!confirm((sw ? _('Switch to the %s branch on GitHub?').format(br) + (what ? ' ' + _('Changes: %s.').format(what) : '') +
					(br === 'dev' ? ' ' + _('dev is for testing; switch back to main to undo.') : '')
				: _('Update from GitHub: %s?').format(what)) + '\n\n' +
				(has('shaper') ? _('Shaping restarts for a few seconds.') + ' ' : '') +
				(has('pf') && !has('shaper') ? _('Ping Filter restarts.') + ' ' : '') +
				(has('luci') ? _('LuCI logs you out when the app is reinstalled.') : ''))) return;
			busy();
			luciUpd = has('luci');
			paintProg(2, _('Starting the update'));
			dom.content(updNote, E('span', { 'class': 'qos-ex-muted' }, _('Updating — do not close this page…')));
			return h.callUpdateRun().then(function(r) {
				if (r && r.ok) return follow();
				throw new Error((r && r.error) || '?');
			}).catch(function(e) {
				var msg = (e && e.message) || String(e);
				// One started meanwhile (another tab, SSH): follow that one.
				if (/already running/.test(msg)) return resume('');
				updating = false;
				btnUpd.classList.remove('spinning');
				updProg.style.display = 'none';
				failed(_('The update did not start: %s.').format(msg) + ' ' + _('More on'));
				btnChk.disabled = selBr.disabled = false;
				paintUpd();
			});
		}

		var verSection = E('div', { 'class': 'cbi-section qos-ex-card' }, [
			E('h3', { 'class': 'qos-ex-card-title' }, [ _('Versions & updates'),
				E('span', { 'class': 'qos-ex-tools' }, E('a', { 'href': repo, 'target': '_blank', 'rel': 'noopener' },
					_('GitHub →'))) ]),
			updGrid,
			E('div', { 'class': 'qos-ex-upd-bar' }, [ btnChk, btnUpd, updNote,
				E('label', { 'title': _('Check GitHub when QoS-Ex is opened, at most once an hour') },
					[ cbAuto, _('Check automatically') ]) ]),
			updProg, updFail,
			E('details', { 'class': 'qos-ex-raw qx-adv' }, [ E('summary', {}, _('Advanced')),
				E('div', { 'style': 'margin-top:8px' }, [ E('label', {}, [ _('Update branch') + ' ', selBr ]) ]) ]),
			E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:8px' },
				_('Settings are kept across updates. A failed update is logged in System \u2192 Logs.'))
		]);
		paintUpd();
		check(false);
		// An update already running (started on another page or tab, before
		// a reload or a new login, or from SSH) keeps Update now greyed out
		// and is followed. A failed one stays flagged, with a link to its
		// log, after a reload or a new login, until the next run replaces it.
		h.callUpdateLog().then(function(r) {
			var out = (r && r.output) || '', m = /@@RC=(\d+)\s*$/.exec(out);
			if (updating) return;
			if (r && r.running) return resume(out);
			if (!m || m[1] === '0') return;
			failed(_('The last update failed (exit %s); its log is on').format(m[1]));
		}).catch(function() {});

		// ----------------------------------------------------------------
		// Reset — confirms, then calls the ubus action. Acts immediately; this
		// tab has no saved settings and therefore no Save & Apply footer.
		// ----------------------------------------------------------------
		var btnReset = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(self, function() {
				if (!confirm(_('Erase the QoS-Ex settings? QoS-Ex turns off and Auto Setup opens again.'))) return;
				return h.callAction('reset_defaults').then(function(res) {
					// The defaults are a fresh install: QoS-Ex opens on Auto Setup.
					if (res && res.ok) {
						h.notifyOk(_('Reset to defaults') + ': ' + _('done'));
						window.setTimeout(function() { h.menuGo([]); }, 800);
					}
					else h.notifyErr(_('Reset to defaults') + ': ' + _('failed') +
						((res && res.error) ? ' (' + res.error + ')' : ''));
				}).catch(function(e) {
					h.notifyErr(_('Reset to defaults') + ': ' + _('failed') + ' (' + ((e && e.message) || e) + ')');
				});
			})
		}, _('Reset to defaults'));

		// Uninstall: qos-ex.sh uninstall, detached on the router. It takes this
		// app with it, reloads rpcd and ends every LuCI session. The page waits
		// until the app stops answering (at most 60 s), then loads LuCI anew at
		// its login page: Status behind an ended session, else the logout. The
		// login returns to Status, not to a QoS-Ex address that is gone.
		var btnUninst = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(self, function() {
				if (!confirm(_('Uninstall QoS-Ex?') + '\n\n' +
					_('Removes QoS-Ex, its settings and server history. This cannot be undone; a settings copy stays in /tmp/qos-ex.bak until reboot.'))) return;
				return h.callUninstallRun().then(function(res) {
					if (!(res && res.ok)) throw new Error((res && res.error) || '?');
					h.notifyOk(_('Uninstalling QoS-Ex — the OpenWrt login page follows.'));
					var n = 0, done = false, t = window.setInterval(function() {
						h.callUpdateLog().then(function() { if (++n >= 30) gone(true); },
							function(e) { gone(!/Access denied|-32002|expired/i.test(String((e && e.message) || e))); });
					}, 2000);
					function gone(live) {
						if (done) return;
						done = true;
						window.clearInterval(t);
						window.location.replace(live ? L.url('admin', 'logout') : L.url('admin', 'status', 'overview'));
					}
				}).catch(function(e) {
					h.notifyErr(_('Uninstall') + ': ' + _('failed') + ' (' + ((e && e.message) || e) + ')');
				});
			})
		}, _('Uninstall QoS-Ex'));

		// Settings backup: QoS-Ex Settings.cfg (h.cfgBackup / h.cfgRestore).
		var btnBackup = E('button', { 'class': 'btn cbi-button-action',
			'click': ui.createHandlerFn(self, function() { return h.cfgBackup(); }) }, _('Download settings'));
		var btnRestore = E('button', { 'class': 'btn cbi-button', 'click': function() { h.cfgRestore(); } }, _('Restore from file\u2026'));
		var backupSection = E('div', { 'class': 'cbi-section qos-ex-card' }, [
			E('h3', { 'class': 'qos-ex-card-title' }, _('Settings backup')),
			E('div', {}, [ btnBackup, ' ', btnRestore ]),
			E('div', { 'class': 'cbi-value-description' },
				_('All QoS-Ex settings in one file. Restore replaces them; server history is not included.'))
		]);

		// Auto Setup, run again (a new line, a new router): its tab comes back
		// and opens, as on a fresh install. Undo puts back the settings from
		// before the last Apply there, the tab with them (Apply is made on it),
		// and opens the first tab with a new menu: Auto Setup, or the Overview
		// when the copy put back has setup done (an apply from the CLI).
		var btnAsUndo = E('button', { 'class': 'cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(self, function() {
				if (!confirm(_('Undo the last Auto Setup?'))) return;
				return h.callAutosetupRun('undo', '').then(function(r) {
					if (!(r && r.ok)) throw new Error((r && r.error) || 'rc=' + ((r && r.rc) || '?'));
					h.menuGo([]);
				}).catch(function(e) {
					h.notifyErr(_('Undo last Auto Setup') + ': ' + _('failed') + ' (' + ((e && e.message) || e) + ')');
				});
			}) }, _('Undo last Auto Setup'));
		btnAsUndo.disabled = true;
		h.callAutosetup('hw').then(function(r) {
			btnAsUndo.disabled = !/(^|\n)undo=1(\n|$)/.test((r && r.output) || '');
		}).catch(function() {});
		var autoSection = E('div', { 'class': 'cbi-section qos-ex-card' }, [
			E('h3', { 'class': 'qos-ex-card-title' }, _('Auto Setup')),
			E('div', {}, [
				E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(self, function() {
					return h.callAutosetupRun('again', '').then(function(r) {
						if (!(r && r.ok)) throw new Error((r && r.error) || '?');
						h.menuGo([ 'autosetup' ]);
					}).catch(function(e) {
						h.notifyErr(_('Run Auto Setup') + ': ' + _('failed') + ' (' + ((e && e.message) || e) + ')');
					});
				}) }, _('Run Auto Setup')), ' ', btnAsUndo ]),
			E('div', { 'class': 'cbi-value-description' },
				_('Router check, speed test and suggested settings. Nothing changes until you apply.'))
		]);

		var dangerSection = E('div', { 'class': 'cbi-section qos-ex-card qos-ex-card-err' }, [
			E('h3', { 'class': 'qos-ex-card-title' }, _('Danger zone')),
			E('div', { 'class': 'qos-ex-grid' }, [
				E('div', {}, _('Reset configuration')),
				E('div', {}, [ btnReset,
					E('div', { 'class': 'cbi-value-description' },
						_('Factory defaults, QoS-Ex off. The old config is kept as config.bak.')) ]),
				E('div', {}, _('Uninstall')),
				E('div', {}, [ btnUninst,
					E('div', { 'class': 'cbi-value-description' },
						_('Removes QoS-Ex completely. Packages and flow offloading are left as before.')) ])
			])
		]);

		return E('div', { 'class': 'qos-ex-scope' }, [
			h.pageHead(_('Maintenance')),
			verSection,
			checkSection,
			autoSection,
			backupSection,
			dangerSection
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
