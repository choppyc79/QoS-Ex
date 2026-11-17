#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# QoS-Ex shaper, install half: packages, the config seed and top-up, procd
# init, the ifup and sysupgrade hooks, autostart, the master switch (enable /
# disable), install and uninstall, Auto Setup.
# Sourced by QoS-Ex.sh (_lib_install) for the verbs that use it; not run on
# its own. Part of the shaper: a change here bumps VERSION in QoS-Ex.sh.

install_pkgs() {
	# Every PKG_DEPS_BACKEND entry is a hard dependency.
	local mgr p missing="" have=0 failed=""
	mgr=$(_pkg_mgr) || { ui_bad "no package manager found (apk / opkg)"; return 1; }

	for p in $PKG_DEPS_BACKEND; do
		if _pkg_have "$mgr" "$p"; then have=$((have + 1)); else missing="$missing $p"; fi
	done
	missing="${missing# }"
	if [ -z "$missing" ]; then
		ui_ok "packages: $have present ($mgr)"
		return 0
	fi

	ui_info "packages: fetching $missing ($mgr)"
	case "$mgr" in
		opkg) opkg update >/dev/null 2>&1 ;;
		apk)  apk update  >/dev/null 2>&1 ;;
	esac
	for p in $missing; do
		case "$mgr" in
			opkg) opkg install "$p" >/dev/null 2>&1 ;;
			apk)  apk add     "$p" >/dev/null 2>&1 ;;
		esac
		if _pkg_have "$mgr" "$p"; then ui_ok "package $p installed"
		else failed="$failed $p"; fi
	done
	if [ -n "$failed" ]; then
		ui_bad "packages not installed:$failed - QoS-Ex may not start until these exist"
		return 1
	fi
	return 0
}

emit_pf_uci_section() {
	cat <<'PFEOF'

config pingfilter 'pingfilter'
	option enabled '0'
	option lite '0'
	option threshold_ms '0'
	option ignore_ports '3478-3481'
	option area_adjust_pct '5'
	option row_ttl '604800'
	option persist_interval '3600'
	option first_pkts '2'
	option max_servers '250'
	option geoip_lookup 'yes'
	option geoip_api 'http://ip-api.com/json'
	option home_lat ''
	option home_lon ''
	option home_radius_km '1000'
	option block_mode 'ping'
	option ping_catch_ms '0'
	option ping_var_pct '5'
	option auto_pin '2'
	option active_pps '20'
	option telemetry '1'
PFEOF
}

emit_uci_config() {
	cat <<'UCIEOF'
config global 'settings'
	option enabled '0'
	option wan 'eth0'
	option qdisc 'cake'
	option nft_mode 'adaptive'
	option upload_kbps '100000'
	option download_kbps '100000'
	option overhead '44'
	option linklayer 'ethernet'
	option download_on 'wan'
	option live_refresh '1'
	option wash_up 'yes'
	option wash_down 'yes'
	option ack_filter 'auto'
	option bw_max_ratio 'auto'
	option bw_headroom '90'
	option mss 'auto'
	option mss_max_kbps '3000'

config cake 'cake'
	option priority 'diffserv4'
	option host_isolation 'yes'
	option nat_ingress 'yes'
	option nat_egress 'yes'
	option ingress_mode 'yes'
	option extra_ingress ''
	option extra_egress ''
	option mpu '84'
	option rtt '100ms'

config hfsc 'hfsc'
	option game_qdisc 'sfq'
	option default_qdisc 'fq_codel'
	option pfifo_min '5'
	option packet_size '576'
	option max_delay '5'
	option bfifo_min '3000'
	option sfq_perturb '10'
	option sfq_quantum '300'
	option fq_limit '10240'
	option fq_flows '1024'
	option fq_quantum '300'
	option fq_target '5'
	option fq_interval '100'
	option game_pct '15'
	option game_burst '10'
	option game_floor '400'
	option voice_rt 'yes'
	option def_tune_mode 'auto'
	option def_fq_limit '10240'
	option def_fq_flows '1024'
	option def_fq_quantum '1514'
	option def_fq_target '5'
	option def_fq_interval '100'
	option def_fq_memory_mb '4'
	option def_fq_ecn 'ecn'
	option def_sfq_limit '127'
	option def_sfq_depth '127'
	option def_sfq_divisor '1024'
	option def_sfq_flows '127'
	option def_sfq_quantum '1514'
	option def_sfq_perturb '10'
	option def_sfq_headdrop 'no'

config ports 'ports'
	option http '80,443'
	option tcp_bulk '51413,6881-6889'
	option udp_bulk '51413'
	option vidconf '53,500,3478-3481,4500,5223,5938,8801-8802,10000,19302-19309'

config advanced 'advanced'
	option udp_fast_pps '450'
	option udp_fast_burst '225'
	option udp_small_avgpkt '576'
	option slow_flow_pps '150'
	option heavy_flow_pps '1000'
	option bulk_timeout '120'
	option tcp_new_cap_mbit '80'
	option tcp_bulk_cap_mbit '400'
	option gaming_ip 'yes'
	option lowprio_ip 'yes'
	option tcp_upgrade 'yes'
	option tcp_10s 'yes'
	option meter_down 'yes'
	option web_pps '200'
	option tcp_pps '200'
	option udp_pps '250'
	option small_len '84'
	option max_len '1256'
	option reset_pm '5'

config adaptive 'adaptive'
	option heavy_pct '25'
	option heavy_secs '10'
	option p2p_rate '120'
	option vpn_ports '51820,1194'

config simple 'simple'
	option bulk_ports 'yes'
	option vidconf 'yes'
	option gaming_ip 'yes'
	option lowprio_ip 'yes'
	option udp_rate 'yes'
	option tcp_500ms 'yes'
	option tcp_upgrade 'yes'
	option tcp_10s 'yes'

config autosetup 'autosetup'
	option done '0'
	option test_secs '10'
	option test_mb '1500'
	option test_url 'http://speed.cloudflare.com'
	option ping_host '1.1.1.1'
	option cpu_busy_pct '90'
	option low_ram_mb '128'
	option small_flash_mb '16'
	option high_cores '4'
	option high_mhz '1500'
	option high_ram_mb '1024'
	option queue_low 'htb'
	option queue_mid 'hfsc'
	option queue_high 'cake'
	option cake_max_mbit '500'
	option fit_check '1'
	option fit_sirq_pct '80'
	option fallback '1'
	option fallback_list 'https://librespeed.org/backend-servers/servers.php'
	option rules_low 'simple'
	option rules_mid 'adaptive'
	option rules_high 'adaptive'

config ips 'ips'
UCIEOF
	# One emitter for the pingfilter defaults: install and top-up agree.
	emit_pf_uci_section
}

### Settings top-up: walks the canonical emitter and adds only what is ABSENT
### (sections, and scalar options with a non-empty default). Never overwrites
### an operator value, never touches `list` entries. LuCI reads raw keys, so a
### key added after the first install would otherwise render as missing.
uci_migrate() {
	local ref line rest sect styp opt val added=0 _new=0
	local lpb_old _o _v _blank=""
	# Auto Setup pending (autosetup.done 0): the keys it picks stay as they
	# are, blank after a reset, until it is applied or Manual setup is chosen.
	[ "$(uci -q get "$UCI_CFG.autosetup.done")" = 0 ] && _blank=" $AS_BLANK "
	# The relative ping limit is gone.
	if uci -q get "$UCI_CFG.pingfilter.limit_rel_ms" >/dev/null; then
		uci -q delete "$UCI_CFG.pingfilter.limit_rel_ms"
		ui_note "- pingfilter.limit_rel_ms (relative limit removed)"
		added=$((added + 1))
	fi
	# Adaptive P2P is a new-connection rate, not a count (no nft_connlimit).
	# 0 (off) carries over; a count does not.
	_v=$(uci -q get "$UCI_CFG.adaptive.p2p_conns") && {
		uci -q delete "$UCI_CFG.adaptive.p2p_conns"
		[ "$_v" = 0 ] && uci -q set "$UCI_CFG.adaptive.p2p_rate=0"
		ui_note "- adaptive.p2p_conns (now p2p_rate, new connections a minute)"
		added=$((added + 1))
	}
	# HTB classes ceil at the shaped rate; htb.ceil and its section are gone.
	if uci -q get "$UCI_CFG.htb" >/dev/null; then
		uci -q delete "$UCI_CFG.htb"
		ui_note "- htb (classes 1:11-1:15 always borrow up to the shaped rate)"
		added=$((added + 1))
	fi
	# Gaming is inside the shaped rate; game_ceil is gone.
	if uci -q get "$UCI_CFG.hfsc.game_ceil" >/dev/null; then
		uci -q delete "$UCI_CFG.hfsc.game_ceil"
		ui_note "- hfsc.game_ceil (Gaming is inside the shaped rate)"
		added=$((added + 1))
	fi
	# Ping Filter defaults moved. Move only an OLD default; any other value
	# is an operator choice.
	for _o in pingfilter.max_servers:200:250 \
		pingfilter.persist_interval:900:3600 advanced.tcp_new_cap_mbit:250:80 \
		autosetup.rules_low:adaptive:simple autosetup.rules_mid:simple:adaptive; do
		_v=${_o#*:}
		[ "$(uci -q get "$UCI_CFG.${_o%%:*}")" = "${_v%:*}" ] || continue
		uci -q set "$UCI_CFG.${_o%%:*}=${_v#*:}"
		ui_note "~ ${_o%%:*} ${_v%:*} -> ${_v#*:} (new default)"
		added=$((added + 1))
	done
	# The gaming queue default moved from pfifo to sfq (3.2.1.4): an update
	# from an older shaper moves a saved pfifo once, so one picked again later
	# stays. _osh is the shaper being replaced (install_all), "v3.2.1.4";
	# every field is one digit, so the dotless number orders the versions.
	_v=${_osh#v}
	while :; do case "$_v" in *.*) _v=${_v%%.*}${_v#*.} ;; *) break ;; esac; done
	if _isnum "$_v" && [ "$_v" -lt 3215 ] && [ "$(uci -q get "$UCI_CFG.hfsc.game_qdisc")" = pfifo ]; then
		uci -q set "$UCI_CFG.hfsc.game_qdisc=sfq"
		ui_note "~ hfsc.game_qdisc pfifo -> sfq (new default)"
		added=$((added + 1))
	fi
	# Auto Setup's rule set for a high-end router moved from advanced to
	# adaptive (3.2.1.9): once, as the gaming queue above, so one picked again
	# later stays.
	if _isnum "$_v" && [ "$_v" -lt 3219 ] && [ "$(uci -q get "$UCI_CFG.autosetup.rules_high")" = advanced ]; then
		uci -q set "$UCI_CFG.autosetup.rules_high=adaptive"
		ui_note "~ autosetup.rules_high advanced -> adaptive (new default)"
		added=$((added + 1))
	fi
	# The manual fq_codel fields hold numbers only: "auto" becomes the
	# fq_codel default.
	for _o in def_fq_target:5 def_fq_interval:100 def_fq_memory_mb:4; do
		_v=$(uci -q get "$UCI_CFG.hfsc.${_o%:*}") || continue
		case "$_v" in
			*[!0-9]*|0*)
				uci -q set "$UCI_CFG.hfsc.${_o%:*}=${_o#*:}"
				ui_note "~ hfsc.${_o%:*} $_v -> ${_o#*:} (fq_codel default)"
				added=$((added + 1)) ;;
		esac
	done
	# Retired SGS: rule set sgs -> simple, queue hfsc_sgs and hfsc.curves ->
	# plain HFSC.
	if [ "$(uci -q get "$UCI_CFG.settings.nft_mode")" = "sgs" ]; then
		uci -q set "$UCI_CFG.settings.nft_mode=simple"
		ui_note "~ settings.nft_mode sgs -> simple (the SGS rule set was removed)"
		added=$((added + 1))
	fi
	if [ "$(uci -q get "$UCI_CFG.settings.qdisc")" = "hfsc_sgs" ]; then
		uci -q set "$UCI_CFG.settings.qdisc=hfsc"
		ui_note "~ settings.qdisc hfsc_sgs -> hfsc (the SGS curves were removed)"
		added=$((added + 1))
	fi
	if _v=$(uci -q get "$UCI_CFG.hfsc.curves"); then
		uci -q delete "$UCI_CFG.hfsc.curves"
		[ "$_v" = "sgs" ] && ui_note "~ hfsc.curves sgs removed - HFSC uses the QoS-Ex curves"
		added=$((added + 1))
	fi
	# Lists once seeded with one empty entry: drop empty entries; a list left
	# with none is removed.
	for _o in pingfilter.whitelist pingfilter.blacklist pingfilter.allow_country \
		ips.gaming_ipv4 ips.gaming_ipv6 ips.gaming_mac ips.lowprio_ipv4 ips.lowprio_ipv6 ips.lowprio_mac; do
		case "$(uci -q show "$UCI_CFG.$_o")" in *"=''"*|*"'' "*|*" ''"*) ;; *) continue ;; esac
		uci -q del_list "$UCI_CFG.$_o=" || continue
		ui_note "- $_o empty entry"
		added=$((added + 1))
	done
	# Pre-split keys, carried into the keys that replaced them BEFORE the
	# top-up seeds those with their defaults (which silently undid them):
	# tcp_flow switched all three TCP stages, and mpu / rtt lived in settings.
	for _o in simple:tcp_500ms simple:tcp_upgrade simple:tcp_10s advanced:tcp_upgrade advanced:tcp_10s; do
		_v=$(uci -q get "$UCI_CFG.${_o%%:*}.tcp_flow") || continue
		[ -n "$_v" ] || continue
		[ -n "$(uci -q get "$UCI_CFG.${_o%%:*}.${_o#*:}")" ] && continue
		uci -q set "$UCI_CFG.${_o%%:*}.${_o#*:}=$_v"
		ui_note "~ ${_o%%:*}.tcp_flow $_v -> ${_o%%:*}.${_o#*:}"
		added=$((added + 1))
	done
	for _o in simple advanced; do
		uci -q get "$UCI_CFG.$_o.tcp_flow" >/dev/null || continue
		uci -q delete "$UCI_CFG.$_o.tcp_flow"
		ui_note "- $_o.tcp_flow (split into tcp_500ms / tcp_upgrade / tcp_10s)"
		added=$((added + 1))
	done
	for _o in mpu rtt; do
		_v=$(uci -q get "$UCI_CFG.settings.$_o") || continue
		if [ -n "$_v" ] && [ -z "$(uci -q get "$UCI_CFG.cake.$_o")" ]; then
			uci -q get "$UCI_CFG.cake" >/dev/null || uci -q set "$UCI_CFG.cake=cake"
			uci -q set "$UCI_CFG.cake.$_o=$_v"
		fi
		uci -q delete "$UCI_CFG.settings.$_o"
		ui_note "~ settings.$_o -> cake.$_o"
		added=$((added + 1))
	done
	# No WAN (cleared in LuCI, or a hand-made config): the device the default
	# route is on, as a fresh install does, before the top-up seeds eth0.
	if [ -z "$_blank" ] && uci -q get "$UCI_CFG.settings" >/dev/null && [ -z "$(uci -q get "$UCI_CFG.settings.wan")" ]; then
		_v=$(_wan_live)
		case "$_v" in
			''|*[!A-Za-z0-9._-]*) ;;
			*) uci -q set "$UCI_CFG.settings.wan=$_v"
			   ui_note "+ settings.wan = $_v (default route)"
			   added=$((added + 1)) ;;
		esac
	fi
	# Auto Setup is offered on a fresh config only: a config from before it
	# counts as set up (the top-up below would seed done=0).
	if ! uci -q get "$UCI_CFG.autosetup" >/dev/null; then
		uci -q set "$UCI_CFG.autosetup=autosetup"
		uci -q set "$UCI_CFG.autosetup.done=1"
		ui_note "+ autosetup.done = 1 (set up before Auto Setup)"
		added=$((added + 1))
	fi
	# No $$ fallback: written and read back as root.
	ref=$(mktemp /tmp/.qos-ex-uci-ref.XXXXXX 2>/dev/null) || {
		err "config top-up: no writable temp file"; return 1; }
	emit_uci_config > "$ref" 2>/dev/null || {
		rm -f "$ref"; err "config top-up: could not render defaults"; return 1; }
	sect=""
	while IFS= read -r line; do
		case "$line" in
			"config "*)
				rest="${line#config }"
				styp="${rest%% *}"
				sect="${rest#* }"
				sect="${sect#\'}"; sect="${sect%\'}"
				# Anonymous section: nothing addressable. Test rest-vs-type, not
				# name-vs-type (`config cake 'cake'`).
				[ "$rest" = "$styp" ] && { sect=""; continue; }
				_new=0
				uci -q get "$UCI_CFG.$sect" >/dev/null 2>&1 && continue
				uci -q set "$UCI_CFG.$sect=$styp" || continue
				_new=1
				ui_note "+ section $sect ($styp)"
				added=$((added + 1))
				;;
			*"option "*)
				[ -n "$sect" ] || continue
				rest="${line#*option }"
				opt="${rest%% *}"
				val="${rest#* }"
				[ "$val" = "$rest" ] && continue   # no value on the line
				val="${val#\'}"; val="${val%\'}"
				[ -n "$val" ] || continue          # empty default: nothing to add
				# A cleared port list is the off switch: never re-seed it.
				case "$_new$sect.$opt" in
					0ports.tcp_bulk|0ports.udp_bulk|0ports.vidconf) continue ;;
				esac
				[ -n "$(uci -q get "$UCI_CFG.$sect.$opt")" ] && continue
				case "$_blank" in *" $sect.$opt "*) continue ;; esac
				uci -q set "$UCI_CFG.$sect.$opt=$val" || continue
				ui_note "+ $sect.$opt = $val"
				added=$((added + 1))
				;;
		esac
	done < "$ref"
	rm -f "$ref"
	# Retired keys: the top-up only adds, so keys dropped from the emitter
	# are removed here.
	for lpb_old in active_interval idle_interval recheck_interval armed_interval idle_poll \
			parallel_cap udp_sample_secs rtt_interval tele_jit_minpps tele_jit_interval \
			tele_ring tele_ckpt tele_ckpt_win tele_finalize \
			ping_count probe_retries catch_grace hs_rtt area_km area_min geo_retry \
			dist_base_ms dist_slope_us presence_pps conn_min_pps match_end_wait \
			rtt_probe gap_ms session_min tele_gap prefix_ttl map_keep set_timeout \
			learning profile unknown_policy unknown_ping unknown_distance \
			game_names game_dns game; do
		[ -n "$(uci -q get "$UCI_CFG.pingfilter.$lpb_old")" ] || continue
		uci -q delete "$UCI_CFG.pingfilter.$lpb_old"
		ui_note "- pingfilter.$lpb_old (retired)"
		added=$((added + 1))
	done
	for lpb_old in ruleset tcp_500ms gaming_guard; do
		[ -n "$(uci -q get "$UCI_CFG.advanced.$lpb_old")" ] || continue
		uci -q delete "$UCI_CFG.advanced.$lpb_old"
		ui_note "- advanced.$lpb_old (retired)"
		added=$((added + 1))
	done
	# Auto Setup suggests the line rate; Headroom (bw_headroom) takes its share.
	if [ -n "$(uci -q get "$UCI_CFG.autosetup.rate_pct")" ]; then
		uci -q delete "$UCI_CFG.autosetup.rate_pct"
		ui_note "- autosetup.rate_pct (retired: Headroom applies)"
		added=$((added + 1))
	fi
	# Multi-queue CAKE was removed: CAKE runs with one queue everywhere.
	if [ -n "$(uci -q get "$UCI_CFG.cake.mq")" ]; then
		uci -q delete "$UCI_CFG.cake.mq"
		ui_note "- cake.mq (retired: multi-queue CAKE removed)"
		added=$((added + 1))
	fi
	if [ "$added" -gt 0 ]; then
		uci -q commit "$UCI_CFG"
		ui_ok "settings: yours kept, $added key(s) added or retired"
	else
		ui_ok "settings: yours kept, up to date"
	fi
	return 0
}

install_uci() {
	if [ -f /etc/config/$UCI_CFG ]; then
		# Keep every operator value; add only what is missing (pingfilter too).
		uci_migrate
		return
	fi
	# Render, then move: a partial write (full /overlay) would parse as
	# missing defaults rather than fail.
	local _cfgtmp _w _m=""
	_cfgtmp=$(mktemp "/etc/config/.$UCI_CFG.XXXXXX" 2>/dev/null) || {
		ui_bad "settings: could not create a temp file in /etc/config"; return 1; }
	if emit_uci_config > "$_cfgtmp" 2>/dev/null; then
		chmod 644 "$_cfgtmp" 2>/dev/null
		mv "$_cfgtmp" "/etc/config/$UCI_CFG"
		# A fresh config offers Auto Setup: LuCI builds its menu again (_as_done).
		rm -f /tmp/luci-indexcache* 2>/dev/null
	else
		rm -f "$_cfgtmp" 2>/dev/null
		ui_bad "settings: could not write /etc/config/$UCI_CFG"
		return 1
	fi
	# A fresh config carries wan=eth0: point it at the default-route device
	# when there is one. Only on a config this run created.
	_w=$(_wan_live)
	case "$_w" in
		''|eth0|*[!A-Za-z0-9._-]*) ;;
		*) uci -q set "$UCI_CFG.settings.wan=$_w" && uci -q commit "$UCI_CFG" \
			&& _m=", WAN interface $_w (the default route)" ;;
	esac
	ui_ok "settings: /etc/config/$UCI_CFG created (defaults)$_m"
}

### procd init: the shaper setup is one-shot in start_service; procd
### supervises the Ping Filter as a respawned instance. QOS_EX_SUPERVISED=1
### tells the backend not to fork its own daemon. $PF_RUN_DIR/.procd routes
### enable / disable / reload through procd.
emit_init_script() {
	local dst="$1"
	cat <<INITEOF
#!/bin/sh /etc/rc.common
# shellcheck disable=SC3023  # rc.common runs this in BusyBox ash; fd 1000 is procd's lock
USE_PROCD=1
START=99
STOP=10

QOS_EX="$dst"
PF_RUN_DIR="$PF_RUN_DIR"
PF_PID_FILE="$PF_PID_FILE"

# guard against the backend file having gone missing (manual rm,
# failed upgrade). Without this, procd would loop on "exec: not found".
_qos_ex_ok() {
	if [ ! -f "\$QOS_EX" ]; then
		logger -t QoS-Ex -p daemon.err "backend missing at \$QOS_EX - aborting init action"
		return 1
	fi
	return 0
}

start_service() {
	_qos_ex_ok || return 1
	logger -t QoS-Ex "start_service (procd)"
	# Tear down first. procd will happily run start_service on a
	# service that is already up -- a boot start racing an ifup hook, a
	# reload trigger, 'service QoS-Ex start' typed twice -- and the shaper
	# setup is not free to run twice: the second pass rebuilt qdiscs under
	# live classification and re-armed the PingFilter instance while the
	# first was still bringing it up. stop is idempotent and cheap on a
	# cold boot (nothing to delete), so paying it unconditionally is the
	# simplest way to make start mean exactly one running instance.
	# 1000>&- on every backend call: procd.sh holds this service's lock on fd
	# 1000 for the whole action. This shell keeps it; the backend must not
	# pass it on, or a job it leaves running (the Ping Filter's location
	# check after a start) holds the lock, and the next action waits for it,
	# with procd's trigger queue behind it.
	QOS_EX_SUPERVISED=1 "\$QOS_EX" stop >/dev/null 2>&1 1000>&-
	# One-shot shaper apply. QOS_EX_SUPERVISED stops QoS-Ex.sh from forking its
	# own detached PingFilter daemon - procd owns that lifecycle below.
	QOS_EX_SUPERVISED=1 "\$QOS_EX" start 1000>&-
	_qos_ex_start_rc=\$?
	# rc.common's rc_procd does not pass this status on -- "service QoS-Ex
	# start" exits 0 regardless. The backend's own start verb reports the
	# real outcome (it checks the start stamp after calling back here).
	#
	# The PingFilter instance is still registered when the shaper fails: it
	# self-gates on UCI, and grading a link is useful whether or not the
	# qdiscs came up. Only the return value changes.
	# Marker: backend uses this to know procd supervises the daemon, so
	# enable/disable/reload nudge a respawn instead of spawning directly.
	mkdir -p "\$PF_RUN_DIR" 2>/dev/null
	: > "\$PF_RUN_DIR/.procd"
	# Supervised, auto-respawning PingFilter daemon. The daemon self-gates
	# on UCI enabled + prereqs: when off/unconfigured it idles cheaply, so
	# procd never hot-loops respawning a process that quits immediately.
	[ -x /usr/sbin/qos-ex-pf.sh ] || return \$_qos_ex_start_rc
	procd_open_instance pingfilter
	procd_set_param command /usr/sbin/qos-ex-pf.sh _daemon_supervised
	procd_set_param respawn 3600 5 0
	procd_set_param pidfile "\$PF_PID_FILE"
	# stdout 0: the daemon used to have every routine message copied into
	# syslog as daemon.info by this capture. Since PF 2.0.8.0 it stays quiet
	# on stdout and writes to the QoS-Ex logs instead. stderr is still
	# captured so a hard shell-level failure is not invisible.
	procd_set_param stdout 0
	procd_set_param stderr 1
	procd_close_instance
	return \$_qos_ex_start_rc
}

stop_service() {
	logger -t QoS-Ex "stop_service (procd)"
	rm -f "\$PF_RUN_DIR/.procd" 2>/dev/null
	_qos_ex_ok || return 0
	QOS_EX_SUPERVISED=1 "\$QOS_EX" stop 1000>&-
}

reload_service() {
	_qos_ex_ok || return 1
	# Not running: a real start, so procd registers the service, the Ping
	# Filter instance and this trigger (a backend-only start left all three
	# missing). This shell already holds procd's lock: start does not wait.
	if [ ! -f /var/run/qos-ex-started ]; then
		case "\$(uci -q get $UCI_CFG.settings.enabled)" in
			1|yes|on|true|enabled) start; return \$? ;;
		esac
	fi
	logger -t QoS-Ex "reload_service (procd)"
	QOS_EX_SUPERVISED=1 "\$QOS_EX" reload 1000>&-
}

# rc.common defines boot() as "start" BEFORE it sources this file, and its
# USE_PROCD block afterwards redefines start/stop/reload but NOT boot -- so
# this override is what actually runs at boot, and it deliberately does not
# start the shaper. At rc.d time (START=99) netifd has only just been asked
# to bring the network up; on a PPPoE line pppoe-wan does not exist yet, so
# a start here fails the ip-link guard and the shaper stays down for the
# whole session with nothing to retry it. /etc/hotplug.d/iface/99-QoS-Ex
# owns the start instead: it fires when the WAN device is genuinely up, and
# again after every redial. enable/enabled are unaffected -- the rc.d
# symlink still governs whether the hook is allowed to act, so System ->
# Startup and the dashboard toggle keep meaning what they always meant.
boot() {
	logger -t QoS-Ex "Starting via Hotplug"
}

service_triggers() {
	# The trigger keys on the UCI PACKAGE name (/etc/config/qos-ex), which is
	# not the service name -- do not "fix" this to \$SCRIPT_NAME.
	procd_add_reload_trigger "$UCI_CFG"
}
INITEOF
}

# stdin to $1 through a dot-file beside it, renamed only after a complete,
# parsable write: on a full overlay the old file stays, never a truncated
# script reported as installed. hotplug-call, rc.d and /etc/init.d/boot skip
# dotfiles. $2 = mode.
_stage_write() {
	local _dst="$1" _t
	_t=$(mktemp "${_dst%/*}/.${_dst##*/}.XXXXXX" 2>/dev/null) || { cat >/dev/null; return 1; }
	if cat > "$_t" && [ -s "$_t" ] && sh -n "$_t" 2>/dev/null && chmod "${2:-755}" "$_t" && mv -f "$_t" "$_dst"; then
		return 0
	fi
	rm -f "$_t" 2>/dev/null
	return 1
}

install_init() {
	local src dst
	src="$(resolve_self_path)"
	dst="$QOS_EX_BIN"
	if [ -f "$src" ] && [ "$src" != "$dst" ]; then
		mkdir -p "$(dirname "$dst")" 2>/dev/null
		# Staged + renamed: the dashboard runs $dst while it is copied.
		if cp "$src" "$dst.new" 2>/dev/null && chmod +x "$dst.new" && mv "$dst.new" "$dst"; then
			:
		else
			rm -f "$dst.new" 2>/dev/null
			err "init: could not copy backend to $dst; init will exec $src in place"
			dst="$src"
		fi
	elif [ "$src" = "$dst" ]; then
		: # already canonical
	else
		err "init: could not resolve backend path (got '$src'); using as-is"
		dst="$src"
	fi
	# The install half beside the installed backend, staged + renamed.
	if [ -f "$_QX_LIB" ] && [ "$_QX_LIB" != "$QX_LIB" ]; then
		mkdir -p "${QX_LIB%/*}" 2>/dev/null
		if ! { cp "$_QX_LIB" "$QX_LIB.new" 2>/dev/null && chmod 644 "$QX_LIB.new" && mv "$QX_LIB.new" "$QX_LIB"; }; then
			rm -f "$QX_LIB.new" 2>/dev/null
			ui_bad "could not write $QX_LIB"; return 1
		fi
	fi
	# The live counters for the rpcd shim (lib live.sh), sliced from the
	# installed backend's ### LIVE block: one source, and a Stats poll parses
	# no script. _stage_write checks the slice's syntax.
	mkdir -p "${QX_LIVE%/*}" 2>/dev/null
	{ echo "# QoS-Ex live counters, sliced from $dst at install (### LIVE markers); not edited by hand."
	  sed -n '/^### LIVE BEGIN/,/^### LIVE END/p' "$dst"; } | _stage_write "$QX_LIVE" 644 ||
		ui_bad "could not write $QX_LIVE (the Live pages read the backend instead)"
	emit_init_script "$dst" | _stage_write /etc/init.d/$SCRIPT_NAME 755 || {
		ui_bad "could not write /etc/init.d/$SCRIPT_NAME"; return 1; }
	# install_all sets _QOS_EX_AUTO=0 when autostart was off before.
	if [ "${_QOS_EX_AUTO:-1}" = 1 ]; then
		/etc/init.d/$SCRIPT_NAME enable 2>/dev/null
	else
		/etc/init.d/$SCRIPT_NAME disable 2>/dev/null
	fi
	ui_note "backend -> $dst, procd -> /etc/init.d/$SCRIPT_NAME"
}

emit_hotplug() {
	local self="$1" init="$2"
	cat <<HPEOF
#!/bin/sh
# QoS-Ex ifup hook. Since 3.0.1.0 this is the only automatic start path:
# the init script's boot() is a deliberate no-op because at rc.d time the
# WAN device -- a PPPoE one especially -- does not exist yet.
[ "\$ACTION" = "ifup" ] || exit 0

# Only the interface carrying our shaped WAN DEVICE may trigger a restart.
# Testing \$DEVICE against $UCI_CFG.settings.wan rather than a hardcoded list
# of logical names is what makes a PPPoE redial work: netifd destroys and
# recreates pppoe-wan, then re-fires ifup for whatever the line happens to
# be called, and DEVICE is pppoe-wan both times. The old wan|wan6 list also
# carried a dead pppoe-wan arm -- that is a device name and never appears in
# INTERFACE. Matching the device instead covers an operator who named the
# interface wan2/wwan/wan_4, and no lan/guest/VPN ifup can reach us. netifd
# sets DEVICE on ifup and ifupdate only -- never ifdown -- so for the one
# action we handle it is never legitimately empty. settings.wan must be that
# L3 device (status and start warn when it is not): the classifier names it
# too, so the port under pppoe-wan would neither start nor classify.
hp_wan="\$(uci -q get $UCI_CFG.settings.wan)"
# Same literal default as load_config's config_get fallback: keep in step.
[ -n "\$hp_wan" ] || hp_wan="eth0"
# With the download shaped on the LAN device (settings.download_on lan), an
# ifup of that device (a bridge rebuilt by a network reload) drops its
# qdiscs too: the device the last start recorded restarts us as well.
hp_st=/var/run/qos-ex-started
hp_lan=""
[ "\$(sed -n 's/^DLON=//p' "\$hp_st" 2>/dev/null)" = lan ] && hp_lan="\$(sed -n 's/^IFB=//p' "\$hp_st" 2>/dev/null)"
[ "\$DEVICE" = "\$hp_wan" ] || { [ -n "\$hp_lan" ] && [ "\$DEVICE" = "\$hp_lan" ]; } || exit 0

# Respect the admin switch. With boot() a no-op, this hook is the only thing
# that could bring up a service the operator has deliberately disabled. The
# rc.d symlink, which is what "\$init enabled" tests, without a shell to
# source the init script: netifd runs one hotplug script at a time.
if [ -x "$init" ]; then
	hp_en=0
	for hp_f in /etc/rc.d/S[0-9][0-9]$SCRIPT_NAME; do [ -e "\$hp_f" ] && hp_en=1; done
	[ "\$hp_en" = 1 ] || exit 0
fi

# Already shaping this device: a later ifup on the same L3 device (wan6 well
# after wan, a network reload that kept the device) has nothing to rebuild,
# and a restart here is an unshaped gap mid-game. A PPPoE redial recreates
# the device, so its qdiscs are gone and this falls through to the restart.
# UP / DN are 0 when that start left the direction unshaped (rate 0): no
# root qdisc or no IFB + ingress is then what "shaping" looks like. The
# shaper's table by name: the Ping Filter's qos_ex_pf puts itself back.
# The download hook is the WAN's ingress with its IFB, or the LAN device's
# clsact with its root qdisc (download_on lan).
hp_up="\$(sed -n 's/^UP=//p' "\$hp_st" 2>/dev/null)"
hp_dn="\$(sed -n 's/^DN=//p' "\$hp_st" 2>/dev/null)"
hp_wdev="\$(sed -n 's/^WAN=//p' "\$hp_st" 2>/dev/null)"
hp_ddev="\$(sed -n 's/^IFB=//p' "\$hp_st" 2>/dev/null)"
hp_dl=0
if [ "\$hp_dn" = 0 ]; then
	hp_dl=1
elif [ -n "\$hp_lan" ]; then
	tc qdisc show dev "\$hp_ddev" 2>/dev/null | awk '\$2 ~ /^(cake|hfsc|htb)\$/ && \$4 == "root" { r = 1 } \$2 == "clsact" { c = 1 } END { exit !(r && c) }' && hp_dl=1
else
	ip link show "\$hp_ddev" >/dev/null 2>&1 && \\
		tc qdisc show dev "\$hp_wdev" 2>/dev/null | awk '\$2 == "ingress" { i = 1 } END { exit !i }' && hp_dl=1
fi
if [ -n "\$hp_wdev" ] && { [ "\$hp_wdev" = "\$DEVICE" ] || [ "\$hp_lan" = "\$DEVICE" ]; } && [ "\$hp_dl" = 1 ] && \\
   tc qdisc show dev "\$hp_wdev" 2>/dev/null | awk -v u="\$hp_up" '\$2 ~ /^(cake|hfsc|htb)\$/ && \$4 == "root" { r = 1 } END { exit !(r || u == "0") }' && \\
   nft list tables inet 2>/dev/null | grep -qE '^table inet qos_ex_(simple|advanced|adaptive)\$'; then
	logger -t QoS-Ex-hotplug "ifup \$INTERFACE (\$DEVICE) - already shaping, nothing to do"
	exit 0
fi

# A dual-stack line brings wan and wan6 up moments apart and BOTH report the
# same L3 device, so this hook fires twice and used to queue two restarts
# five seconds after each other -- the second tore down the qdiscs the first
# had just built. mkdir is the atomic test-and-set busybox gives us.
#
# The lock carries a timestamp because the holder releases it from inside a
# backgrounded subshell: if procd reaps that process group mid-sleep the
# directory survives, and from then on every ifup -- every PPPoE redial for
# the rest of the uptime -- exits silently right here, so the shaper never
# comes back and only a reboot (tmpfs) clears it. Anything older than the
# debounce plus a generous apply window is treated as abandoned and taken
# over. Two hooks could in principle both judge it stale and both proceed;
# that is the pre-lock behaviour for one cycle, which start_service already
# tolerates by tearing down first, and it beats wedging until reboot.
# /var/run like the lifecycle lock: /tmp and /var/lock are world-writable, and
# a name there is one any user can hold.
mkdir -p /var/run 2>/dev/null
hp_lock="/var/run/$SCRIPT_NAME-hotplug.lock"
# Seconds since boot, not the wall clock: NTP steps it, often just as the WAN
# comes up, and a stepped clock made a live lock look stale.
read -r hp_now _ < /proc/uptime
hp_now=\${hp_now%%.*}
if mkdir "\$hp_lock" 2>/dev/null; then
	:
else
	hp_ts="\$(cat "\$hp_lock/ts" 2>/dev/null)"
	# Unset/garbage (a lock left by a pre-3.0.1.0 hook has no ts) reads as
	# epoch 0, i.e. always stale -- which is the outcome we want for it.
	case "\$hp_ts" in ""|*[!0-9]*) hp_ts=0 ;; esac
	# A timestamp ahead of the uptime is a wall-clock one from before 3.1.7.1.
	# A live lock: the event is left for the hook holding it (hp_again
	# below), as an ifup after its start can be a redial that recreated
	# the device.
	[ "\$hp_ts" -gt "\$hp_now" ] || [ \$((hp_now - hp_ts)) -gt 120 ] ||
		{ { echo "\$INTERFACE \$DEVICE" > "\$hp_lock/again"; } 2>/dev/null; exit 0; }
	logger -t QoS-Ex-hotplug "stale hotplug lock (\$((hp_now - hp_ts))s) - taking over"
	# Replace the stale lock rather than writing into it: two ifup events
	# seeing the same stale directory both proceeded.
	rm -rf "\$hp_lock" 2>/dev/null
	mkdir "\$hp_lock" 2>/dev/null || exit 0
fi
# Ownership token as well as a timestamp. The stale-takeover path above
# covers a holder that DIED, but not one that is merely slow: if its
# backgrounded stop+start runs past the window, a second hook takes over,
# and then the first finishes and rm -rf's the SECOND hook's lock while it
# is still applying -- after which a third acquires cleanly and runs
# concurrently with it. Only remove the lock if it is still ours.
hp_tok="\$\$-\$hp_now"
echo "\$hp_now" > "\$hp_lock/ts"
echo "\$hp_tok" > "\$hp_lock/tok"
logger -t QoS-Ex-hotplug "ifup \$INTERFACE (\$DEVICE) - restarting QoS-Ex in 5s"
(
	sleep 5
	# An ifup during the wait (wan6 just after wan) is served by this run.
	rm -f "\$hp_lock/again"
	# Explicit stop, then start, instead of one restart verb. The link
	# coming up is exactly when a start is most likely to land on top of a
	# still-running instance -- boot order, a PPPoE redial mid-session --
	# and an interrupted restart could leave the shaper half-applied with
	# no second chance. Two separate verbs mean the teardown is always
	# attempted and always completes before anything is rebuilt.
	if [ -x "$init" ]; then
		"$init" stop  >/dev/null 2>&1
		"$init" start >/dev/null 2>&1
	else
		"$self" stop  >/dev/null 2>&1
		"$self" start >/dev/null 2>&1
	fi
	# One that came while this ran goes through this hook again once the
	# lock is gone: if a redial recreated the device after the start, its
	# checks find it unshaped and restart; else it is already shaping.
	hp_again="\$(cat "\$hp_lock/again" 2>/dev/null)"
	[ "\$(cat "\$hp_lock/tok" 2>/dev/null)" = "\$hp_tok" ] && rm -rf "\$hp_lock" 2>/dev/null
	[ -z "\$hp_again" ] || ACTION=ifup INTERFACE="\${hp_again%% *}" DEVICE="\${hp_again#* }" \\
		sh /etc/hotplug.d/iface/99-$SCRIPT_NAME
) &
HPEOF
}

install_hotplug() {
	local self
	if [ -x "$QOS_EX_BIN" ]; then self="$QOS_EX_BIN"
	else self="$(readlink -f "$0" 2>/dev/null || echo "$0")"; fi
	# The init script first, so procd re-registers the PF instance.
	mkdir -p /etc/hotplug.d/iface 2>/dev/null
	emit_hotplug "$self" "/etc/init.d/$SCRIPT_NAME" | _stage_write /etc/hotplug.d/iface/99-$SCRIPT_NAME 755 || {
		ui_bad "could not write /etc/hotplug.d/iface/99-$SCRIPT_NAME"; return 1; }
	ui_note "ifup hook -> /etc/hotplug.d/iface/99-$SCRIPT_NAME"
}

remove_hotplug() {
	rm -f /etc/hotplug.d/iface/99-$SCRIPT_NAME
	msg "Hotplug removed"
}

enable_autostart() {
	if [ -f /etc/init.d/$SCRIPT_NAME ]; then
		/etc/init.d/$SCRIPT_NAME enable 2>/dev/null
	else
		install_init
	fi
	install_hotplug
	msg "Autostart enabled (init + hotplug)"
}

disable_autostart() {
	[ -f /etc/init.d/$SCRIPT_NAME ] && /etc/init.d/$SCRIPT_NAME disable 2>/dev/null
	remove_hotplug
	msg "Autostart disabled (init + hotplug)"
}

# One master verb at a time, on fd 8 (start / stop take the lifecycle lock
# on fd 9 inside): an enable and a disable that overlapped (a toggle while
# the first was still running) could end enabled with flow offload back on
# and autostart removed.
MASTER_LOCK="/var/run/qos-ex-master.lock"
_master_lock() {
	local _w=0
	command -v flock >/dev/null 2>&1 || return 0
	( : >> "$MASTER_LOCK" ) 2>/dev/null || return 0
	exec 8>> "$MASTER_LOCK"
	until flock -n 8; do
		[ "$_w" -ge 60 ] && { exec 8>&-; err "another enable / disable is still running"; return 1; }
		_w=$((_w + 1)); sleep 1
	done
	return 0
}
_master_unlock() { exec 8>&-; }

master_enable() {
	local _rc
	_master_lock || return 1
	uci -q set "$UCI_CFG.settings.enabled=1"
	uci -q commit "$UCI_CFG"
	enable_autostart
	qos_ex_disable_offload >/dev/null 2>&1
	start; _rc=$?    # start() re-reads UCI, so it sees enabled=1
	_master_unlock
	return $_rc
}

master_disable() {
	local _rc
	_master_lock || return 1
	uci -q set "$UCI_CFG.settings.enabled=0"
	uci -q commit "$UCI_CFG"
	stop; _rc=$?     # stop() also tears the PingFilter daemon down
	# Disabling QoS-Ex turns PF OFF (enabled=0), not just stopped.
	_pf_delegate disable >/dev/null 2>&1
	disable_autostart
	qos_ex_restore_offload
	_master_unlock
	# The stop's result, not the offload restore's.
	return $_rc
}

_find_luci_installer() {
	local here
	here="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
	local p
	# No $(pwd): the match runs as root, and CWD may be writable by anyone.
	for p in "$here/QoS-Ex-luci-app.sh" "/root/QoS-Ex-luci-app.sh"; do
		[ -f "$p" ] && { echo "$p"; return 0; }
	done
	return 1
}

_find_pf_installer() {
	local here p
	here="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
	# No $PWD: see _find_luci_installer.
	for p in "$here/QoS-Ex-PF.sh" "/root/QoS-Ex-PF.sh" \
	         "/usr/sbin/qos-ex-pf.sh"; do
		[ -f "$p" ] && { echo "$p"; return 0; }
	done
	return 1
}


# "v1 -> v2"; the one version when there was none before, or the same.
_ui_vv() { if [ -n "$1" ] && [ "$1" != "$2" ]; then echo "$1 -> $2"; else echo "$2"; fi; }
# The LuCI app's version, from the first line of its stylesheet; "" = none.
_ui_luci_ver() { sed -n '1s/.*qos-ex-luci \(v[0-9.]*\).*/\1/p' /www/luci-static/resources/qos-ex/qos-ex.css 2>/dev/null; }

install_all() {
	: > "$RUN_LOG" 2>/dev/null
	rm -f "$NFT_ERR" 2>/dev/null
	local self pf_sh luci_sh _st="" _hk=0 _sw _hw _lbl _osh _opf _olu _app=0
	self="$(resolve_self_path)"
	[ -f "$self" ] && chmod +x "$self" 2>/dev/null
	# What is installed before this run: an update says old -> new
	# (install_summary reads _osh and _app too).
	_osh=$(_ui_ver "$QOS_EX_BIN"); _opf=$(_ui_ver "$PF_BIN"); _olu=$(_ui_luci_ver)

	ui_head "install"
	ui_note "source $self -> $QOS_EX_BIN, config /etc/config/$UCI_CFG"

	# Autostart as it stands, read first: an update must not switch back on
	# what was switched off. No init script = on.
	_QOS_EX_AUTO=1
	[ -f /etc/init.d/$SCRIPT_NAME ] && ! _svc_enabled "$SCRIPT_NAME" && _QOS_EX_AUTO=0

	if [ -x /etc/init.d/$SCRIPT_NAME ]; then
		/etc/init.d/$SCRIPT_NAME stop >/dev/null 2>&1
		_st="the shaper"
	fi
	if [ -x "$PF_BIN" ]; then
		"$PF_BIN" stop >/dev/null 2>&1
		_st="${_st:+$_st and }Ping Filter"
	fi
	[ -n "$_st" ] && ui_ok "stopped $_st"
	# Old /tmp and /var/lock paths: nothing reads them now.
	# /var/run/QoS-Ex.lock: the mkdir lock before 3.1.6.9 (now flock on qos-ex.lock).
	rm -rf /tmp/qos-ex-pingfilter /var/lock/$SCRIPT_NAME.lock /var/lock/$SCRIPT_NAME-hotplug.lock \
		/var/run/$SCRIPT_NAME.lock 2>/dev/null
	rm -f /tmp/qos-ex.log /tmp/qos-ex-nft.err /tmp/qos-ex-pf-daemon.log \
		/tmp/qos-ex-pingfilter-nft.err /tmp/qos-ex-pingfilter-nft.err.* 2>/dev/null

	install_pkgs
	install_uci

	install_init    || _hk=1
	# Autostart off: the ifup hook is only refreshed where it still exists.
	if [ "$_QOS_EX_AUTO" = 1 ] || [ -f /etc/hotplug.d/iface/99-$SCRIPT_NAME ]; then
		install_hotplug || _hk=1
	fi
	sysup_keep_add
	install_sysup_reinstall || _hk=1
	install_fw4_include || _hk=1
	[ "$_hk" = 0 ] && ui_ok "shaper $(_ui_vv "$_osh" "v$VERSION"): $QOS_EX_BIN, its service and hooks"
	[ "$_QOS_EX_AUTO" = 1 ] || ui_info "start at boot was off - left off ($QOS_EX_BIN enable_autostart turns it on)"
	# Offload bypasses nft for established flows (DSCP and PF discovery). Off
	# here when enabled; otherwise left alone until `enable`.
	_sw=$(uci -q get firewall.@defaults[0].flow_offloading)
	_hw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
	if [ "$_sw" = 1 ] || [ "$_hw" = 1 ]; then
		if [ "$(uci -q get "$UCI_CFG.settings.enabled")" = "1" ]; then
			qos_ex_disable_offload >/dev/null 2>&1
			ui_ok "flow offloading turned off: offloaded traffic would skip the shaper"
		else
			ui_info "flow offloading is on: it is turned off when shaping is switched on"
		fi
	fi

	# QOS_EX_SKIP (QoS-Ex-install.sh): unchanged parts are left alone.
	if [ "${QOS_EX_SKIP#*pf}" != "${QOS_EX_SKIP:-}" ] && [ -x "$PF_BIN" ]; then
		ui_info "Ping Filter $_opf unchanged"
	elif pf_sh=$(_find_pf_installer); then
		if [ "$pf_sh" = "$PF_BIN" ]; then
			ui_info "Ping Filter $_opf already installed"
		else
			_ui_run "Ping Filter $(_ui_vv "$_opf" "$(_ui_ver "$pf_sh")")" sh "$pf_sh" install
		fi
	else
		ui_bad "Ping Filter: QoS-Ex-PF.sh not found - put it in /root and run install again"
		install_summary
		return 1
	fi

	if [ "${QOS_EX_SKIP#*luci}" != "${QOS_EX_SKIP:-}" ]; then
		ui_info "LuCI app${_olu:+ $_olu} unchanged"
	elif luci_sh=$(_find_luci_installer); then
		_ui_run "LuCI app $(_ui_vv "$_olu" "$(_ui_ver "$luci_sh")")" sh "$luci_sh" install && _app=1
	else
		ui_warn "LuCI app: QoS-Ex-luci-app.sh not found - not installed or updated"
	fi

	[ "$_QOS_EX_AUTO" = 1 ] && /etc/init.d/$SCRIPT_NAME enable >/dev/null 2>&1
	# settings.enabled ships 0: say so, or "started" reads as shaping.
	_lbl="QoS-Ex started"
	if [ "$(uci -q get "$UCI_CFG.settings.enabled")" != "1" ]; then
		_lbl="$_lbl - shaping is off"
		[ "$(uci -q get "$UCI_CFG.autosetup.done")" = 0 ] && _lbl="$_lbl until it is set up"
	fi
	_ui_run "$_lbl" start

	install_summary
}

# The result, the versions by module (LuCI app 1.x, Ping Filter 2.x, shaper
# 3.x) and the next step, from what the router has now. Reads install_all's
# _osh (a shaper was installed before) and _app (the LuCI app was installed).
install_summary() {
	local _w="" _lu _ip
	[ "$UI_WARNS" -gt 0 ] && _w=" ($UI_WARNS warning(s))"
	if [ "$UI_FAILS" -gt 0 ]; then
		printf '%s%s v%s install FAILED: %s error(s)%s - log %s%s\n' \
			"$UI_R" "$DISPLAY_NAME" "$VERSION" "$UI_FAILS" "$_w" "$RUN_LOG" "$UI_0"
		return 1
	fi
	_lu=$(_ui_luci_ver)
	printf '%s%s %s: app %s · PF %s · shaper v%s%s%s\n' "$UI_G" "$DISPLAY_NAME" \
		"$([ -n "$_osh" ] && echo updated || echo installed)" "${_lu:-not installed}" \
		"$(_ui_ver "$PF_BIN")" "$VERSION" "$_w" "$UI_0"
	_ip=$(uci -q get network.lan.ipaddr); _ip=${_ip%%[/ ]*}
	case "$_ip" in *[!0-9.]*) _ip="" ;; esac
	if [ "$(uci -q get "$UCI_CFG.autosetup.done")" = 0 ]; then
		echo "  Next: open LuCI${_ip:+ (http://$_ip)} > Network > QoS-Ex and run Auto Setup."
	elif [ "$(uci -q get "$UCI_CFG.settings.enabled")" != "1" ]; then
		echo "  Next: shaping is off - turn it on on the LuCI Overview, or run: $QOS_EX_BIN enable"
	elif [ "${_app:-0}" = 1 ]; then
		echo "  Next: log in to LuCI again - the app was reinstalled."
	fi
	return 0
}

uninstall_all() {
	local luci_sh self _keep=0
	case "${1:-}" in keep|--keep-config) _keep=1 ;; esac
	ui_head "uninstall"

	pf_stop >/dev/null 2>&1
	if [ -x /etc/init.d/$SCRIPT_NAME ]; then
		/etc/init.d/$SCRIPT_NAME stop    >/dev/null 2>&1
		/etc/init.d/$SCRIPT_NAME disable >/dev/null 2>&1
		ui_ok "shaper stopped and disabled"
	fi
	# Direct teardown too (init script already gone). Gated on the start
	# stamp: a WAN we are not shaping is not touched.
	if { [ -f /var/run/qos-ex-started ] || [ -f "$START_PART" ]; } && _lock; then
		_stop_locked >/dev/null 2>&1; _unlock
	fi

	if luci_sh=$(_find_luci_installer); then
		_ui_run "LuCI app removed" sh "$luci_sh" uninstall
		rm -f "$luci_sh" 2>/dev/null
	fi
	# The app's files when its installer is gone. The menu file stays when it
	# is the redirect stub (no views): a QoS-Ex address the browser returns to
	# after the logout then lands on Status instead of a 404.
	grep -q '"view"' /usr/share/luci/menu.d/luci-app-qos-ex.json 2>/dev/null &&
		rm -f /usr/share/luci/menu.d/luci-app-qos-ex.json
	rm -f /usr/share/rpcd/acl.d/luci-app-qos-ex.json \
		/usr/libexec/rpcd/qos-ex /usr/libexec/qos-ex-menu-refresh \
		/www/luci-static/resources/view/status/include/35_qos-ex*.js 2>/dev/null
	rm -rf /www/luci-static/resources/qos-ex /www/luci-static/resources/view/qos-ex \
		/tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null
	if [ -z "$luci_sh" ]; then
		# Reload rpcd and log LuCI sessions out: the browser keeps the menu.
		if [ -x /etc/init.d/rpcd ]; then
			/etc/init.d/rpcd reload >/dev/null 2>&1
			ubus -t 5 wait_for session >/dev/null 2>&1
			ubus call session list 2>/dev/null \
				| sed -n 's/.*"ubus_rpc_session": *"\([0-9a-f]\{32\}\)".*/\1/p' \
				| while read -r sid; do
					[ "$sid" = "00000000000000000000000000000000" ] && continue
					ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1
				done
		fi
		ui_ok "LuCI app removed (installer not found - files removed by path), LuCI sessions logged out"
	fi

	# PF owns its table, caches and binary: only its uninstaller removes them.
	if [ -x "$PF_BIN" ]; then
		_ui_run "PingFilter removed (firewall rules + $PF_BIN)" sh "$PF_BIN" uninstall
	fi

	cleanup_nft
	rm -f "$FW4_INC" /etc/nftables.d/35-qos-ex-pf-seen.nft 2>/dev/null
	ui_ok "nft tables, fw4 include, qdiscs and discovery hook removed"

	rm -f /etc/init.d/$SCRIPT_NAME 2>/dev/null
	rm -f /etc/rc.d/[SK][0-9][0-9]$SCRIPT_NAME 2>/dev/null
	rm -f /etc/hotplug.d/iface/99-$SCRIPT_NAME 2>/dev/null
	rm -rf /var/run/$SCRIPT_NAME-hotplug.lock /var/lock/$SCRIPT_NAME-hotplug.lock 2>/dev/null
	sysup_keep_del
	rm -f "$SYSUP_HOOK" 2>/dev/null

	# Before /etc/qos-ex goes: put flow offloading back as it was found.
	qos_ex_restore_offload >/dev/null 2>&1
	if [ "$_keep" = 1 ]; then
		# `uninstall keep`: settings and server history stay for a reinstall.
		grep -qxF /etc/qos-ex/ "$SYSUP_CONF" 2>/dev/null || echo /etc/qos-ex/ >> "$SYSUP_CONF"
		ui_ok "kept /etc/config/$UCI_CFG and /etc/qos-ex (uninstall keep)"
	else
		# One copy of the settings outlives the uninstall, until reboot:
		# mktemp + rename (a fixed /tmp name is anyone's to plant), and the
		# settings go only once the copy is made.
		local _bk=""
		if [ -f "/etc/config/$UCI_CFG" ]; then
			if _bk=$(mktemp /tmp/.qos-ex-bak.XXXXXX 2>/dev/null) && cp "/etc/config/$UCI_CFG" "$_bk" 2>/dev/null &&
			   mv -f "$_bk" "/tmp/$UCI_CFG.bak" 2>/dev/null; then
				ui_info "settings copied to /tmp/$UCI_CFG.bak (until reboot)"
				rm -f "/etc/config/$UCI_CFG" 2>/dev/null
			else
				rm -f "$_bk" 2>/dev/null
				ui_warn "settings kept: no backup could be made - delete /etc/config/$UCI_CFG yourself"
			fi
		fi
		rm -rf /etc/qos-ex 2>/dev/null
	fi
	rm -rf "$NFT_DIR" "$PF_RUN_DIR" "$PF_SIG" "$RELOAD_PEND" "$LOCK_FILE" "$MASTER_LOCK" 2>/dev/null
	# "$RUN_LOG".*: the trim stages through a mktemp suffix. The rpcd shim's
	# state cache, update check, run and its two locks, the LuCI installer's
	# lock, the speed test's result and lock, the package's first-run log and
	# the check script's report too.
	rm -f  "$NFT_ERR" "$PF_NFT_ERR" "$RUN_LOG" "$RUN_LOG".* /var/run/qos-ex-state.cache \
		/var/run/qos-ex-update.json /var/run/qos-ex-update.pid /var/run/qos-ex-act.* \
		/var/run/qos-ex-update.lock /var/run/qos-ex-update-run.lock /var/run/qos-ex-luci.lock \
		"$AS_RUN" "$AS_RUN.tmp" "$AS_SUGG" "$AS_LOCK" \
		/var/log/qos-ex-update.log /var/log/qos-ex-pkg-install.log /tmp/qos-ex-check.txt 2>/dev/null
	ui_ok "init, hotplug, config, caches and logs removed"

	self="$(resolve_self_path)"
	rm -f "$QOS_EX_BIN" "$QX_LIB" "$QX_LIVE" 2>/dev/null
	rmdir "${QX_LIB%/*}" 2>/dev/null
	rm -f /root/QoS-Ex-PF.sh /root/QoS-Ex-luci-app.sh /root/qos-ex-luci.tar.gz /root/QoS-Ex-install.sh /root/qos-ex-check.sh 2>/dev/null
	# Generic names: only when they are ours (the fetcher was install.sh until
	# LuCI 1.2.7.4; the install half carries its own header).
	grep -q 'QoS-Ex-install\.sh' /root/install.sh 2>/dev/null && rm -f /root/install.sh
	grep -q 'QoS-Ex shaper, install half' /root/lib/install.sh 2>/dev/null && rm -f /root/lib/install.sh
	rmdir /root/lib 2>/dev/null
	ui_ok "$QOS_EX_BIN and /root scripts removed"

	printf '%s%s removed%s\n' "$UI_G" "$DISPLAY_NAME" "$UI_0"
	# Last act: delete the running script; nothing after this is guaranteed.
	# Not gated on $self still existing: run as $QOS_EX_BIN it is gone by
	# now, and /root/QoS-Ex.sh was left behind.
	rm -f "$self" /root/QoS-Ex.sh 2>/dev/null
	return 0
}

# Sysupgrade keep-list (/etc/config/ is kept by default). Adds are idempotent;
# removal strips only our exact lines.
SYSUP_CONF="/etc/sysupgrade.conf"
SYSUP_HOOK="/etc/uci-defaults/99-qos-ex-reinstall"
# Re-install on the first boot after a sysupgrade: the installed files belong
# to no package, so sysupgrade drops them while /etc/config and /root stay.
# /etc/init.d/boot deletes a uci-defaults hook that exits 0, so this one exits
# non-zero to stay armed, and 0 only when /root holds no source (retires it).
emit_sysup_reinstall() {
	cat <<SUEOF
#!/bin/sh
# Auto-generated by $SCRIPT_NAME v$VERSION -- reinstalls after a sysupgrade.
# Non-zero exit keeps this uci-defaults script in place for the next upgrade.
[ -f "/root/$SCRIPT_NAME.sh" ] || exit 0
[ -x "$QOS_EX_BIN" ] && exit 1
logger -t $SCRIPT_NAME "backend missing after upgrade - reinstalling from /root/$SCRIPT_NAME.sh once a default route exists"
# Backgrounded and gated on a default route: uci-defaults run from
# /etc/init.d/boot, before netifd has a WAN. A sysupgrade drops the kmods and
# tools installed with apk/opkg, so install has to fetch them, and the LuCI
# app fetches Leaflet -- run inline here they failed without a network, and
# the firewall reload install does landed in the middle of boot.
(
	n=0
	while [ "\$n" -lt 600 ] && [ -z "\$(ip route show default 2>/dev/null)\$(ip -6 route show default 2>/dev/null)" ]; do
		sleep 10; n=\$((n + 10))
	done
	sh "/root/$SCRIPT_NAME.sh" install >/dev/null 2>&1
) </dev/null >/dev/null 2>&1 &
exit 1
SUEOF
}
install_sysup_reinstall() {
	mkdir -p /etc/uci-defaults 2>/dev/null
	emit_sysup_reinstall | _stage_write "$SYSUP_HOOK" 755 || { ui_bad "could not write $SYSUP_HOOK"; return 1; }
	ui_note "upgrade hook -> $SYSUP_HOOK"
}

sysup_keep_add() {
	local p
	# Last byte not a newline: add one, or our path joins the last line.
	if [ -s "$SYSUP_CONF" ] && [ -n "$(tail -c 1 "$SYSUP_CONF" 2>/dev/null)" ]; then
		echo "" >> "$SYSUP_CONF"
	fi
	for p in /etc/qos-ex/ /root/QoS-Ex.sh /root/lib/install.sh /root/QoS-Ex-PF.sh /root/QoS-Ex-luci-app.sh /root/qos-ex-luci.tar.gz /root/QoS-Ex-install.sh /root/qos-ex-check.sh "$SYSUP_HOOK"; do
		grep -qxF "$p" "$SYSUP_CONF" 2>/dev/null || echo "$p" >> "$SYSUP_CONF"
	done
}
sysup_keep_del() {
	[ -f "$SYSUP_CONF" ] || return 0
	local tmp rc
	tmp=$(mktemp "$SYSUP_CONF.XXXXXX" 2>/dev/null) || return 0
	grep -vxF -e /etc/qos-ex/ -e /root/QoS-Ex.sh -e /root/lib/install.sh -e /root/QoS-Ex-PF.sh \
	          -e /root/QoS-Ex-luci-app.sh -e /root/qos-ex-luci.tar.gz -e /root/QoS-Ex-install.sh -e /root/qos-ex-check.sh \
	          -e "$SYSUP_HOOK" "$SYSUP_CONF" > "$tmp" 2>/dev/null
	rc=$?
	# grep exits 1 when it filtered everything (a legitimate empty result);
	# above that, committing $tmp would wipe the user's other paths.
	if [ "$rc" -le 1 ]; then
		# mktemp is 0600; the file ships 0644.
		chmod 644 "$tmp" 2>/dev/null
		mv "$tmp" "$SYSUP_CONF" 2>/dev/null
	else
		rm -f "$tmp" 2>/dev/null
	fi
	return 0
}

# fw4 includes every /usr/share/nftables.d/ruleset-post/*.nft at the end of its
# ruleset on each start, restart and reload, so a firewall stop + start (`fw4
# flush` deletes every nft table) puts the shaper's table back. It names the
# rule sets loaded this boot ($NFT_DIR, tmpfs): a glob that matches nothing
# (stopped, not started yet) loads nothing and is not an error. Fixed text,
# written only when it differs (flash).
FW4_INC="/usr/share/nftables.d/ruleset-post/qos-ex.nft"
install_fw4_include() {
	local _l _t=""
	_l="include \"$NFT_DIR/qos_ex_*.nft\""
	[ "$(cat "$FW4_INC" 2>/dev/null)" = "$_l" ] && return 0
	mkdir -p "${FW4_INC%/*}" 2>/dev/null
	# Not *.nft until the rename: fw4 loads only those.
	_t=$(mktemp "${FW4_INC%/*}/.qos-ex.XXXXXX" 2>/dev/null) &&
		printf '%s\n' "$_l" > "$_t" && chmod 644 "$_t" && mv -f "$_t" "$FW4_INC" && return 0
	rm -f "$_t" 2>/dev/null
	ui_bad "could not write $FW4_INC"
	return 1
}

################################################################################
### AUTO SETUP: router check, line speed test, suggested settings            ###
################################################################################
# qos-ex.sh autosetup probe | speedtest | result | suggest [DOWN UP] [-p] |
#                     apply [all | steering | KEY ...] | undo
# The check only reads what the router exposes. Nothing changes until apply,
# which keeps a copy of the config for undo. Thresholds: autosetup section.
AS_RUN="/var/run/qos-ex-autosetup"         # speed test progress and result
AS_SUGG="/var/run/qos-ex-autosetup.sugg"   # the last suggestions, for apply
AS_LOCK="/var/run/qos-ex-autosetup.lock"
# The speed test's routing (_as_bind): its rules' priority and its table,
# before mwan3's rules (1001 up), pbr's and the main table.
AS_RT=900
AS_BAK="/etc/qos-ex/autosetup.bak"         # the config before the last apply
AS_STEER_BAK="/etc/qos-ex/autosetup.steering"
# The only keys apply writes: rpcd passes the user's choice through.
AS_KEYS="settings.wan settings.download_kbps settings.upload_kbps settings.qdisc settings.nft_mode settings.linklayer settings.overhead settings.download_on settings.lan settings.live_refresh hfsc.default_qdisc pingfilter.lite pingfilter.max_servers pingfilter.persist_interval network.packet_steering"
# Left blank by Reset to defaults until Auto Setup picks them (apply) or
# Manual setup takes the defaults (skip); the top-up skips them meanwhile.
AS_BLANK="settings.wan settings.download_kbps settings.upload_kbps settings.qdisc settings.nft_mode settings.linklayer settings.overhead pingfilter.lite"

# A number from the autosetup section; $2 when unset or not a number.
_as_num() {
	local _v
	_v=$(uci -q get "$UCI_CFG.autosetup.$1")
	if _isnum "$_v"; then echo "$_v"; else echo "$2"; fi
}

# $1 = key, $2 = key=value file
_as_kv() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }

# Uptime in hundredths of a second (whole-second sleeps drift).
_as_up100() { awk '{ printf "%.0f\n", $1 * 100 }' /proc/uptime; }

# kbps from two byte counters ($1 then $2) over $3 hundredths of a second.
# awk: counters pass 2^31; a 32-bit counter that wrapped once is put right.
_as_kbps() {
	awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN {
		d = b - a; if (d < 0) d += 4294967296
		if (t <= 0) { print 0; exit }
		printf "%.0f\n", d * 8 / 10 / t }'
}

# True when counter $2 is $3 or more bytes past $1.
_as_over() { awk -v a="$1" -v b="$2" -v c="$3" 'BEGIN { d = b - a; if (d < 0) d += 4294967296; exit !(d >= c) }'; }

# "busy% softirq% sirqmax%" between two copies of the /proc/stat cpuN lines:
# the busiest core's load and its softirq share, then the highest softirq
# share of any core (packet work: the core a queue runs on). idle + iowait
# count as idle.
_as_cpu_peak() {
	awk -v f="$1" '
		{ t = 0; for (i = 2; i <= NF; i++) t += $i }
		FILENAME == f { T[$1] = t; I[$1] = $5 + $6; S[$1] = $8; next }
		($1 in T) {
			d = t - T[$1]; if (d <= 0) next
			b = 100 - ($5 + $6 - I[$1]) * 100 / d
			s = ($8 - S[$1]) * 100 / d
			if (b > pb) { pb = b; ps = s }
			if (s > pm) pm = s
		}
		END { printf "%.0f %.0f %.0f\n", pb, ps, pm }' "$1" "$2"
}

# Packets the kernel dropped before any queue (its per-core backlog was
# full: the CPU did not keep up), summed over the cores of a copy of
# /proc/net/softnet_stat: column 2, hex.
_as_drops() {
	local _p _d _r _n=0
	[ -r "$1" ] || { echo 0; return 0; }
	while read -r _p _d _r; do
		case "$_d" in ''|*[!0-9a-fA-F]*) continue ;; esac
		_n=$((_n + 0x$_d))
	done < "$1"
	echo "$_n"
}

# Average of a ping summary in ms, rounded; empty when nothing came back.
_as_ping() {
	sed -n 's#.*min/avg/max[^=]*= *[0-9.]*/\([0-9.]*\)/.*#\1#p' "$1" 2>/dev/null |
		awk 'NR == 1 { printf "%.0f\n", $1 }'
}

# kbps -> Mbit, one decimal.
_as_mbit() { awk -v k="$1" 'BEGIN { printf "%.1f\n", k / 1000 }'; }

# $1 and the devices under it (VLAN -> port, bridge port), one a line.
_as_chain() {
	local _d="$1" _l _n=0
	while [ -n "$_d" ] && [ "$_n" -lt 4 ]; do
		echo "$_d"
		_l=""
		for _l in /sys/class/net/"$_d"/lower_*; do [ -e "$_l" ] && break; _l=""; done
		_d=${_l##*/lower_}
		_n=$((_n + 1))
	done
}

# Loaded, built in, or on disk for modprobe.
_as_kmod() {
	local _k
	_mod_loaded "$1" && return 0
	_k="/lib/modules/$(uname -r)"
	[ -e "$_k/$1.ko" ] && return 0
	grep -q "/$1\.ko" "$_k/modules.builtin" 2>/dev/null
}

# Sets AS_* from what the router exposes. Reads only.
# Board, cores and RAM, and the fingerprint made of them: a config restored
# on other hardware. Cheap (no package manager, no tc): LuCI asks on load.
_as_hw() {
	AS_BOARD=""; AS_MODEL=""
	[ -r /tmp/sysinfo/board_name ] && read -r AS_BOARD < /tmp/sysinfo/board_name
	[ -r /tmp/sysinfo/model ] && read -r AS_MODEL < /tmp/sysinfo/model
	# Cores: the online list, else the processor lines (_ncpu).
	_ncpu; AS_CORES=$_NCPU
	AS_MEM_MB=$(awk '/^MemTotal:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo 2>/dev/null)
	_isnum "$AS_MEM_MB" || AS_MEM_MB=0
	AS_HW="${AS_BOARD:-$AS_MODEL}/$AS_CORES/$AS_MEM_MB"
	AS_HW_SAVED=$(uci -q get "$UCI_CFG.autosetup.hw")
}

# True when the hardware recorded at setup (AS_HW_SAVED) is other hardware
# than this (AS_HW): another board or core count, or RAM more than 5% off.
# MemTotal leaves out the kernel's own size, so a new kernel (an OpenWrt
# upgrade) moves it a little: that is not new hardware.
_as_hw_moved() {
	local _s _n _sb _nb _sm _nm _d
	[ -n "$AS_HW_SAVED" ] && [ "$AS_HW_SAVED" != "$AS_HW" ] || return 1
	_sm=${AS_HW_SAVED##*/}; _s=${AS_HW_SAVED%/*}; _sb=${_s%/*}; _s=${_s##*/}
	_nm=${AS_HW##*/};       _n=${AS_HW%/*};       _nb=${_n%/*}; _n=${_n##*/}
	[ "$_sb" = "$_nb" ] && [ "$_s" = "$_n" ] || return 0
	_isnum "$_sm" && _isnum "$_nm" && [ "$_sm" -gt 0 ] || return 0
	_d=$((_sm - _nm)); [ "$_d" -lt 0 ] && _d=$((0 - _d))
	[ $((_d * 100)) -gt $((_sm * 5)) ]
}

# The fingerprint lines probe and hw print.
_as_hw_lines() {
	printf '%s\n' "hw=$AS_HW" "hw_saved=$AS_HW_SAVED" \
		"hw_changed=$(_as_hw_moved && echo 1 || echo 0)" \
		"setup_done=$(uci -q get "$UCI_CFG.autosetup.done")" \
		"undo=$([ -f "$AS_BAK" ] || [ -f "$AS_STEER_BAK" ] && echo 1 || echo 0)"
}

_as_probe() {
	local _f _v _caps="" _w _dev
	_as_hw
	AS_ARCH=$(uname -m 2>/dev/null)
	AS_REL=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null)
	# Fastest core in MHz; 0 = not exposed (most MIPS).
	AS_MHZ=0
	for _f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_max_freq; do
		_v=""; read -r _v 2>/dev/null < "$_f"
		_isnum "$_v" && [ $((_v / 1000)) -gt "$AS_MHZ" ] && AS_MHZ=$((_v / 1000))
	done
	if [ "$AS_MHZ" = 0 ]; then
		_v=$(awk -F: '/^cpu MHz/ { printf "%d\n", $2; exit }' /proc/cpuinfo 2>/dev/null)
		_isnum "$_v" && AS_MHZ=$_v
	fi
	# big.LITTLE: cores of more than one capacity.
	for _f in /sys/devices/system/cpu/cpu[0-9]*/cpu_capacity; do
		_v=""; read -r _v 2>/dev/null < "$_f"
		[ -n "$_v" ] || continue
		case " $_caps " in *" $_v "*) ;; *) _caps="$_caps $_v" ;; esac
	done
	AS_BIGLITTLE=no
	# shellcheck disable=SC2086  # one word per capacity
	[ "$(echo $_caps | wc -w)" -gt 1 ] && AS_BIGLITTLE=yes
	# The core type, for reports: ARM's implementer:part of each kind of core
	# (41:d03 = Cortex-A53; big.LITTLE lists two), else the model the CPU
	# gives (MIPS "cpu model", x86 "model name").
	AS_CPUPART=$(awk -F': *' '
		/^CPU implementer/ { i = $2 }
		/^CPU part/ { p = i ":" $2; gsub(/0x/, "", p); if (!(p in s)) { s[p] = 1; o = o (o == "" ? "" : ",") p } }
		END { print o }' /proc/cpuinfo 2>/dev/null)
	case "$AS_CPUPART" in *[!0-9a-fA-F:,]*) AS_CPUPART="" ;; esac
	AS_CPUMODEL=$(awk -F': *' '/^(cpu model|model name)/ { print $2; exit }' /proc/cpuinfo 2>/dev/null |
		sed 's/[^A-Za-z0-9 ._()@-]//g' | cut -c1-48)
	AS_MEMFREE_KB=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null)
	_isnum "$AS_MEMFREE_KB" || AS_MEMFREE_KB=0
	# The overlay's size and free space; 0 when there is none.
	AS_FLASH_MB=0; AS_FLASH_FREE_MB=0
	if [ -d /overlay ]; then
		_v=$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 { printf "%d %d\n", $2 / 1024, $4 / 1024 }')
		AS_FLASH_MB=${_v% *}; AS_FLASH_FREE_MB=${_v#* }
		_isnum "$AS_FLASH_MB" || AS_FLASH_MB=0
		_isnum "$AS_FLASH_FREE_MB" || AS_FLASH_FREE_MB=0
	fi
	# WAN: the one set while a default route uses it (with two lines, Setup's
	# choice stays), else the line in use (_wan_live), else the one set: a
	# fresh config may name eth0 when the line was not up at install. Then
	# that interface's protocol and its L2 device (a PPPoE device has none
	# below it in sysfs), and AS_WAN_ALL: every default-route line's device.
	AS_WAN_CFG=$(uci -q get "$UCI_CFG.settings.wan")
	AS_WAN_LIVE=$(_wan_live)
	case "$AS_WAN_LIVE" in *[!A-Za-z0-9._-]*) AS_WAN_LIVE="" ;; esac
	AS_WAN=${AS_WAN_LIVE:-$AS_WAN_CFG}
	AS_WAN_ALL=""; AS_PROTO=""; _dev=""
	if [ -f /lib/functions/network.sh ] && [ -f /usr/share/libubox/jshn.sh ]; then
		# A subshell: network.sh sources jshn.sh unguarded (see _wan_live).
		_v=$(
			. /lib/functions/network.sh 2>/dev/null
			command -v network_get_device >/dev/null 2>&1 || exit 0
			_l=""; _wan_ifs _l
			_all="" _wi="" _wc=""
			for _i in $_l; do
				_d=""; network_get_device _d "$_i" 2>/dev/null
				case "$_d" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
				_all="${_all:+$_all }$_d"
				[ "$_d" = "$AS_WAN_CFG" ] && [ -z "$_wc" ] && _wc=$_i
				[ "$_d" = "$AS_WAN" ] && [ -z "$_wi" ] && _wi=$_i
			done
			_u=$AS_WAN; [ -n "$_wc" ] && { _u=$AS_WAN_CFG; _wi=$_wc; }
			_d=""; _p=""
			[ -n "$_wi" ] && { network_get_physdev _d "$_wi" 2>/dev/null; _p=$(uci -q get "network.$_wi.proto"); }
			echo "$_all|$_u|$_p|$_d"
		)
		case "$_v" in *"|"*"|"*"|"*)
			AS_WAN_ALL=${_v%%|*}; _v=${_v#*|}
			AS_WAN=${_v%%|*}; _v=${_v#*|}
			AS_PROTO=${_v%%|*}; _dev=${_v#*|} ;;
		esac
	fi
	# LAN: the lan interface's device, and how many devices carry an up
	# interface besides the WAN's (download_on lan shapes one device: with
	# a second, guest or IoT, the download on it would go unshaped).
	AS_LAN=""; AS_LAN_N=0
	if [ -f /lib/functions/network.sh ] && [ -f /usr/share/libubox/jshn.sh ] && command -v ubus >/dev/null 2>&1; then
		_v=$(
			# shellcheck disable=SC1091
			. /lib/functions/network.sh 2>/dev/null
			command -v network_get_device >/dev/null 2>&1 || exit 0
			_ld=""; network_get_device _ld lan 2>/dev/null
			_n=""
			for _i in $(ubus -t 3 list 'network.interface.*' 2>/dev/null); do
				_i=${_i#network.interface.}
				[ "$_i" = loopback ] && continue
				network_is_up "$_i" 2>/dev/null || continue
				_d=""; network_get_device _d "$_i" 2>/dev/null
				{ [ -n "$_d" ] && [ "$_d" != "$AS_WAN" ] && [ "$_d" != lo ]; } || continue
				case " $_n " in *" $_d "*) ;; *) _n="$_n $_d" ;; esac
			done
			# shellcheck disable=SC2086 # the device names, counted
			set -- $_n
			echo "$_ld $#"
		)
		case "$_v" in *" "*) AS_LAN=${_v% *}; AS_LAN_N=${_v##* } ;; esac
		case "$AS_LAN" in *[!A-Za-z0-9._-]*) AS_LAN="" ;; esac
		_isnum "$AS_LAN_N" || AS_LAN_N=0
	fi
	# Port speed (Mbit), driver and queues: the first device down the chain
	# that reports a speed. VLAN anywhere on it adds 4 bytes a packet.
	AS_VLAN=no; AS_SPEED=0; AS_PORT=""; AS_DRIVER=""; AS_RXQ=0; AS_TXQ=0
	for _f in $(_as_chain "$AS_WAN"; [ -n "$_dev" ] && [ "$_dev" != "$AS_WAN" ] && _as_chain "$_dev"); do
		[ -e "/proc/net/vlan/$_f" ] && AS_VLAN=yes
		[ "$AS_SPEED" = 0 ] || continue
		_v=""; read -r _v 2>/dev/null < "/sys/class/net/$_f/speed"
		_isnum "$_v" && [ "$_v" -gt 0 ] || continue
		AS_SPEED=$_v; AS_PORT=$_f
		_v=$(readlink "/sys/class/net/$_f/device/driver" 2>/dev/null)
		AS_DRIVER=${_v##*/}
		AS_RXQ=$(ls -d /sys/class/net/"$_f"/queues/rx-* 2>/dev/null | wc -l)
		AS_TXQ=$(ls -d /sys/class/net/"$_f"/queues/tx-* 2>/dev/null | wc -l)
	done
	# DSL modem: the trained line rates and ATM (ADSL) or PTM (VDSL).
	AS_DSL=""; AS_DSL_DN=0; AS_DSL_UP=0
	if command -v jsonfilter >/dev/null 2>&1 && ubus -t 2 list dsl >/dev/null 2>&1; then
		_v=$(ubus -t 3 call dsl metrics 2>/dev/null)
		if [ "$(printf '%s' "$_v" | jsonfilter -e '@.up' 2>/dev/null)" = true ]; then
			case "$(printf '%s' "$_v" | jsonfilter -e '@.mode' 2>/dev/null)" in
				*VDSL*) AS_DSL=ptm ;;
				*ADSL*) AS_DSL=atm ;;
			esac
			_f=$(printf '%s' "$_v" | jsonfilter -e '@.downstream.data_rate' 2>/dev/null)
			_isnum "$_f" && AS_DSL_DN=$((_f / 1000))
			_f=$(printf '%s' "$_v" | jsonfilter -e '@.upstream.data_rate' 2>/dev/null)
			_isnum "$_f" && AS_DSL_UP=$((_f / 1000))
		fi
	fi
	AS_MODS_MISSING=""
	for _f in sch_cake sch_hfsc sch_htb act_ctinfo act_mirred ifb; do
		_as_kmod "$_f" || AS_MODS_MISSING="${AS_MODS_MISSING:+$AS_MODS_MISSING }$_f"
	done
	AS_PKG_MISSING=$(_pkg_missing "$(_pkg_mgr)" 2>/dev/null)
	AS_OFFLOAD_SW=$(uci -q get firewall.@defaults[0].flow_offloading || echo 0)
	AS_OFFLOAD_HW=$(uci -q get firewall.@defaults[0].flow_offloading_hw || echo 0)
	# Unset = netifd's default (on since 24.10); 0 off, 2 all CPUs.
	AS_STEER=$(uci -q get network.@globals[0].packet_steering)
	AS_CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
	# Another shaper's root qdisc on the WAN caps a speed test.
	AS_FOREIGN=no
	_v=$(tc qdisc show dev "$AS_WAN" root 2>/dev/null | awk 'NR == 1 { print $2 }')
	case "$_v" in cake|cake_mq|hfsc|htb|tbf) _dev_ours "$AS_WAN" || AS_FOREIGN=$_v ;; esac
	# Tier: low = one core, little RAM (low_ram_mb) or MIPS; high = x86, or
	# high_cores+ cores at high_mhz+ with high_ram_mb+ RAM; else mid. The
	# figures are the router's own: a CPU speed it does not report counts as
	# 0, and a 1 GB router reports under 1024 MB, so both are mid. It picks
	# the queue (queue_<tier>), the rule set (rules_<tier>) and Ping Filter
	# Lite.
	AS_TIER=mid
	case "$AS_ARCH" in mips*) AS_TIER=low ;; esac
	[ "$AS_CORES" -le 1 ] && AS_TIER=low
	[ "$AS_MEM_MB" -gt 0 ] && [ "$AS_MEM_MB" -le "$(_as_num low_ram_mb 128)" ] && AS_TIER=low
	if [ "$AS_TIER" = mid ]; then
		case "$AS_ARCH" in x86_64|i[3-6]86) AS_TIER=high ;; esac
		[ "$AS_CORES" -ge "$(_as_num high_cores 4)" ] && [ "$AS_MHZ" -ge "$(_as_num high_mhz 1500)" ] &&
			[ "$AS_MEM_MB" -ge "$(_as_num high_ram_mb 1024)" ] && AS_TIER=high
	fi
	return 0
}

# The router check's key=value lines (probe, suggest -p).
_as_probe_out() {
	printf '%s\n' "board=$AS_BOARD" "model=$AS_MODEL" "release=$AS_REL" "arch=$AS_ARCH" \
		"cores=$AS_CORES" "mhz=$AS_MHZ" "biglittle=$AS_BIGLITTLE" "cpu_part=$AS_CPUPART" \
		"cpu_model=$AS_CPUMODEL" "mem_mb=$AS_MEM_MB" \
		"flash_mb=$AS_FLASH_MB" "flash_free_mb=$AS_FLASH_FREE_MB" \
		"wan=$AS_WAN" "wan_cfg=$AS_WAN_CFG" "wan_proto=$AS_PROTO" "wan_vlan=$AS_VLAN" "wan_port=$AS_PORT" \
		"wan_speed=$AS_SPEED" "wan_driver=$AS_DRIVER" "wan_rxq=$AS_RXQ" "wan_txq=$AS_TXQ" \
		"dsl=$AS_DSL" "dsl_down_kbps=$AS_DSL_DN" "dsl_up_kbps=$AS_DSL_UP" \
		"kmods_missing=$AS_MODS_MISSING" "pkgs_missing=$AS_PKG_MISSING" \
		"offload_sw=$AS_OFFLOAD_SW" "offload_hw=$AS_OFFLOAD_HW" "packet_steering=$AS_STEER" \
		"conntrack_max=$AS_CT_MAX" "foreign_shaper=$AS_FOREIGN" "tier=$AS_TIER"
	_as_hw_lines
}

autosetup_probe() { _as_probe; _as_probe_out; }

# Set up (1) or offered (0); $2 = the hardware fingerprint to record. LuCI
# shows its Auto Setup tab only while done is 0 (the menu's uci depends) and
# keeps the menu it built in /tmp/luci-indexcache.*.json: that copy goes,
# so the next page load builds the menu again.
_as_done() {
	uci -q get "$UCI_CFG.autosetup" >/dev/null || uci -q set "$UCI_CFG.autosetup=autosetup"
	uci -q set "$UCI_CFG.autosetup.done=$1"
	[ -z "${2:-}" ] || uci -q set "$UCI_CFG.autosetup.hw=$2"
	uci -q commit "$UCI_CFG"
	rm -f /tmp/luci-indexcache* 2>/dev/null
}

# The QoS-Ex defaults for what a reset left blank and Auto Setup did not
# set. The top-up makes a uci call per option, so it runs only then.
_as_fill() {
	local _k
	for _k in $AS_BLANK; do
		[ -n "$(uci -q get "$UCI_CFG.$_k")" ] && continue
		uci_migrate >/dev/null 2>&1
		return 0
	done
}

# Set up by hand (LuCI's Manual setup): not offered again on this hardware.
autosetup_skip() {
	_as_hw
	_as_done 1 "$AS_HW"
	_as_fill
	return 0
}

# Reset to defaults: the settings Auto Setup picks are left blank, not
# preset, and LuCI's Auto Setup tab is back.
autosetup_blank() {
	local _k
	for _k in $AS_BLANK; do uci -q delete "$UCI_CFG.$_k"; done
	_as_done 0
}

# Run again (Maintenance -> Run Auto Setup): LuCI's Auto Setup tab is back
# until it is applied or Manual setup is chosen. Settings stay.
autosetup_again() { _as_done 0; }

### Speed test: Cloudflare's speed endpoints over plain HTTP (no TLS cost on
### a slow CPU), several uclient-fetch streams, the rate from the WAN byte
### counters - so other traffic on the line counts too. Shaping is stopped
### for the test and started again after.

_as_save() {
	printf '%s\n' "phase=$AS_PHASE" "progress=${AS_PROG:-0}" "now_kbps=${AS_NOW:-0}" \
		"down_kbps=$AS_DN" "up_kbps=$AS_UP" "ping_idle=$AS_P0" "ping_down=$AS_PD" "ping_up=$AS_PU" \
		"cpu_down=$AS_CD" "sirq_down=$AS_SD" "sirqmax_down=$AS_MD" "drops_down=$AS_RD" \
		"cpu_up=$AS_CU" "sirq_up=$AS_SU" "sirqmax_up=$AS_MU" "drops_up=$AS_RU" \
		"limit_down=$AS_LD" "limit_up=$AS_LU" "fit_rate=$AS_FR" "fit_now=$AS_FN" \
		"fail_down=$AS_FD" "fail_up=$AS_FU" "src_down=$AS_SDN" "src_up=$AS_SUP" "ls_server=$AS_LSN" \
		"fit_cake=$AS_FCAKE" "fit_hfsc=$AS_FHFSC" "fit_htb=$AS_FHTB" "streams=$AS_STREAMS" "secs=$AS_SECS" \
		"wan=$AS_WAN" "bound=${AS_BOUND:-0}" "msg=$AS_MSG" "at=$(($(_as_up100) / 100))" > "$AS_RUN.tmp" 2>/dev/null &&
		mv -f "$AS_RUN.tmp" "$AS_RUN"
}

# One stream: a fetch at a time until the stop file shows. Its PID goes to $2
# so the end can stop a transfer in flight. uclient-fetch holds a whole POST
# body in RAM, so uploads repeat a small file.
_as_stream() {   # $1 = stop file, $2 = PID file, $3.. = uclient-fetch arguments
	local _s="$1" _p="$2"
	shift 2
	while [ ! -e "$_s" ]; do
		# Not -q: it hides why a fetch failed (HTTP error, connection).
		uclient-fetch -O /dev/null "$@" </dev/null >/dev/null 2>"${_s%/*}/log.${_p##*.}" &
		echo "$!" > "$_p"
		# A failed fetch (no route, refused) must not spin; its reason is
		# kept for the result. A fetch stopped at the end is not a failure.
		if ! wait "$!"; then
			[ -e "$_s" ] || grep -E 'error|failed|Failed|refused|reset|timed out|Cannot' "${_s%/*}/log.${_p##*.}" 2>/dev/null |
				tail -n 1 > "${_s%/*}/fail"
			sleep 1
		fi
	done
}

# Stop the stream loops ($@) and the fetch each one is in. A PID file is only
# acted on while it still names uclient-fetch (PIDs are reused). From the
# third try KILL: a fetch still connecting to a server that never answers
# ignores TERM (uloop only notes it) until its connect timeout, and kept
# the speed test's lock.
_as_kill() {
	local _f _p _c _live _try=0 _sig=TERM
	[ -n "$AS_TMP" ] && : > "$AS_TMP/stop"
	while [ "$_try" -lt 5 ]; do
		[ "$_try" -ge 2 ] && _sig=KILL
		for _f in "$AS_TMP"/pid.*; do
			[ -f "$_f" ] || continue
			_p=""; read -r _p < "$_f"
			_c=""; read -r _c 2>/dev/null < "/proc/$_p/comm"
			[ "$_c" = uclient-fetch ] && kill -"$_sig" "$_p" 2>/dev/null
		done
		_live=""
		for _p in "$@"; do kill -0 "$_p" 2>/dev/null && _live=1; done
		[ -n "$_live" ] || break
		sleep 1
		_try=$((_try + 1))
	done
	for _p in "$@"; do kill "$_p" 2>/dev/null; done
	for _p in "$@"; do wait "$_p" 2>/dev/null; done
	rm -f "$AS_TMP"/pid.* 2>/dev/null
	AS_PIDS=""
}

# One direction ($1 = down | up). The first 2 s (slow start) are not counted,
# then AS_SECS, or less once test_mb has crossed the WAN. Sets AS_KBPS,
# AS_CPU / AS_SIRQ (busiest core), AS_SQMAX (the core with the most packet
# work), AS_DROP (packets the kernel dropped before a queue), AS_PING (loaded
# latency) and AS_FAIL (the last failed fetch's reason, empty when none
# failed).
_as_dir() {
	local _ctr _i=0 _n=0 _bs _b0="" _now _prev _u0 _u1 _cap _pp="" _c
	# IPv4 only: _as_bind routes the test out through AS_WAN, and IPv6 can
	# run on another line. The test server's URLs, or a LibreSpeed server's
	# once _as_ls_use has moved that direction.
	if [ "$1" = down ]; then
		_ctr="/sys/class/net/$AS_WAN/statistics/rx_bytes"
		set -- -4 "$AS_DLU"
	else
		_ctr="/sys/class/net/$AS_WAN/statistics/tx_bytes"
		set -- -4 --post-file="$AS_TMP/up" "$AS_ULU"
	fi
	rm -f "$AS_TMP/stop" "$AS_TMP/ping" "$AS_TMP/fail"
	AS_PIDS=""
	while [ "$_n" -lt "$AS_STREAMS" ]; do
		_as_stream "$AS_TMP/stop" "$AS_TMP/pid.$_n" "$@" &
		AS_PIDS="$AS_PIDS $!"
		_n=$((_n + 1))
	done
	_cap=$(($(_as_num test_mb 1500) * 1000000))
	read -r _bs < "$_ctr"; _prev=$_bs
	_u0=$(_as_up100)
	# Replaced after the warm-up; kept when the cap ends the test inside it.
	grep '^cpu[0-9]' /proc/stat > "$AS_TMP/cpu0"
	cat /proc/net/softnet_stat > "$AS_TMP/sn0" 2>/dev/null
	while [ "$_i" -lt $((AS_SECS + 2)) ]; do
		sleep 1
		_i=$((_i + 1))
		read -r _now < "$_ctr"
		AS_NOW=$(_as_kbps "$_prev" "$_now" 100)
		_prev=$_now
		if [ "$_i" = 2 ]; then
			_b0=$_now; _u0=$(_as_up100)
			grep '^cpu[0-9]' /proc/stat > "$AS_TMP/cpu0"
			cat /proc/net/softnet_stat > "$AS_TMP/sn0" 2>/dev/null
			# Without the lock's fd: a test stopped meanwhile must not leave it
			# held by a ping still running (_as_end stops it as well).
			ping -q -c "$AS_SECS" -W 2 "$AS_PING_HOST" > "$AS_TMP/ping" 2>&1 6>&- &
			_pp=$!; AS_PP=$_pp
		fi
		AS_PROG=$((_i * 100 / (AS_SECS + 2)))
		_as_save
		_as_over "$_bs" "$_now" "$_cap" && break
	done
	read -r _now < "$_ctr"; _u1=$(_as_up100)
	grep '^cpu[0-9]' /proc/stat > "$AS_TMP/cpu1"
	cat /proc/net/softnet_stat > "$AS_TMP/sn1" 2>/dev/null
	# A cap reached inside the warm-up: count from the start.
	[ -n "$_b0" ] || _b0=$_bs
	# shellcheck disable=SC2086  # a PID list
	_as_kill $AS_PIDS
	AS_KBPS=$(_as_kbps "$_b0" "$_now" $((_u1 - _u0)))
	_c=$(_as_cpu_peak "$AS_TMP/cpu0" "$AS_TMP/cpu1")
	AS_CPU=${_c%% *}; _c=${_c#* }; AS_SIRQ=${_c% *}; AS_SQMAX=${_c#* }
	AS_DROP=$(($(_as_drops "$AS_TMP/sn1") - $(_as_drops "$AS_TMP/sn0")))
	[ "$AS_DROP" -ge 0 ] || AS_DROP=0
	# SIGINT: ping prints its summary (SIGTERM does not).
	if [ -n "$_pp" ]; then
		kill -INT "$_pp" 2>/dev/null
		wait "$_pp" 2>/dev/null
	fi
	AS_PP=""
	AS_PING=$(_as_ping "$AS_TMP/ping")
	AS_FAIL=""; [ -s "$AS_TMP/fail" ] && read -r AS_FAIL < "$AS_TMP/fail"
	AS_NOW=0
}

# What held the rate: the WAN port, the router's CPU, or the line. A test
# that filled the port was held by the port, however busy a core was.
_as_limit() {   # $1 = kbps, $2 = busiest core %
	if [ "$AS_SPEED" -gt 0 ] && [ "$1" -ge $((AS_SPEED * 900)) ]; then echo port
	elif [ "${2:-0}" -ge "$(_as_num cpu_busy_pct 90)" ]; then echo router
	else echo line; fi
}

# The IPv4 addresses of host $1, one a line: itself when it is one, else the
# resolver's (BusyBox nslookup prints "Address: a.b.c.d"; the line naming
# the DNS server carries its port).
_as_ip4() {
	case "$1" in
		'') ;;
		*[!0-9.]*) nslookup "$1" 2>/dev/null | awk '$1 ~ /^Address/ && $NF ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $NF !~ /^127\./ { print $NF }' | sort -u ;;
		*) echo "$1" ;;
	esac
}

# The test out through AS_WAN, whatever line the router's own traffic takes
# (failover by metric, load balancing, pbr): the router's own packets (iif
# lo: LAN traffic keeps its line) to the test server ($1) and the other
# hosts ($2 ...: the ping host, a LibreSpeed server) follow rules before
# mwan3's and pbr's to table AS_RT, which holds one
# default route over the WAN. A rule on the address alone: one with ipproto
# or a port stops matching once mwan3 marks the packet in output and the
# kernel routes it again (measured), and the packet left by the other line
# with the WAN's address. False, with nothing left, when the WAN has no
# default route, the server's name does not resolve, another tool's rule
# uses the table, or a rule is refused.
_as_bind() {
	local _l _gw _a _s _h
	_as_unbind
	ip -4 rule show 2>/dev/null | grep -qw "lookup $AS_RT" && return 1
	_s=$(_as_ip4 "$1")
	[ -n "$_s" ] || return 1
	shift
	_l=$(ip -4 route show table all default dev "$AS_WAN" 2>/dev/null | head -n 1)
	[ -n "$_l" ] || return 1
	_gw=$(printf '%s\n' "$_l" | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')
	ip -4 route add default ${_gw:+via "$_gw"} dev "$AS_WAN" table "$AS_RT" 2>/dev/null || return 1
	for _a in $({ printf '%s\n' "$_s"; for _h in "$@"; do _as_ip4 "$_h"; done; } | sort -u); do
		ip -4 rule add pref "$AS_RT" to "$_a" iif lo lookup "$AS_RT" 2>/dev/null || { _as_unbind; return 1; }
	done
}

# _as_bind's rules out, then its table once no rule uses it (also what a
# test stopped hard left behind).
_as_unbind() {
	local _n=0
	while [ "$_n" -lt 64 ] && ip -4 rule del pref "$AS_RT" lookup "$AS_RT" 2>/dev/null; do _n=$((_n + 1)); done
	ip -4 rule show 2>/dev/null | grep -qw "lookup $AS_RT" || ip -4 route flush table "$AS_RT" >/dev/null 2>&1
	AS_BOUND=""
}

### LibreSpeed: the test server (test_url, Cloudflare's) first. A part of
### the test that gets almost nothing from it runs again from a LibreSpeed
### server, and that direction stays there for the rest of the test.

# The part just measured got almost nothing from its server: under 100
# kbit/s, or a request refused with an HTTP error (429: too many tests).
_as_bad() {
	[ "$AS_KBPS" -lt 100 ] && return 0
	case "$AS_FAIL" in *"HTTP error"*) return 0 ;; esac
	return 1
}

# What _as_dir measured, as the download ($1 = down) or the upload, from
# server $2 (the test server's host, or librespeed).
_as_take() {
	if [ "$1" = down ]; then
		AS_DN=$AS_KBPS; AS_CD=$AS_CPU; AS_SD=$AS_SIRQ; AS_PD=$AS_PING; AS_FD=$AS_FAIL
		AS_MD=$AS_SQMAX; AS_RD=$AS_DROP; AS_LD=$(_as_limit "$AS_DN" "$AS_CD"); AS_SDN=$2
	else
		AS_UP=$AS_KBPS; AS_CU=$AS_CPU; AS_SU=$AS_SIRQ; AS_PU=$AS_PING; AS_FU=$AS_FAIL
		AS_MU=$AS_SQMAX; AS_RU=$AS_DROP; AS_LU=$(_as_limit "$AS_UP" "$AS_CU"); AS_SUP=$2
	fi
}

# One half of the test ($1 = down | up). Almost nothing from the test
# server: the half again from LibreSpeed (_as_ls_use), and the higher of
# the two readings counts.
_as_half() {
	local _k
	_as_dir "$1"
	_as_take "$1" "$AS_SRVH"
	if _as_bad && _as_ls_use "$1" "the ${1}load" "${AS_FAIL:-almost nothing}"; then
		_k=$AS_KBPS
		_as_dir "$1"
		[ "$AS_KBPS" -gt "$_k" ] && _as_take "$1" librespeed
	fi
	return 0
}

# One LibreSpeed server as a candidate line "index host download-URL
# upload-URL name", plain HTTP whatever scheme the list gives; nothing when
# the host or a path holds anything else (the list is data from the
# internet). $1 index, $2 server, $3 / $4 download / upload paths, $5 name.
_as_ls_add() {
	local _b _hp _h _pa _d=${3#/} _u=${4#/} _m
	_b=${2#https:}; _b=${_b#http:}
	case "$_b" in //?*) ;; *) return 1 ;; esac
	_b=${_b#//}; _hp=${_b%%/*}; _pa=${_b#"$_hp"}; _h=${_hp%:*}
	case "$_hp" in *[!A-Za-z0-9.:-]*) return 1 ;; esac
	case "$_h" in ''|-*|*[!A-Za-z0-9.-]*) return 1 ;; esac
	case "$_pa/$_d/$_u" in *[!A-Za-z0-9._~/-]*) return 1 ;; esac
	[ -n "$_d" ] && [ -n "$_u" ] || return 1
	_m=$(printf '%s' "$5" | tr -cd 'A-Za-z0-9 ,.()&+-' | cut -c1-60)
	_b="http://$_hp${_pa%/}"
	printf '%s %s %s %s %s\n' "$1" "$_h" "$_b/$_d?ckSize=100" "$_b/$_u" "${_m:-$_h}"
}

# The LibreSpeed server, once a test: autosetup.fallback_url (the folder
# that holds garbage.php and empty.php), else from fallback_list (the
# public list): all pinged at once, then the three nearest asked in turn
# for 1 MB; the first that sends it and does not redirect (to HTTPS: TLS
# would cap a small router's reading at its CPU). Sets AS_LSH AS_LSDL
# AS_LSUL AS_LSN.
_as_ls_pick() {
	local _f="$AS_TMP/ls" _u _n _i=0 _s _d _p _m _h _ms _pids=""
	mkdir -p "$_f" || return 1
	_u=$(uci -q get "$UCI_CFG.autosetup.fallback_url")
	if [ -n "$_u" ]; then
		_m=${_u#*://}; _m=${_m%%/*}
		_as_ls_add 0 "$_u" garbage.php empty.php "$_m" > "$_f/c" || return 1
	else
		_u=$(uci -q get "$UCI_CFG.autosetup.fallback_list")
		case "$_u" in http://*|https://*) ;; *) return 1 ;; esac
		command -v jsonfilter >/dev/null 2>&1 || return 1
		uclient-fetch -4 -q -T 10 -O "$_f/list" "$_u" </dev/null >/dev/null 2>&1 6>&- || return 1
		_n=$(jsonfilter -i "$_f/list" -e '@[*].server' 2>/dev/null | wc -l)
		: > "$_f/c"
		while [ "$_i" -lt "$_n" ] && [ "$_i" -lt 64 ]; do
			jsonfilter -i "$_f/list" -e "@[$_i].server" -e "@[$_i].dlURL" -e "@[$_i].ulURL" -e "@[$_i].name" > "$_f/e" 2>/dev/null
			_s=""; _d=""; _p=""; _m=""
			{ read -r _s; read -r _d; read -r _p; read -r _m; } < "$_f/e"
			_as_ls_add "$_i" "$_s" "$_d" "$_p" "$_m" >> "$_f/c"
			_i=$((_i + 1))
		done
	fi
	[ -s "$_f/c" ] || return 1
	while read -r _i _h _d _p _m; do
		ping -q -c 2 -W 1 "$_h" > "$_f/p$_i" 2>&1 6>&- &
		_pids="$_pids $!"
	done < "$_f/c"
	# shellcheck disable=SC2086  # a PID list
	wait $_pids 2>/dev/null
	# Nearest first, no answer last.
	while read -r _i _h _d _p _m; do
		_ms=$(_as_ping "$_f/p$_i")
		echo "${_ms:-99999} $_i $_h $_d $_p $_m"
	done < "$_f/c" | sort -n | head -n 3 > "$_f/n"
	while read -r _ms _i _h _d _p _m; do
		uclient-fetch -4 -T 5 -O /dev/null "${_d%\?*}?ckSize=1" </dev/null >"$_f/x" 2>&1 6>&- || continue
		grep -q 'Redirected' "$_f/x" && continue
		AS_LSH=$_h; AS_LSDL=$_d; AS_LSUL=$_p; AS_LSN=$_m
		return 0
	done < "$_f/n"
	return 1
}

# Direction $1 (down | up) from the LibreSpeed server from now on: once a
# test and only from the test server ($2 = what runs again, $3 = why). The
# server is picked once (_as_ls_pick) and routed through the WAN with the
# test server and the ping host. False with autosetup.fallback 0, or when
# no server answers.
_as_ls_use() {
	case "$1" in
		down) [ "$AS_DLU" = "$AS_LSDL" ] && return 1 ;;
		*)    [ "$AS_ULU" = "$AS_LSUL" ] && return 1 ;;
	esac
	[ "$(_as_num fallback 1)" = 1 ] || return 1
	if [ -z "$AS_LSN" ]; then
		[ -z "$_AS_LSTRY" ] || return 1
		_AS_LSTRY=1
		if ! _as_ls_pick; then
			msg "speed test: $2 from LibreSpeed: no server answered - $AS_SRVH: $3"
			return 1
		fi
		[ "$AS_BOUND" = 1 ] && _as_bind "$AS_SRVH" "$AS_LSH" "$AS_PING_HOST" && AS_BOUND=1
	fi
	case "$1" in down) AS_DLU=$AS_LSDL ;; *) AS_ULU=$AS_LSUL ;; esac
	msg "speed test: $2 again from LibreSpeed ($AS_LSN) - $AS_SRVH: $3"
}

### Queue check: with shaping off and the line measured, the download path a
### start builds (the WAN's ingress redirect to its IFB, the queue at the
### shaped rate with the config's own options) carries the download again:
### CAKE, then HFSC, then HTB, until one keeps up: no core at fit_sirq_pct
### packet work (softirq) or over, nothing dropped before the queue. It
### measures this router's CPU, driver and line (PPPoE, VLAN) on the
### router's own download; forwarding's nft and NAT work is not in it.

# The check's download path: queue $1 at $2 kbps (shaped) on the IFB a start
# would use for AS_WAN, whatever download_on says (the router's own download
# never leaves by the LAN device).
_as_fit_build() {
	# shellcheck disable=SC2034  # read by QoS-Ex.sh's setup_* functions
	{ QDISC=$1; DOWNLOAD_KBPS=$2; SHAPE_UP=0; SHAPE_DN=1; DL_LAN=0; }
	WAN=$AS_WAN; _ifb_name "$WAN"
	_game_rate "$2"; GAME_DN=$_GG
	AS_FITB=1
	setup_ingress || return 1
	case "$1" in
		cake) setup_cake_dev ingress "$IFB" "$2" "$CAKE_NAT_ING" "$CAKE_EXTRA_I" ;;
		*)    "setup_$1" "$IFB" "$2" "$GAME_DN" ;;
	esac
}

# The check's download path out again (also on any exit: _as_end).
_as_fit_clear() {
	[ "${AS_FITB:-0}" = 1 ] || return 0
	tc qdisc del dev "$IFB" root 2>/dev/null
	cleanup_ingress
	AS_FITB=0
}

# After the download half (AS_DN). Each queue's result: "pass|fail|nodata,
# <kbps it carried>,<the busiest packet-work core %>,<packets dropped>,
# <ping ms>", "missing" (no module), empty = not checked. nodata: the
# download failed (under 100 kbit/s), or under half the rate it ran at
# arrived with no core busy: nothing was measured.
# The first pass ends it; so do nodata and a queue that could not be built
# (no more requests to the test server).
_as_fit() {
	local _q _r _s="$AS_SECS" _hr _kb _th _t
	AS_FCAKE=""; AS_FHFSC=""; AS_FHTB=""; AS_FR=""; AS_FN=""
	[ "$(_as_num fit_check 1)" = 1 ] || return 0
	# Another shaper on the WAN, shaping still on, or no download measured.
	[ "$AS_FOREIGN" = no ] && [ "${_AS_NOFIT:-0}" = 0 ] && [ "${AS_DN:-0}" -ge 100 ] || return 0
	load_config >/dev/null 2>&1 || return 0
	_hr=$BW_HEADROOM
	_isnum "$_hr" && [ "$_hr" -ge 50 ] && [ "$_hr" -le 100 ] || _hr=90
	# The download as Auto Setup will suggest it (never over the port), shaped.
	_kb=$AS_DN
	[ "$AS_SPEED" -gt 0 ] && [ "$_kb" -gt $((AS_SPEED * 1000)) ] && _kb=$((AS_SPEED * 1000))
	_kb=$((_kb * _hr / 100))
	# shellcheck disable=SC2034  # read by QoS-Ex.sh's _foreign_ingress
	{ WAN=$AS_WAN; DL_LAN=0; }
	_ifb_name "$WAN"
	# Another tool's download path on the WAN: left alone, nothing checked.
	_foreign_ingress >/dev/null 2>&1 || return 0
	_as_fit_th
	AS_FR=$_kb; AS_PHASE=fit
	# Half the test's time a queue (5 s at least), after the 2 s warm-up.
	AS_SECS=$(((_s + 1) / 2)); [ "$AS_SECS" -lt 5 ] && AS_SECS=5
	for _q in cake hfsc htb; do
		_r=""
		if ! _as_kmod "sch_$_q"; then
			_r=missing
		else
			AS_FN=$_q; AS_PROG=0; AS_NOW=0; _as_save
			msg "speed test: queue check - $_q on $IFB at $(_as_mbit "$_kb") Mbit"
			# Nothing measured from the test server: the same queue again from
			# LibreSpeed (_as_ls_use: once a test, and only from the test server).
			_t=""
			while _as_fit_build "$_q" "$_kb" >/dev/null 2>&1; do
				_as_dir down
				_as_fit_clear
				# Under 100 kbit/s (the download failed), or under half the rate it
				# ran at with no core busy: nothing measured, and the check stops.
				# A core at fit_sirq_pct, or drops: the CPU held it.
				if [ "$AS_KBPS" -lt 100 ]; then _r=nodata
				elif [ "$AS_SQMAX" -ge "$_th" ]; then _r=fail
				elif [ $((AS_KBPS * 2)) -lt "$_kb" ]; then _r=nodata
				elif [ "$AS_DROP" -gt 0 ]; then _r=fail
				else _r=pass; fi
				if [ "$_r" = nodata ]; then
					msg "speed test: queue check - $_q could not be measured: $(_as_mbit "$AS_KBPS") of $(_as_mbit "$_kb") Mbit arrived${AS_FAIL:+ ($AS_FAIL)}"
				else
					msg "speed test: queue check - $_q $_r: $(_as_mbit "$AS_KBPS") Mbit, busiest core ${AS_SQMAX}% packet work, $AS_DROP dropped, ping ${AS_PING:-?} ms"
				fi
				if [ "$_r" = nodata ] && [ -z "$_t" ] &&
					_as_ls_use down "the queue check" "${AS_FAIL:-almost nothing}"; then
					_t=1; continue
				fi
				break
			done
			_as_fit_clear
			if [ -n "$_r" ]; then
				_r="$_r,$AS_KBPS,$AS_SQMAX,$AS_DROP,$AS_PING"
			else
				msg "speed test: queue check - $_q could not be set up"
			fi
		fi
		case "$_q" in cake) AS_FCAKE=$_r ;; hfsc) AS_FHFSC=$_r ;; *) AS_FHTB=$_r ;; esac
		case "$_r" in fail,*|missing) ;; *) break ;; esac
	done
	AS_FN=""; AS_SECS=$_s
}

# Run on exit, error or Ctrl-C: streams stopped, the queue check's path
# gone, routing and shaping back as they were.
_as_end() {
	trap - EXIT INT TERM
	# shellcheck disable=SC2086  # a PID list
	[ -n "$AS_PIDS" ] && _as_kill $AS_PIDS
	[ -n "${AS_PP:-}" ] && kill "$AS_PP" 2>/dev/null
	AS_PP=""
	_as_fit_clear
	[ -n "$AS_TMP" ] && rm -rf "$AS_TMP"
	AS_TMP=""
	_as_unbind
	case "$AS_PHASE" in
		done|error) ;;
		*) AS_PHASE=error; AS_MSG="${AS_MSG:-stopped before the end}"; _as_save ;;
	esac
	if [ "${_AS_WAS:-0}" = 1 ]; then
		_AS_WAS=0
		start 6>&- >/dev/null 2>&1 || err "speed test: shaping did not start again - run: qos-ex.sh start"
	fi
	exec 6>&-
}

autosetup_speedtest() {
	local _kb _w _k
	command -v uclient-fetch >/dev/null 2>&1 || { err "uclient-fetch not found"; return 1; }
	if command -v flock >/dev/null 2>&1; then
		exec 6>> "$AS_LOCK"
		flock -n 6 || { exec 6>&-; err "a speed test is already running"; return 1; }
	fi
	_as_probe
	if [ ! -r "/sys/class/net/$AS_WAN/statistics/rx_bytes" ]; then
		exec 6>&-; err "WAN device '$AS_WAN' not found - set it in Setup -> Line"; return 1
	fi
	AS_TMP=$(mktemp -d /tmp/qos-ex-speed.XXXXXX 2>/dev/null) || { exec 6>&-; err "no temp directory"; return 1; }
	AS_URL=$(uci -q get "$UCI_CFG.autosetup.test_url")
	# A URL and a host, else the defaults: a value starting with "-" would
	# reach uclient-fetch or ping as an option.
	case "$AS_URL" in http://*|https://*) ;; *) AS_URL=http://speed.cloudflare.com ;; esac
	AS_URL=${AS_URL%/}
	# Its host, and its URLs: 90 MB a request (Cloudflare refuses 100 MB):
	# fewer requests, and Cloudflare limits how many one address may make.
	AS_SRVH=${AS_URL#*://}; AS_SRVH=${AS_SRVH%%/*}; AS_SRVH=${AS_SRVH%:*}
	AS_DLU="$AS_URL/__down?bytes=90000000"; AS_ULU="$AS_URL/__up"
	AS_PING_HOST=$(uci -q get "$UCI_CFG.autosetup.ping_host")
	case "$AS_PING_HOST" in ''|-*|*[!A-Za-z0-9.:-]*) AS_PING_HOST=1.1.1.1 ;; esac
	AS_SECS=$(_as_num test_secs 10)
	[ "$AS_SECS" -lt 5 ] && AS_SECS=5
	[ "$AS_SECS" -gt 60 ] && AS_SECS=60
	# Two streams a core, 2 to 8.
	AS_STREAMS=$((AS_CORES * 2))
	[ "$AS_STREAMS" -gt 8 ] && AS_STREAMS=8
	# The upload file: each stream holds a copy in RAM while it posts, so a
	# quarter of the free RAM shared out, 256 KB to 16 MB.
	_kb=$((AS_MEMFREE_KB / (4 * (AS_STREAMS + 1))))
	[ "$_kb" -lt 256 ] && _kb=256
	[ "$_kb" -gt 16384 ] && _kb=16384
	AS_PHASE=start; AS_PROG=0; AS_NOW=0; AS_MSG=""; AS_PIDS=""; AS_BOUND=""
	AS_DN=""; AS_UP=""; AS_P0=""; AS_PD=""; AS_PU=""
	AS_CD=""; AS_SD=""; AS_CU=""; AS_SU=""; AS_LD=""; AS_LU=""
	AS_MD=""; AS_RD=""; AS_MU=""; AS_RU=""; AS_FD=""; AS_FU=""
	AS_FR=""; AS_FN=""; AS_FCAKE=""; AS_FHFSC=""; AS_FHTB=""; AS_FITB=0
	AS_SDN=$AS_SRVH; AS_SUP=$AS_SRVH; AS_LSH=""; AS_LSDL=""; AS_LSUL=""; AS_LSN=""; _AS_LSTRY=""
	_AS_WAS=0; _AS_NOFIT=0
	trap '_as_end' EXIT
	trap 'exit 1' INT TERM
	# A closed SSH session must not end the test with shaping off.
	trap ':' HUP
	_as_save
	[ "$AS_FOREIGN" = no ] || AS_MSG="another shaper ($AS_FOREIGN) is on $AS_WAN - the result is its rate"
	if ! dd if=/dev/zero of="$AS_TMP/up" bs=1024 count="$_kb" 2>/dev/null; then
		AS_PHASE=error; AS_MSG="no room in /tmp for the upload file"; _as_save
		_as_end; err "speed test: $AS_MSG"; return 1
	fi
	# With two lines the router's own traffic may leave by the other one: the
	# test server (the URL's host) and the ping host go through the WAN.
	_as_bind "$AS_SRVH" "$AS_PING_HOST" && AS_BOUND=1
	if [ -f /var/run/qos-ex-started ]; then
		msg "speed test: shaping stopped for the test, started again after"
		_AS_WAS=1
		stop 6>&- >/dev/null 2>&1 || { _AS_NOFIT=1; AS_MSG="shaping did not stop - the result may be the shaped rate"; }
	fi
	ping -q -c 5 -W 2 "$AS_PING_HOST" > "$AS_TMP/ping" 2>&1
	AS_P0=$(_as_ping "$AS_TMP/ping")
	msg "speed test: download${AS_BOUND:+ through $AS_WAN}, $AS_STREAMS streams, ${AS_SECS} s ($AS_URL)"
	AS_PHASE=down
	_as_half down
	_as_fit
	msg "speed test: upload"
	AS_PHASE=up
	_as_half up
	# A download under 1/50 of the upload from the test server: almost
	# nothing arrived. The download and the queue check again from LibreSpeed.
	if [ $((AS_DN * 50)) -lt "$AS_UP" ] && _as_ls_use down "the download" "under 1/50 of the upload"; then
		AS_PHASE=down
		_k=$AS_DN
		_as_dir down
		if [ "$AS_KBPS" -gt "$_k" ]; then
			_as_take down librespeed
			_as_fit
		fi
	fi
	AS_PHASE=done; AS_PROG=100
	# Under 100 kbit either way: the test did not reach the server, or this
	# is not the device the line is on. A download under 1/50 of the upload
	# is no line's speed either: almost nothing arrived. No result rather
	# than a wrong one.
	if [ "$AS_DN" -lt 100 ] || [ "$AS_UP" -lt 100 ]; then
		AS_PHASE=error
		_w=""
		[ "$AS_DN" -lt 100 ] && _w="download${AS_FD:+ ($AS_FD)}"
		[ "$AS_UP" -lt 100 ] && _w="${_w:+$_w, }upload${AS_FU:+ ($AS_FU)}"
		AS_MSG="almost no test traffic crossed $AS_WAN: $_w (down $(_as_mbit "$AS_DN"), up $(_as_mbit "$AS_UP") Mbit) - check that $AS_URL can be reached${AS_BOUND:+ through $AS_WAN}"
	elif [ $((AS_DN * 50)) -lt "$AS_UP" ]; then
		AS_PHASE=error
		AS_MSG="the download carried almost nothing (down $(_as_mbit "$AS_DN"), up $(_as_mbit "$AS_UP") Mbit)${AS_FD:+: $AS_FD} - try again in a few minutes, or type the line's speeds"
	fi
	# 429: the server limits how many tests one address may run.
	if [ "$AS_PHASE" = error ]; then
		case "$AS_FD$AS_FU" in *"HTTP error 429"*)
			AS_MSG="the test server is limiting tests from this address (HTTP error 429) - try again later, or type the line's speeds" ;;
		esac
	fi
	_as_save
	_as_end
	[ "$AS_PHASE" = done ] || { err "speed test: $AS_MSG"; return 1; }
	msg "speed test: download $(_as_mbit "$AS_DN") Mbit ($AS_LD limit, busiest core ${AS_CD}%), upload $(_as_mbit "$AS_UP") Mbit ($AS_LU limit, ${AS_CU}%)"
	msg "speed test: ping ${AS_P0:-?} ms idle, ${AS_PD:-?} ms downloading, ${AS_PU:-?} ms uploading"
	[ -z "$AS_MSG" ] || msg "speed test: $AS_MSG"
	[ -z "$AS_FD$AS_FU" ] || msg "speed test: some fetches failed - download: ${AS_FD:-none}; upload: ${AS_FU:-none}"
	[ -z "$AS_LSN" ] || msg "speed test: LibreSpeed server $AS_LSN - download from $AS_SDN, upload from $AS_SUP"
	return 0
}

# A speed test result less than an hour old.
_as_fresh() {
	local _at _now
	_at=$(_as_kv at "$AS_RUN")
	_now=$(($(_as_up100) / 100))
	_isnum "$_at" && [ "$_now" -ge "$_at" ] && [ $((_now - _at)) -lt 3600 ]
}

### Suggestions: one line each, "set|key|current|suggested|why",
### "keep|key|current|why" (the queue and rule set, shown when they stay) or
### "note|text". Any other key already at its suggested value is left out.

_as_sug() {   # $1 = key, $2 = suggested, $3 = why
	local _cur
	case "$1" in
		network.packet_steering) _cur=$(uci -q get network.@globals[0].packet_steering) ;;
		*) _cur=$(uci -q get "$UCI_CFG.$1") ;;
	esac
	[ "$_cur" = "$2" ] && return 0
	printf 'set|%s|%s|%s|%s\n' "$1" "$_cur" "$2" "$3"
}
_as_note() { printf 'note|%s\n' "$1"; }
_as_keep() { printf 'keep|%s|%s|%s\n' "$1" "$(uci -q get "$UCI_CFG.$1")" "$2"; }

# fit_sirq_pct into _th: 10-100, else 80.
_as_fit_th() {
	_th=$(_as_num fit_sirq_pct 80)
	[ "$_th" -ge 10 ] && [ "$_th" -le 100 ] || _th=80
}

# The queue the speed test's queue check found for $1 kbps shaped (the
# faster direction), from a fresh test on this WAN: the first of CAKE, HFSC
# and HTB whose busiest packet-work core, scaled from the rate it carried to
# $1 (that work grows with the rate), stays under fit_sirq_pct, with nothing
# dropped. Sets the caller's _qsel and _w; _fstop = the first queue the
# check did not reach or could not measure (the rating then picks it or a
# lighter one); _fcap = the shaped rate the lightest queue holds when none
# keeps up. Could not measure: under half the rate it ran at arrived with
# no core busy (nodata; shaper 3.2.2.5 called that a pass). The first queue
# not measured: the rating picks, and _w says why.
_as_fitq() {
	local _need=$1 _f _r _n _ok _kb _sq _dr _cap _th _rt _seen="" _lf="" _lc="" _ln="" _o="$IFS" _hf _fnd=""
	[ "$(_as_kv phase "$AS_RUN")" = "done" ] && _as_fresh || return 0
	[ "$(_as_kv wan "$AS_RUN")" = "$AS_WAN" ] || return 0
	# The shaped rate the check ran at.
	_rt=$(_as_kv fit_rate "$AS_RUN")
	_isnum "$_rt" || return 0
	_as_fit_th
	for _f in cake hfsc htb; do
		case "$_f" in cake) _n=CAKE ;; hfsc) _n=HFSC ;; *) _n=HTB ;; esac
		_r=$(_as_kv "fit_$_f" "$AS_RUN")
		case "$_r" in
			missing) continue ;;
			pass,*|fail,*|nodata,*) ;;
			*) [ -n "$_seen" ] && _fstop=$_f; break ;;
		esac
		case "$-" in *f*) _hf=1 ;; *) _hf=0 ;; esac
		IFS=,; set -f
		# shellcheck disable=SC2086  # the result's fields
		set -- $_r
		IFS=$_o; [ "$_hf" = 1 ] || set +f
		_ok=$1; _kb=$2; _sq=$3; _dr=$4
		if ! { _isnum "$_kb" && _isnum "$_sq" && _isnum "$_dr"; }; then
			[ -n "$_seen" ] && _fstop=$_f
			break
		fi
		if [ "$_ok" = nodata ] || [ "$_kb" -lt 100 ] || { [ "$_sq" -lt "$_th" ] && [ $((_kb * 2)) -lt "$_rt" ]; }; then
			[ -n "$_seen" ] && _fstop=$_f
			_seen="${_seen:+$_seen; }$_n could not be measured ($(_as_mbit "$_kb") of $(_as_mbit "$_rt") Mbit arrived)"
			_fnd=1
			break
		fi
		# What one core's packet work allows, scaled from what it carried
		# (the work grows with the packets). A core at its limit, or packets
		# dropped before the queue: about what it carried.
		if [ "$_dr" -gt 0 ] || [ "$_sq" -ge 100 ]; then _cap=$((_kb * _th / 100))
		elif [ "$_sq" -gt 0 ]; then _cap=$((_kb * _th / _sq))
		else _cap=$((_kb * _th)); fi
		# Kept up carrying the shaped rate needed or more: measured, not scaled.
		[ "$_ok" = pass ] && [ "$_dr" = 0 ] && [ "$_need" -le "$_kb" ] && _cap=$_need
		if [ "$_cap" -ge "$_need" ]; then
			_qsel=$_f
			_w="queue check: $_n keeps up on this router (busiest core ${_sq}% packet work at $((_kb / 1000)) Mbit"
			[ "$_need" -gt "$_kb" ] && _w="$_w, about $((_sq * _need / _kb))% at $((_need / 1000))"
			_w="$_w)${_seen:+ - $_seen}"
			return 0
		fi
		if [ "$_dr" -gt 0 ]; then _r="$_n did not keep up ($_dr packets dropped at $((_kb / 1000)) Mbit)"
		elif [ "$_ok" = pass ]; then
			# Kept up at the rate it ran at; scaled to the one needed it is over.
			_r="$_n kept up at $((_kb / 1000)) Mbit but would need about $((_sq * _need / _kb))% packet work at $((_need / 1000))"
		else _r="$_n did not keep up (busiest core ${_sq}% at $((_kb / 1000)) Mbit)"; fi
		_seen="${_seen:+$_seen; }$_r"
		_lf=$_f; _lc=$_cap; _ln=$_n
	done
	[ -n "$_seen" ] || return 0
	if [ -n "$_fstop$_fnd" ]; then
		if [ -z "$_fnd" ]; then
			case "$_fstop" in hfsc) _n=HFSC ;; *) _n=HTB ;; esac
			_seen="$_seen; $_n was not checked"
		fi
		_w="queue check: $_seen"
	else
		_qsel=$_lf; _fcap=$_lc
		_w="queue check: no queue keeps up at $((_need / 1000)) Mbit on this router ($_seen): the rates are cut to what $_ln shapes"
	fi
}

_as_suggest() {   # $1 $2 = line download / upload, kbps (optional)
	local _hr _dn="" _up="" _src="" _v _q _w _oh _ll _lim="" _busy=0 _mgr _why _qsel _mx=0 _cm _st=0 _ln _ls
	local _fcap="" _fstop="" _cpu _qw _l0 _fw _pw _sw
	# Line rates are the line's speed: the shaper takes Headroom off them.
	_hr=$(uci -q get "$UCI_CFG.settings.bw_headroom")
	_isnum "$_hr" && [ "$_hr" -ge 50 ] && [ "$_hr" -le 100 ] || _hr=90
	# The WAN set carries no default route: the line in use. (One that
	# carries one stays: _as_probe.)
	[ -n "$AS_WAN" ] && [ "$AS_WAN" != "$AS_WAN_CFG" ] &&
		_as_sug settings.wan "$AS_WAN" "the line (default route) is on $AS_WAN"
	# Line rates: typed, else a fresh speed test, else the DSL sync rate.
	if _isnum "${1:-}" && _isnum "${2:-}"; then
		_dn=$1; _up=$2; _src="the speeds given"
	elif [ "$(_as_kv phase "$AS_RUN")" = done ] && _as_fresh; then
		_dn=$(_as_kv down_kbps "$AS_RUN"); _up=$(_as_kv up_kbps "$AS_RUN"); _src="the speed test"
		for _v in limit_down limit_up; do
			[ "$(_as_kv "$_v" "$AS_RUN")" = router ] && _lim=router
		done
		for _v in cpu_down cpu_up; do
			_q=$(_as_kv "$_v" "$AS_RUN")
			_isnum "$_q" && [ "$_q" -gt "$_busy" ] && _busy=$_q
		done
	elif [ -n "$AS_DSL" ] && [ "$AS_DSL_DN" -gt 0 ]; then
		_dn=$AS_DSL_DN; _up=$AS_DSL_UP; _src="the DSL sync rate"
	fi
	# The faster line rate as it will be suggested (never over the WAN port):
	# the queue is picked for it, and the rate rows follow the queue's cap.
	for _v in "$_dn" "$_up"; do
		if ! { _isnum "$_v" && [ "$_v" -gt 0 ]; }; then continue; fi
		[ "$AS_SPEED" -gt 0 ] && [ "$_v" -gt $((AS_SPEED * 1000)) ] && _v=$((AS_SPEED * 1000))
		[ "$_v" -gt "$_mx" ] && _mx=$_v
	done
	# Queue: what the speed test's queue check found (_as_fitq). Else the
	# rating's (queue_<tier>: HTB on a low-spec router, HFSC on a mid-range
	# one, CAKE on a high-end one), then one step lighter at most (CAKE ->
	# HFSC -> HTB): CAKE on a router that is not x86 with a line faster than
	# cake_max_mbit, or a fresh speed test that kept a core at cpu_busy_pct
	# (it runs unshaped: shaping only adds to that). Never richer than a
	# queue the check found does not keep up.
	_cpu="$AS_CORES cores${AS_MHZ:+ at $AS_MHZ MHz}"
	[ "$AS_MHZ" = 0 ] && _cpu="$AS_CORES cores"
	_qsel=""; _w=""; _fw=""
	[ "$_mx" -gt 0 ] && _as_fitq $((_mx * _hr / 100))
	if [ -z "$_qsel" ]; then
		_fw=$_w
		_qsel=$(uci -q get "$UCI_CFG.autosetup.queue_$AS_TIER")
		case "$_qsel" in
			cake|hfsc|htb) ;;
			*) case "$AS_TIER" in low) _qsel=htb ;; mid) _qsel=hfsc ;; *) _qsel=cake ;; esac ;;
		esac
		case "$_qsel" in
			htb)  _w="$AS_TIER-spec router ($_cpu): HTB is the cheapest queue" ;;
			hfsc) _w="$AS_TIER-spec router ($_cpu): HFSC is lighter than CAKE and has a real-time Gaming class" ;;
			*)    _w="$AS_TIER-spec router ($_cpu): CAKE also shares the line fairly between devices" ;;
		esac
		# _mx: the faster line rate, 0 with none known.
		_cm=$(_as_num cake_max_mbit 500)
		if [ "$_qsel" = cake ] && [ "$_cm" -gt 0 ] && [ "$_mx" -gt $((_cm * 1000)) ]; then
			case "$AS_ARCH" in
				x86_64|i[3-6]86) ;;
				*) _qsel=hfsc; _st=1
				   _w="$AS_TIER-spec router ($_cpu) at $((_mx / 1000)) Mbit: above cake_max_mbit ($_cm) CAKE runs out of CPU - HFSC is lighter and keeps the real-time Gaming class" ;;
			esac
		fi
		if [ "$_lim" = router ] && [ "$_st" = 0 ]; then
			case "$_qsel" in
				cake) _qsel=hfsc; _w="$AS_TIER-spec router ($_cpu): the speed test maxed a CPU core (${_busy}%) unshaped - HFSC is lighter than CAKE" ;;
				hfsc) _qsel=htb;  _w="$AS_TIER-spec router ($_cpu): the speed test maxed a CPU core (${_busy}%) unshaped - HTB is lighter than HFSC" ;;
			esac
		fi
		case "$_fstop$_qsel" in
			hfsccake) _qsel=hfsc; _w="HFSC is lighter than CAKE and has a real-time Gaming class" ;;
			htbcake|htbhfsc) _qsel=htb; _w="HTB is the cheapest queue" ;;
		esac
		[ -n "$_fw" ] && _w="$_fw - $_w"
	fi
	# A queue whose module is missing: HTB.
	if [ "$_qsel" = cake ] && ! _as_kmod sch_cake; then
		_qsel=htb; _w="${_fw:+$_fw - }the CAKE module (kmod-sched-cake) is not installed"
	elif [ "$_qsel" = hfsc ] && ! _as_kmod sch_hfsc; then
		_qsel=htb; _w="${_fw:+$_fw - }the HFSC module (sch_hfsc) is not installed"
	fi
	_qw=$_w
	if [ -n "$_src" ]; then
		for _v in "download_kbps $_dn" "upload_kbps $_up"; do
			_q=${_v#* }
			_isnum "$_q" || continue
			if [ "$_q" = 0 ]; then
				# Typed 0: that direction is not shaped. A test 0 failed.
				[ "$_src" = "the speeds given" ] && _as_sug "settings.${_v% *}" 0 "0 = this direction is not shaped"
				continue
			fi
			# Never over the WAN port's speed, and the row says so.
			_l0=$_q; _pw=""
			if [ "$AS_SPEED" -gt 0 ] && [ "$_q" -gt $((AS_SPEED * 1000)) ]; then
				_q=$((AS_SPEED * 1000)); _pw=", cut to the WAN port's $AS_SPEED Mbit"
			fi
			# A direction the router's CPU held back: the line may be faster.
			_w=""
			if [ "$_src" = "the speed test" ]; then
				case "${_v% *}" in download_kbps) _w=limit_down ;; *) _w=limit_up ;; esac
				if [ "$(_as_kv "$_w" "$AS_RUN")" = router ]; then
					_w=", held by the router's CPU (the line may be faster: type its speeds if you know them)"
				else
					_w=""
				fi
			fi
			# Measured from a LibreSpeed server: named, as its own limit may be
			# under the line's.
			_sw=""
			if [ "$_src" = "the speed test" ]; then
				case "${_v% *}" in download_kbps) _sw=src_down ;; *) _sw=src_up ;; esac
				if [ "$(_as_kv "$_sw" "$AS_RUN")" = librespeed ]; then
					_sw=" (LibreSpeed: $(_as_kv ls_server "$AS_RUN"))"
				else
					_sw=""
				fi
			fi
			# No queue keeps up at the line's speed: what the lightest shapes.
			if [ -n "$_fcap" ] && [ $((_q * _hr / 100)) -gt "$_fcap" ]; then
				_q=$((_fcap * 100 / _hr))
				_w="$_w, cut to $(_as_mbit "$_q") Mbit: this router's CPU shapes about $(_as_mbit "$_fcap") Mbit (queue check)"
			fi
			_as_sug "settings.${_v% *}" "$_q" "$(_as_mbit "$_l0") Mbit from $_src$_sw$_pw$_w; shaped at $(_as_mbit $((_q * _hr / 100))) Mbit (Headroom ${_hr}%)"
		done
	else
		_as_note "No line speed yet: run the speed test, or give the line's download and upload speeds."
	fi
	# More than one line with a default route (failover, mwan3): QoS-Ex
	# shapes one. The speed test runs through it (_as_bind); one that could
	# not be routed so ran over the router's own route.
	_ln=0; _ls=""
	for _v in $AS_WAN_ALL; do _ln=$((_ln + 1)); _ls="${_ls:+$_ls, }$_v"; done
	if [ "$_ln" -gt 1 ]; then
		_v=""
		[ "$_src" = "the speed test" ] && [ "$(_as_kv bound "$AS_RUN")" != 1 ] &&
			_v=" The speed test may not have run over $AS_WAN: if its speeds look low, type them."
		_as_note "$_ln lines have a default route ($_ls). QoS-Ex shapes $AS_WAN only: send the gaming devices out through it (an mwan3 rule or pbr).$_v"
	fi
	# The queue picked above, always shown.
	_q=$(uci -q get "$UCI_CFG.settings.qdisc")
	if [ "$_q" = "$_qsel" ]; then _as_keep settings.qdisc "$_qw"; else _as_sug settings.qdisc "$_qsel" "$_qw"; fi
	# Leaf queue inside the HFSC / HTB classes: sfq on a low-spec router.
	if [ "$_qsel" != cake ]; then
		_q=$(uci -q get "$UCI_CFG.hfsc.default_qdisc")
		if [ "$AS_TIER" = low ]; then
			_w="low-spec router: sfq costs less CPU than fq_codel"
			if [ "${_q:-fq_codel}" = sfq ]; then _as_keep hfsc.default_qdisc "$_w"; else _as_sug hfsc.default_qdisc sfq "$_w"; fi
		elif [ "${_q:-fq_codel}" = fq_codel ]; then
			_as_keep hfsc.default_qdisc "$AS_TIER-spec router: fq_codel keeps latency lower than sfq"
		else
			_as_sug hfsc.default_qdisc fq_codel "$AS_TIER-spec router: fq_codel keeps latency lower than sfq"
		fi
	fi
	# Rule set: the rating's (rules_<tier>).
	_q=$(uci -q get "$UCI_CFG.settings.nft_mode")
	_w=$(uci -q get "$UCI_CFG.autosetup.rules_$AS_TIER")
	case "$_w" in
		simple|advanced|adaptive) ;;
		*) if [ "$AS_TIER" = low ]; then _w=simple; else _w=adaptive; fi ;;
	esac
	_why="$AS_TIER-spec router ($_cpu)"
	if [ "$_q" = "$_w" ]; then _as_keep settings.nft_mode "$_why"
	else _as_sug settings.nft_mode "$_w" "$_why"; fi
	# Where the download is shaped: on the LAN device as the traffic leaves
	# (no IFB, no redirect: one qdisc pass less a packet) on a low-spec
	# router whose one LAN device carries every LAN network; the IFB off the
	# WAN, which covers every LAN device, otherwise.
	_q=$(uci -q get "$UCI_CFG.settings.download_on")
	if [ "$AS_TIER" = low ] && [ -n "$AS_LAN" ] && [ "$AS_LAN_N" = 1 ]; then
		_w="low-spec router: the download is shaped on $AS_LAN as it leaves, with no IFB device to pass through"
		if [ "${_q:-wan}" = lan ]; then _as_keep settings.download_on "$_w"; else _as_sug settings.download_on lan "$_w"; fi
		[ "$(uci -q get "$UCI_CFG.settings.lan")" = "$AS_LAN" ] || _as_sug settings.lan "$AS_LAN" "the LAN device"
	elif [ "${_q:-wan}" = lan ]; then
		if [ "$AS_TIER" = low ]; then _w="$AS_LAN_N LAN devices: the download shaped on one would miss the others"
		else _w="$AS_TIER-spec router: the IFB off the WAN covers every LAN device"; fi
		_as_sug settings.download_on wan "$_w"
	else
		_as_keep settings.download_on "$AS_TIER-spec router: the IFB off the WAN covers every LAN device"
	fi
	# Live pages: how often Stats and Flows poll the router (each poll runs
	# tc and nft) until a browser picks its own.
	_q=$(uci -q get "$UCI_CFG.settings.live_refresh")
	if [ "$AS_TIER" = low ]; then _w=2; _why="low-spec router: every poll runs tc and nft"
	else _w=1; _why="$AS_TIER-spec router"; fi
	if [ "${_q:-1}" = "$_w" ]; then _as_keep settings.live_refresh "$_why"
	else _as_sug settings.live_refresh "$_w" "$_why"; fi
	[ "$_lim" = router ] &&
		_as_note "The router's CPU held the speed test back (busiest core ${_busy}%): the suggested line speeds are what the router managed, and the line may be faster. Shaping takes CPU too: if Live -> Stats shows drops or the ping rises, lower the rates."
	[ -n "$_fcap" ] &&
		_as_note "No queue keeps up with this line on this router's CPU, so the rates are set to what it shapes (about $(_as_mbit "$_fcap") Mbit). Shaped any faster, the queue builds before QoS-Ex and the ping rises under load."
	# Overhead: the bytes each packet carries on the wire besides IP
	# (tc-cake: ethernet 38, bridged-ptm 22; ATM 44 when the encapsulation is
	# unknown); PPPoE adds 8, a VLAN tag 4.
	case "$AS_DSL" in
		atm) _ll=atm;      _oh=44; _w="ADSL (ATM)" ;;
		ptm) _ll=ethernet; _oh=22; _w="VDSL (PTM)" ;;
		*)   _ll=ethernet; _oh=38; _w="Ethernet" ;;
	esac
	if [ "$_ll" = ethernet ]; then
		[ "$AS_PROTO" = pppoe ] && { _oh=$((_oh + 8)); _w="$_w + PPPoE"; }
		[ "$AS_VLAN" = yes ] && { _oh=$((_oh + 4)); _w="$_w + VLAN"; }
	fi
	_as_sug settings.linklayer "$_ll" "$_w line"
	_as_sug settings.overhead "$_oh" "$_w: bytes each packet carries on the wire besides IP"
	# Small routers: Ping Filter Lite, a shorter server list, fewer flash writes.
	if uci -q get "$UCI_CFG.pingfilter" >/dev/null; then
		if [ "$AS_TIER" = low ]; then
			_as_sug pingfilter.lite 1 "low-spec router ($_cpu, $AS_MEM_MB MB): ping limit or radius, no gameplay grading or Ping Catch"
		else
			_as_sug pingfilter.lite 0 "$AS_TIER-spec router: the full Ping Filter"
		fi
		_v=$(uci -q get "$UCI_CFG.pingfilter.max_servers")
		[ "$AS_MEM_MB" -gt 0 ] && [ "$AS_MEM_MB" -le "$(_as_num low_ram_mb 128)" ] &&
			_isnum "$_v" && [ "$_v" -gt 100 ] &&
			_as_sug pingfilter.max_servers 100 "$AS_MEM_MB MB of RAM: a shorter Ping Filter server list"
		_v=$(uci -q get "$UCI_CFG.pingfilter.persist_interval")
		[ "$AS_FLASH_MB" -gt 0 ] && [ "$AS_FLASH_MB" -le "$(_as_num small_flash_mb 16)" ] &&
			_isnum "$_v" && [ "$_v" -lt 21600 ] &&
			_as_sug pingfilter.persist_interval 21600 "$AS_FLASH_MB MB of writable flash: save the server list every 6 hours, not every hour"
	fi
	# Packet steering spreads packet work over the cores; applied on its own,
	# without a network restart.
	[ "$AS_CORES" -gt 1 ] && [ "$AS_STEER" = 0 ] && [ -x /etc/init.d/packet_steering ] &&
		_as_sug network.packet_steering 1 "$AS_CORES cores: spread packet work over them"
	# Notes.
	[ "$AS_OFFLOAD_SW$AS_OFFLOAD_HW" = 00 ] ||
		_as_note "Flow offloading is on: QoS-Ex turns it off when switched on. A router that needs hardware offload for its top speed routes less without it."
	if [ -n "$AS_PKG_MISSING" ]; then
		_mgr=$(_pkg_mgr)
		case "$_mgr" in
			apk) _as_note "Packages missing: $AS_PKG_MISSING - install: apk update && apk add $AS_PKG_MISSING" ;;
			*)   _as_note "Packages missing: $AS_PKG_MISSING - install: opkg update && opkg install $AS_PKG_MISSING" ;;
		esac
	fi
	[ "$AS_FOREIGN" = no ] || _as_note "Another shaper ($AS_FOREIGN) is on $AS_WAN: stop it before QoS-Ex starts."
	_as_hw_moved &&
		_as_note "This config was set up on other hardware ($AS_HW_SAVED, now $AS_HW): check these suggestions."
	if [ "$_src" = "the speed test" ]; then
		_v=$(_as_kv ping_idle "$AS_RUN")
		_q=$(_as_kv ping_down "$AS_RUN"); _w=$(_as_kv ping_up "$AS_RUN")
		_isnum "$_v" && _as_note "Ping unshaped: $_v ms idle, ${_q:-?} ms downloading, ${_w:-?} ms uploading."
	fi
	return 0
}

# -p, after the speeds or alone: the router check's lines first, so LuCI
# needs one run, not two. (An older backend takes the speeds and leaves -p.)
autosetup_suggest() {
	local _tmp _p=0
	[ "${1:-}" = -p ] && { _p=1; shift; }
	[ "${3:-}" = -p ] && _p=1
	_as_probe
	_tmp=$(mktemp /tmp/qos-ex-sugg.XXXXXX 2>/dev/null) || { err "no temp file"; return 1; }
	# When they were made (uptime, s): apply refuses them an hour on, and
	# LuCI hands it back (at=) so it applies only the ones it showed.
	{ echo "sugg_at=$(($(_as_up100) / 100))"; _as_suggest "$@"; } > "$_tmp"
	[ "$_p" = 0 ] || _as_probe_out
	cat "$_tmp"
	mv -f "$_tmp" "$AS_SUGG"
}

# The gaming and the low-priority MACs, each list sorted: what apply changed.
_as_macs() {
	local _l
	for _l in gaming_mac lowprio_mac; do
		uci -q get "$UCI_CFG.ips.$_l" | tr 'A-F ' 'a-f\n' | sort | tr '\n' ' '
		echo
	done
}

# True while a speed test holds its lock.
_as_testing() {
	command -v flock >/dev/null 2>&1 || return 1
	! flock -n "$AS_LOCK" true 2>/dev/null
}

# Apply suggestions from the last suggest: all (packet steering apart), the
# word steering, or keys by name. dev=<MAC> / low=<MAC> (repeatable) set the
# gaming / low-priority devices; dev= or low= alone empties that list. at=
# (LuCI) names the suggestions the page showed: other ones are refused. The
# config is copied first, for undo, and kept only when something changed. The
# Ping Filter is set up on its own (its pages' setup card), never here.
autosetup_apply() {
	local _t _k _cur _new _why _a _sel _n=0 _bak=0 _steer="" _devs="" _lows="" _dset=0 _lset=0 _m _old _was
	local _want="" _only="" _at _now _chg=""
	[ -f "$AS_SUGG" ] || { err "no suggestions yet - run: qos-ex.sh autosetup suggest"; return 1; }
	# An apply under a running speed test would start shaping under it.
	_as_testing && { err "a speed test is running - apply once it has ended"; return 1; }
	[ $# -gt 0 ] || set -- all
	for _a in "$@"; do
		case "$_a" in
			at=*) _want=${_a#at=} ;;
			dev=*|low=*)
				# Lower-cased first: LuCI sends lower case, a hand-typed MAC
				# may not. Anything else but empty is not a device: ignored.
				_m=$(printf '%s' "${_a#*=}" | tr 'A-F' 'a-f')
				case "$_m" in
					'') ;;
					[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])
						case "$_a" in dev=*) _devs="$_devs $_m" ;; *) _lows="$_lows $_m" ;; esac ;;
					*) continue ;;
				esac
				case "$_a" in dev=*) _dset=1 ;; *) _lset=1 ;; esac ;;
			*) _only="$_only $_a" ;;
		esac
	done
	# The suggestions: under an hour old (an older file is another line, or
	# another speed test), and the ones the page showed.
	_at=$(_as_kv sugg_at "$AS_SUGG")
	_now=$(($(_as_up100) / 100))
	if ! _isnum "$_at" || [ "$_now" -lt "$_at" ] || [ $((_now - _at)) -ge 3600 ]; then
		err "the suggestions are over an hour old - run: qos-ex.sh autosetup suggest"; return 1
	fi
	[ -z "$_want" ] || [ "$_want" = "$_at" ] ||
		{ err "the suggestions changed since they were shown (another window?) - look at them again"; return 1; }
	if [ "$_only" != " steering" ]; then
		mkdir -p /etc/qos-ex 2>/dev/null
		cp "/etc/config/$UCI_CFG" "$AS_BAK.new" 2>/dev/null || { err "could not copy the config - nothing changed"; return 1; }
		_bak=1
	fi
	while IFS='|' read -r _t _k _cur _new _why; do
		[ "$_t" = set ] || continue
		_sel=0
		for _a in "$@"; do
			case "$_a" in
				all) [ "$_k" = network.packet_steering ] || _sel=1 ;;
				steering) [ "$_k" = network.packet_steering ] && _sel=1 ;;
				"$_k") _sel=1 ;;
			esac
		done
		[ "$_sel" = 1 ] || continue
		case " $AS_KEYS " in *" $_k "*) ;; *) continue ;; esac
		case "$_new" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
		if [ "$_k" = network.packet_steering ]; then
			_steer=$_new
			continue
		fi
		[ "$_bak" = 1 ] || continue
		uci -q set "$UCI_CFG.$_k=$_new" || continue
		msg "auto setup: $_k = $_new (was ${_cur:-unset})"
		_chg="$_chg $_k"
		_n=$((_n + 1))
	done < "$AS_SUGG"
	# Devices by MAC. A device is never gaming and low priority both: gaming
	# wins. The Ping Filter's watched devices are ticked by the user only: one
	# that leaves Gaming leaves that list, none is added.
	if [ "$_dset$_lset" != 00 ]; then
		_was=$(_as_macs)
		if [ "$_dset" = 1 ]; then
			for _m in $(uci -q get "$UCI_CFG.ips.gaming_mac"); do
				_old=$(echo "$_m" | tr 'A-F' 'a-f')
				case "$_devs " in *" $_old "*) ;; *) uci -q del_list "$UCI_CFG.pingfilter.pf_devices=$_m" ;; esac
			done
			uci -q delete "$UCI_CFG.ips.gaming_mac"
			for _m in $_devs; do
				uci -q add_list "$UCI_CFG.ips.gaming_mac=$_m"
				uci -q del_list "$UCI_CFG.ips.lowprio_mac=$_m"
			done
		fi
		if [ "$_lset" = 1 ]; then
			_old=" $(uci -q get "$UCI_CFG.ips.gaming_mac" | tr 'A-F' 'a-f') "
			uci -q delete "$UCI_CFG.ips.lowprio_mac"
			for _m in $_lows; do
				case "$_old" in *" $_m "*) ;; *) uci -q add_list "$UCI_CFG.ips.lowprio_mac=$_m" ;; esac
			done
		fi
		if [ "$(_as_macs)" != "$_was" ]; then
			msg "auto setup: gaming devices = $(uci -q get "$UCI_CFG.ips.gaming_mac"), low priority = $(uci -q get "$UCI_CFG.ips.lowprio_mac")"
			_chg="$_chg ips.gaming_mac ips.lowprio_mac pingfilter.pf_devices"
			_n=$((_n + 1))
		fi
	fi
	# Set up either way: Auto Setup is not offered again on this hardware.
	# Packet steering alone is not the setup. A setting left blank by a
	# reset and not applied: the default (and undo blanks it again). The
	# copy for undo names the keys this apply changed, the switch (Apply and
	# start turns it on) and the setup state; one that changed nothing keeps
	# the last copy, so undo still reaches the apply before it.
	if [ "$_bak" = 1 ]; then
		for _k in $AS_BLANK; do [ -n "$(uci -q get "$UCI_CFG.$_k")" ] || _chg="$_chg $_k"; done
		_as_hw
		_as_done 1 "$AS_HW"
		_as_fill
		if [ -n "$_chg" ]; then
			{ echo "# autosetup undo:$_chg settings.enabled autosetup.done autosetup.hw"; cat "$AS_BAK.new"; } \
				> "$AS_BAK.tmp" 2>/dev/null && mv -f "$AS_BAK.tmp" "$AS_BAK"
		fi
		rm -f "$AS_BAK.new" "$AS_BAK.tmp" 2>/dev/null
	fi
	if [ -n "$_steer" ] && uci -q get network.@globals[0] >/dev/null; then
		mkdir -p /etc/qos-ex 2>/dev/null
		uci -q get network.@globals[0].packet_steering > "$AS_STEER_BAK" 2>/dev/null || : > "$AS_STEER_BAK"
		uci -q set network.@globals[0].packet_steering="$_steer"
		uci -q commit network
		/etc/init.d/packet_steering reload >/dev/null 2>&1
		msg "auto setup: packet steering = $_steer"
		_n=$((_n + 1))
	fi
	if [ "$_n" -gt 0 ]; then msg "auto setup: $_n change(s) applied - undo: qos-ex.sh autosetup undo"
	else msg "auto setup: nothing to change"; fi
	[ "$(uci -q get "$UCI_CFG.settings.enabled")" = 1 ] && [ "$_n" -gt 0 ] && reload
	return 0
}

# Put back what the last apply changed, and packet steering: the keys its
# copy names, each as the copy has it (read by uci from the copy, with no
# change file of its own); anything else changed since stays. A copy from an
# older shaper names no keys: every key an apply can set.
autosetup_undo() {
	local _v="" _n=0 _d _keys _k _l
	_as_testing && { err "a speed test is running - undo once it has ended"; return 1; }
	if [ -f "$AS_BAK" ]; then
		_d=$(mktemp -d /tmp/qos-ex-undo.XXXXXX 2>/dev/null) || { err "no temp directory"; return 1; }
		cp "$AS_BAK" "$_d/$UCI_CFG" 2>/dev/null || { rm -rf "$_d"; err "could not read $AS_BAK"; return 1; }
		_keys=$(sed -n '1s/^# autosetup undo://p' "$AS_BAK")
		[ -n "$_keys" ] || _keys="$AS_KEYS $AS_BLANK ips.gaming_mac ips.lowprio_mac pingfilter.pf_devices settings.enabled autosetup.done autosetup.hw"
		# Changes staged with the uci CLI belong to the config being put back.
		uci -q revert "$UCI_CFG"
		for _k in $_keys; do
			case "$_k" in network.*|*[!A-Za-z0-9._-]*) continue ;; esac
			_v=$(uci -c "$_d" -t "$_d" -q get "$UCI_CFG.$_k")
			uci -q delete "$UCI_CFG.$_k"
			case "$_k" in
				ips.gaming_mac|ips.lowprio_mac|pingfilter.pf_devices)
					for _l in $_v; do uci -q add_list "$UCI_CFG.$_k=$_l"; done ;;
				*) [ -z "$_v" ] || uci -q set "$UCI_CFG.$_k=$_v" ;;
			esac
		done
		uci -q commit "$UCI_CFG"
		rm -rf "$_d"; rm -f "$AS_BAK"
		# autosetup.done comes back as it was (0: Apply is on the Auto Setup
		# tab), so LuCI builds its menu again, as after _as_done.
		rm -f /tmp/luci-indexcache* 2>/dev/null
		msg "auto setup: what the last apply changed is back as it was"
		_n=1
	fi
	if [ -f "$AS_STEER_BAK" ]; then
		read -r _v < "$AS_STEER_BAK"
		if [ -n "$_v" ]; then uci -q set network.@globals[0].packet_steering="$_v"
		else uci -q delete network.@globals[0].packet_steering; fi
		uci -q commit network
		[ -x /etc/init.d/packet_steering ] && /etc/init.d/packet_steering reload >/dev/null 2>&1
		rm -f "$AS_STEER_BAK"
		msg "auto setup: packet steering put back (${_v:-default})"
		_n=1
	fi
	[ "$_n" = 1 ] || { err "nothing to undo"; return 1; }
	# The copy is from before Apply and start switched shaping on, so it can
	# switch it off: a running shaper reloads as well, and then stops.
	if [ "$(uci -q get "$UCI_CFG.settings.enabled")" = 1 ] || [ -f /var/run/qos-ex-started ] || [ -f "$START_PART" ]; then
		reload
	fi
	return 0
}

autosetup_main() {
	case "${1:-}" in
		probe)     autosetup_probe ;;
		hw)        _as_hw; _as_hw_lines ;;
		speedtest) autosetup_speedtest ;;
		result)    cat "$AS_RUN" 2>/dev/null ;;
		suggest)   shift; autosetup_suggest "$@" ;;
		apply)     shift; autosetup_apply "$@" ;;
		undo)      autosetup_undo ;;
		skip)      autosetup_skip ;;
		again)     autosetup_again ;;
		blank)     autosetup_blank ;;
		*)
			cat <<'ASEOF'
Usage: qos-ex.sh autosetup COMMAND
  probe            What this router has (key=value; changes nothing)
  hw               The hardware fingerprint and whether setup is done
  speedtest        Measure the line (stops shaping while it runs)
  result           The last speed test
  suggest [D U] [-p]
                   Suggested settings; D U = line speeds in kbps, else the
                   speed test (under an hour old) or the DSL sync rate;
                   -p: the probe lines first
  apply [all | steering | KEY ...]
                   Apply the last suggestions (all leaves packet steering out);
                   dev=<mac> / low=<mac> (repeatable) set the gaming /
                   low-priority devices; dev= or low= alone empties the list
  undo             Put back what the last apply changed
  skip             Mark as set up by hand (Auto Setup not offered again)
  again            Offer Auto Setup again, in its LuCI tab (settings stay)
  blank            Clear the settings Auto Setup picks and offer it again
                   (Reset to defaults; skip fills in the defaults)
ASEOF
			return 1 ;;
	esac
}
