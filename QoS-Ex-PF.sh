#!/bin/sh
# shellcheck shell=dash
# SPDX-License-Identifier: GPL-3.0-or-later
# QoS-Ex Ping Filter — standalone backend, companion to QoS-Ex.sh. Discovery,
# grading and enforcement logic live here in user space; the kernel does the
# fast path (@pf_seen discovery, @ping_allowed / @ping_blocked enforcement).
# Installed to $PF_BIN; the shaper delegates its `pingfilter` verb here.

VERSION="2.0.9.4"
# Version: <module>.<major>.<minor>.<patch>; module 3 = shaper, 2 = Ping
# Filter, 1 = LuCI app. Odometer: patch 10 -> minor+1, minor 10 -> major+1.
SCRIPT_NAME="qos-ex-pf"
DISPLAY_NAME="QoS-Ex-PF"
# UCI package name, shared with the shaper.
UCI_CFG="qos-ex"
PF_BIN="/usr/sbin/qos-ex-pf.sh"
# Daemon stdout / stderr sink: an empty path kills the detached spawn before
# it writes its pidfile.
RUN_LOG="/var/log/qos-ex-pf-daemon.log"
# PF's only log: daemon activity and user actions (the shaper's is
# /var/log/qos-ex.log; LuCI's Logs tab shows both).
RUN_LOG_MAX=200

# /var/run (root's own tmpfs), not /tmp: a fixed /tmp name can be taken first.
PF_RUN_DIR="/var/run/qos-ex-pingfilter"
PF_SERVERS_TSV="$PF_RUN_DIR/servers.tsv"
PF_GEO_CACHE="$PF_RUN_DIR/geo-cache.tsv"
# /24 memory: pfx n rtt_ewma bound_km lat lon country city ts. Learned from
# MEASURED readings only; persisted with the other caches.
PF_PREFIX_TSV="$PF_RUN_DIR/prefix.tsv"
PF_PERSIST_DIR="/etc/qos-ex/pf-cache"
PF_PID_FILE="$PF_RUN_DIR/daemon.pid"
# Live telemetry, tmpfs only: live.tsv = the per-flow overlay pf_servers_json
# reads; tele-<ip> = capped ring buffer (sparkline history).
PF_LIVE_TSV="$PF_RUN_DIR/live.tsv"
PF_TELE_PREFIX="$PF_RUN_DIR/tele-"
# Session grading: per-server EWMA history (tmpfs, synced to flash) and
# per-flow accumulators (.acc-<ip>). Only a full cache clear wipes history.
PF_TELE_HIST="$PF_RUN_DIR/telemetry-hist.tsv"
PF_TELE_ACC_PREFIX="$PF_RUN_DIR/.acc-"
PF_NFT_ERR="/var/run/qos-ex-pingfilter-nft.err"
# Play history, one line per stretch of play on one server (newest last,
# 200 kept):
#   end-epoch  ip  seconds  ping  jitter  gaps  pps  country  city  name
PF_SESS_TSV="$PF_RUN_DIR/sessions.tsv"
# Servers on a game company's own network: "ip<TAB>company", from the
# location lookup's network owner. The name a server shows.
PF_OWNER_TSV="$PF_RUN_DIR/owner.tsv"
# The servers JSON as the daemon last built it; present only while a page
# asks for it.
PF_JSON="$PF_RUN_DIR/servers.json"
PF_SYSCTL="/etc/sysctl.d/90-qos-ex-pf.conf"
# One name for the conntrack table: the daemon's per-tick pass and the
# one-off readers agree.
PF_CT_PROC="${PF_CT_PROC:-/proc/net/nf_conntrack}"
PF_CT_TOT="$PF_RUN_DIR/.ct.tot"
PF_CT_DST="$PF_RUN_DIR/.ct.dst"

_logline() {
	local _n _t
	[ -n "$RUN_LOG" ] || return 0
	echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$RUN_LOG" 2>/dev/null
	# A fork and a full read: first line of a run and every 25th after it.
	_LOGN=$((${_LOGN:-0} + 1))
	[ "$_LOGN" -eq 1 ] || [ $((_LOGN % 25)) -eq 0 ] || return 0
	[ -f "$RUN_LOG" ] || return 0
	_n=$(wc -l < "$RUN_LOG" 2>/dev/null)
	[ "${_n:-0}" -gt "$RUN_LOG_MAX" ] || return 0
	# mktemp, not $$: a guessable name can be a planted symlink. No temp = no
	# trim this pass.
	_t=$(mktemp "$RUN_LOG.XXXXXX" 2>/dev/null) || return 0
	chmod 644 "$_t" 2>/dev/null
	tail -n "$RUN_LOG_MAX" "$RUN_LOG" > "$_t" 2>/dev/null && mv "$_t" "$RUN_LOG" 2>/dev/null
	rm -f "$_t" 2>/dev/null
}

# PF logs to the QoS-Ex logs only, never syslog: procd captures the daemon's
# stdout. In daemon mode msg() / err() only log; CLI runs still print.
# PF_DAEMON = 1 is set by the two daemon entry points only.
PF_DAEMON=0
PF_UPKEEP=30

msg() {
	[ "$PF_DAEMON" = 1 ] || echo "[$DISPLAY_NAME] $*"
	_logline "INFO" "$*"
	return 0
}
err() {
	[ "$PF_DAEMON" = 1 ] || echo "[$DISPLAY_NAME] ERROR: $*" >&2
	_logline "ERR " "$*"
	return 1
}

# Log-only note: never touches stdout / stderr, so it is safe inside $( )
# (pf_filter_ips runs as X=$(pf_filter_ips ...)).
pf_note() { _logline "$1" "$2"; return 0; }

# Config warnings, logged ONCE per distinct message: pf_load_config runs every
# daemon tick. $1 = fixed internal key (a filename part, never user input),
# $2 = the message. _pf_warn_clear resets it when the value is fixed.
_pf_warn_once() {
	local f="$PF_RUN_DIR/.warn-$1" o=""
	[ -f "$f" ] && read -r o < "$f" 2>/dev/null
	[ "$o" = "$2" ] && return 0
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	printf '%s\n' "$2" > "$f" 2>/dev/null
	pf_note "WARN" "$2"
}
_pf_warn_clear() { [ -f "$PF_RUN_DIR/.warn-$1" ] && rm -f "$PF_RUN_DIR/.warn-$1" 2>/dev/null; return 0; }

pkg_install_hint() {
	local p="${1:-<pkg>}"
	if command -v apk >/dev/null 2>&1; then echo "apk add $p"
	elif command -v opkg >/dev/null 2>&1; then echo "opkg install $p"
	else echo "install $p"; fi
}

# Append $1 to the list NAMED by $2 (internal callers only; never user input
# as $2).
_app() { eval "$2=\"\${$2:+\${$2} }\$1\""; }

# Address validators: fork-free and strict, the same logic as QoS-Ex.sh, so a
# token means the same to both. A bad token fails any nft transaction it
# reaches. _isnum: plain decimal, no leading zero ("08" is a fatal ash
# arithmetic error, "010" octal).
_isnum() {
	case "${1:-}" in
		''|*[!0-9]*) return 1 ;;
		0)           return 0 ;;
		0*)          return 1 ;;
	esac
	return 0
}
pf_valid_ip4() {
	local _a="$1" _p="" _oct _n=0
	case "$_a" in
		*[!0-9./]*) return 1 ;;
	esac
	case "$_a" in
		*/*/*) return 1 ;;
		*/*)   _p="${_a#*/}"; _a="${_a%%/*}"
		       _isnum "$_p" || return 1
		       [ "$_p" -le 32 ] || return 1 ;;
	esac
	case "$_a" in
		*.) return 1 ;;
	esac
	while [ -n "$_a" ]; do
		case "$_a" in
			*.*) _oct="${_a%%.*}"; _a="${_a#*.}" ;;
			*)   _oct="$_a"; _a="" ;;
		esac
		_isnum "$_oct" || return 1
		[ "$_oct" -le 255 ] || return 1
		_n=$((_n + 1))
		[ "$_n" -le 4 ] || return 1
	done
	[ "$_n" -eq 4 ]
}
# Groups of a colon-separated address: each 1-4 hex digits, count into $_G.
_ip6_groups() {
	local _r="$1" _g
	_G=0
	[ -n "$_r" ] || return 0
	while :; do
		case "$_r" in
			*:*) _g="${_r%%:*}"; _r="${_r#*:}" ;;
			*)   _g="$_r"; _r="" ;;
		esac
		case "$_g" in
			""|*[!0-9A-Fa-f]*) return 1 ;;
		esac
		[ "${#_g}" -le 4 ] || return 1
		_G=$((_G + 1))
		[ -n "$_r" ] || break
	done
	return 0
}
pf_valid_ip6() {
	local _a="$1" _p="" _h _t _hn
	case "$_a" in
		*[!0-9A-Fa-f:/]*) return 1 ;;
	esac
	case "$_a" in
		*/*/*) return 1 ;;
		*/*)   _p="${_a#*/}"; _a="${_a%%/*}"
		       _isnum "$_p" || return 1
		       [ "$_p" -le 128 ] || return 1 ;;
	esac
	# A lone colon at either end is not part of "::" and holds no group:
	# "2a02:db8::50:" passed the group count, and nft failed the table.
	case "$_a" in
		*[0-9A-Fa-f]:|:[0-9A-Fa-f]*) return 1 ;;
	esac
	case "$_a" in
		*:::*) return 1 ;;
		*::*)  _h="${_a%%::*}"; _t="${_a#*::}"
		       _ip6_groups "$_h" || return 1
		       _hn=$_G
		       _ip6_groups "$_t" || return 1
		       [ $((_hn + _G)) -le 7 ] ;;
		*:*)   _ip6_groups "$_a" || return 1
		       [ "$_G" -eq 8 ] ;;
		*)     return 1 ;;
	esac
}
# _pf_clamp VAR DEFAULT MIN MAX (VAR an internal name): non-numeric -> DEFAULT,
# then bound. _pf_num VAR option default min max: one numeric pingfilter
# option, read, defaulted and bound.
_pf_num() {
	config_get "$1" pingfilter "$2" "$3"
	_pf_clamp "$1" "$3" "$4" "$5"
}
_pf_clamp() {
	local _v
	eval "_v=\${$1}"
	# Leading zeros are decimal ("050" = 50, as LuCI shows it).
	case "$_v" in ''|*[!0-9]*) ;; *) _v=${_v#"${_v%%[!0]*}"}; _v=${_v:-0} ;; esac
	_isnum "$_v" && [ "${#_v}" -le 9 ] || _v="$2"
	[ "$_v" -lt "$3" ] && _v="$3"
	[ "$_v" -gt "$4" ] && _v="$4"
	eval "$1=\$_v"
}
# Plain decimal coordinate: optional sign, digits, at most one point.
_pf_dec_ok() {
	local _v="${1#-}"
	case "$_v" in
		''|*[!0-9.]*|*.*.*|.*|*.) return 1 ;;
	esac
	return 0
}

# _pf_coord_ok <value> <90|180>: a plain decimal no further than that from 0.
_pf_coord_ok() {
	local i f=""
	_pf_dec_ok "$1" || return 1
	i=${1#-}
	case "$i" in *.*) f=${i#*.}; i=${i%%.*} ;; esac
	i=${i#"${i%%[!0]*}"}; i=${i:-0}
	[ "${#i}" -le 3 ] && [ "$i" -le "$2" ] || return 1
	[ "$i" -lt "$2" ] && return 0
	case "$f" in *[1-9]*) return 1 ;; esac
	return 0
}

pf_filter_ips() {
	_valid=""; _bad=""; _what="$1"; shift; _fn="$1"; shift
	for _tok in "$@"; do
		[ -n "$_tok" ] || continue
		if "$_fn" "$_tok"; then
			_valid="${_valid:+$_valid }$_tok"
		else
			_bad="${_bad:+$_bad }$_tok"
		fi
	done
	# _fn is one of the two validator names: a fixed, filename-safe key.
	if [ -n "$_bad" ]; then
		_pf_warn_once "$_fn" "ping filter: dropping invalid $_what address(es): $_bad"
	else
		_pf_warn_clear "$_fn"
	fi
	echo "$_valid"
}

. /lib/functions.sh

# Narrow GAMING_IP4/6 to the pf_devices selection (exact entries, so CIDR
# entries select cleanly). PF never monitors a device that is not a gaming
# device (Setup -> Devices & Ports). The selection is authoritative:
# matching nothing = no sources.
pf_apply_device_filter() {
	# Nothing ticked = no sources: there is no "empty means all".
	if [ -z "$PF_DEVICES" ]; then
		GAMING_IP4=""
		GAMING_IP6=""
		return 0
	fi
	local _sel4="" _sel6="" _e _s
	for _e in $GAMING_IP4; do
		for _s in $PF_DEVICES; do
			[ "$_e" = "$_s" ] && { _sel4="$_sel4 $_e"; break; }
		done
	done
	for _e in $GAMING_IP6; do
		for _s in $PF_DEVICES; do
			[ "$_e" = "$_s" ] && { _sel6="$_sel6 $_e"; break; }
		done
	done
	GAMING_IP4=${_sel4# }
	GAMING_IP6=${_sel6# }
	return 0
}

# PF watches HOSTS: @pf_gaming_src is a plain set and nft rejects a prefix
# there (even /32), failing the whole seed. /32 and /128 are hosts; wider
# prefixes are skipped and logged once. $1 = list variable, $2 = host prefix,
# $3 = warn key (internal names).
_pf_hosts_only() {
	local _v _e _o="" _b=""
	eval "_v=\${$1}"
	for _e in $_v; do
		case "$_e" in
			*"/$2") _e=${_e%/*} ;;
			*/*)     _b="${_b:+$_b }$_e"; continue ;;
		esac
		case " $_o " in *" $_e "*) continue ;; esac
		_o="${_o:+$_o }$_e"
	done
	eval "$1=\$_o"
	if [ -n "$_b" ]; then
		_pf_warn_once "$3" "ping filter: monitored devices must be single hosts — skipping prefix entries: $_b"
	else
		_pf_warn_clear "$3"
	fi
}

# PF-scoped config loader: gaming sources and pingfilter options only.
# The stock location service, asked last (plain HTTP). The HTTPS services
# are asked only while geoip_api is this: an endpoint of your own is the only
# one asked.
PF_GEOIP_DEFAULT="http://ip-api.com/json"

pf_load_config() {
	local _e _m _i
	config_load "$UCI_CFG"
	# config_get, not config_list_foreach: it returns a list's items space-
	# separated AND a value written as a plain option (`uci set ...`), which
	# config_list_foreach skips silently (as QoS-Ex.sh reads them).
	config_get GAMING_IP4 ips gaming_ipv4 ""
	config_get GAMING_IP6 ips gaming_ipv6 ""
	config_get GAMING_MAC ips gaming_mac  ""
	GAMING_IP4=$(pf_filter_ips "gaming IPv4" pf_valid_ip4 $GAMING_IP4)
	GAMING_IP6=$(pf_filter_ips "gaming IPv6" pf_valid_ip6 $GAMING_IP6)
	# pingfilter.pf_devices narrows which classified gaming devices PF
	# monitors: it can only subtract. Empty = none.
	config_get PF_DEVICES pingfilter pf_devices ""
	GAMING_IP4_ALL="$GAMING_IP4"; GAMING_IP6_ALL="$GAMING_IP6"
	pf_apply_device_filter
	_pf_hosts_only GAMING_IP4 32 hosts4
	_pf_hosts_only GAMING_IP6 128 hosts6
	# Devices named by MAC (ips.gaming_mac): each MAC's current IPv4 joins the
	# device list, re-read every PF_MAC_REFRESH s (follows DHCP). A ticked MAC
	# is a monitored device even with no address right now (a console asleep),
	# so a reload does not switch PF off.
	PF_MAC_MAP=""; PF_MAC_SEL=""
	if [ -n "$GAMING_MAC" ]; then
		_pf_mac_resolve
		_i=$(echo "$PF_DEVICES" | tr 'A-F' 'a-f')
		for _m in $GAMING_MAC; do
			case " $_i " in *" $_m "*) PF_MAC_SEL="${PF_MAC_SEL:+$PF_MAC_SEL }$_m" ;; esac
		done
		for _e in $PF_MAC_MAP; do
			_m=${_e%%=*}; _i=${_e#*=}
			case " $GAMING_IP4_ALL " in *" $_i "*) ;; *) GAMING_IP4_ALL="${GAMING_IP4_ALL:+$GAMING_IP4_ALL }$_i" ;; esac
			case " $PF_MAC_SEL " in *" $_m "*)
				case " $GAMING_IP4 " in *" $_i "*) ;; *) GAMING_IP4="${GAMING_IP4:+$GAMING_IP4 }$_i" ;; esac ;;
			esac
		done
	fi
	# Manual allow / deny lists. Hosts stay in PF_WHITELIST / PF_BLACKLIST
	# (every per-server path reads them); IPv4 prefixes (/8../31) go to
	# PF_WL_NETS / PF_BL_NETS (@wl_net / @bl_net, _pf_in_nets).
	PF_WHITELIST=""; PF_BLACKLIST=""
	config_list_foreach pingfilter whitelist _app PF_WHITELIST
	config_list_foreach pingfilter blacklist _app PF_BLACKLIST
	_pf_split_nets PF_WHITELIST PF_WL_NETS
	_pf_split_nets PF_BLACKLIST PF_BL_NETS
	# Shaper-owned keys: fallbacks must match QoS-Ex.sh load_config (enabled
	# 0, wan eth0). PF refuses to run when the shaper is off.
	config_get ENABLED             settings   enabled          "0"
	config_get PF_ENABLED          pingfilter enabled          "0"
	config_get PF_WAN              settings   wan              "eth0"
	# Pinned to 0 / 1: emitted unquoted into the servers JSON.
	case "$ENABLED" in 1) ;; *) ENABLED=0 ;; esac
	case "$PF_ENABLED" in 1) ;; *) PF_ENABLED=0 ;; esac

	# A non-numeric threshold would fail OPEN (a test that errors = allowed).
	#   ""      -> absent / cleared: 0 (visibility only), the default.
	#   garbage -> a typo ("50ms"): 0 would disable filtering, so 50 ms.
	# Warned via the log only: stdout here is every verb's output.
	config_get PF_THRESHOLD_MS     pingfilter threshold_ms     "0"
	case "$PF_THRESHOLD_MS" in
		'') PF_THRESHOLD_MS=0; _pf_warn_clear thr ;;
		*[!0-9]*)
			_pf_warn_once thr "ping filter: threshold_ms='$PF_THRESHOLD_MS' is not a number — using 50ms default (fix via: pf threshold <ms>)"
			PF_THRESHOLD_MS=50
			;;
		*)
			# Decimal: to $(( )) "050" is octal and "08" a fatal error.
			PF_THRESHOLD_MS=${PF_THRESHOLD_MS#"${PF_THRESHOLD_MS%%[!0]*}"}
			PF_THRESHOLD_MS=${PF_THRESHOLD_MS:-0}
			_pf_warn_clear thr ;;
	esac
	[ "$PF_THRESHOLD_MS" -le 5000 ] 2>/dev/null || PF_THRESHOLD_MS=5000
	config_get PF_BLOCK_MODE       pingfilter block_mode       "ping"
	# Anything but the two known modes reads as ping.
	case "$PF_BLOCK_MODE" in ping|distance) ;; *) PF_BLOCK_MODE=ping ;; esac
	# Ping Catch (distance mode only): outside the radius, servers at or under
	# this are let in. 0 = off. Each mode keeps its number in UCI over a mode
	# switch; the other mode's is zeroed here, in memory: the one gate every
	# reader inherits.
	_pf_num PF_PING_CATCH       ping_catch_ms      0   0   250
	if [ "$PF_BLOCK_MODE" = "distance" ]; then PF_THRESHOLD_MS=0; else PF_PING_CATCH=0; fi
	# Limit margin: a reading passes at <= ms + ms*pct/100. 0 = hard limit.
	_pf_num PF_PING_VAR_PCT     ping_var_pct       5   0    50
	config_get PF_HOME_LAT        pingfilter home_lat         ""
	config_get PF_HOME_LON         pingfilter home_lon         ""
	# Plain decimals in range, or unset: anything else reads as 0 (a home in
	# the Gulf of Guinea).
	if [ -n "$PF_HOME_LAT$PF_HOME_LON" ] \
	   && ! { _pf_coord_ok "$PF_HOME_LAT" 90 && _pf_coord_ok "$PF_HOME_LON" 180; }; then
		_pf_warn_once home "ping filter: home location '$PF_HOME_LAT,$PF_HOME_LON' is not a valid lat,lon - treated as not set"
		PF_HOME_LAT=""; PF_HOME_LON=""
	else
		_pf_warn_clear home
	fi
	_pf_num PF_HOME_RADIUS_KM   home_radius_km  1000  50 20000
	_PF_IRM=""
	# New servers with a limit to meet (a ping limit, Ping Catch): the first
	# first_pkts packets of each flow pass, so conntrack times the game's own
	# handshake, then the hold keeps the rest until graded. 0 = no hold.
	_pf_num PF_FIRST_PKTS       first_pkts         2   0    20
	# Region lock: a known country not on the list is blocked, whatever its
	# ping. "|"-joined (names hold spaces).
	PF_COUNTRIES=""
	config_list_foreach pingfilter allow_country _pf_app_bar
	# UDP ports that are never a game server (STUN, party chat): not
	# discovered, graded or held.
	config_get PF_IGNORE_PORTS     pingfilter ignore_ports     "3478-3481"
	PF_UDP_PORT_MIN="1024"
	PF_UDP_PORT_MAX="65535"
	_pf_ports_norm "$PF_IGNORE_PORTS"

	# --- tuning ------------------------------------------------------------
	# The area figure lowered this many percent (it read above its servers).
	_pf_num PF_AREA_ADJ         area_adjust_pct    5   0    50
	# A /24 holding this many whitelist (or blacklist) hosts is listed whole;
	# with Ping Catch, this many measured servers all on one side of it
	# (_pf_auto_nets). 0 = off; 1 is raised to 2 so one server never spreads.
	_pf_num PF_AUTO_PIN         auto_pin           2   0    20
	[ "$PF_AUTO_PIN" = "1" ] && PF_AUTO_PIN=2
	config_get PF_GEOIP_LOOKUP     pingfilter geoip_lookup     "yes"
	# OpenWrt booleans, as the shaper reads its switches: "1" is on.
	case "$PF_GEOIP_LOOKUP" in
		[Yy][Ee][Ss]|1|[Oo][Nn]|[Tt][Rr][Uu][Ee]|[Ee][Nn][Aa][Bb][Ll][Ee][Dd]) PF_GEOIP_LOOKUP=yes ;;
		*) PF_GEOIP_LOOKUP=no ;;
	esac
	config_get PF_GEOIP_API        pingfilter geoip_api        "$PF_GEOIP_DEFAULT"
	# "active" needs a measured, sustained UDP rate (a rest-mode console parks
	# flows in conntrack forever). Enter at active_pps, exit at half.
	_pf_num PF_ACTIVE_PPS       active_pps        20   5   500
	# Server memory, and how often it is copied to flash.
	_pf_num PF_ROW_TTL          row_ttl       604800 43200 2592000
	_pf_num PF_MAX_SERVERS      max_servers      250  50  2000
	_pf_num PF_PERSIST_INTERVAL persist_interval 3600 60 86400
	config_get PF_TELEMETRY        pingfilter telemetry        "1"
	# Handshake RTT needs the conntrack tool.
	PF_HS_RTT=1
	command -v conntrack >/dev/null 2>&1 || PF_HS_RTT=0

	# --- fixed: how the Ping Filter works, not site policy -----------------
	PF_PING_COUNT=5           # ICMP echoes per probe (median, first dropped)
	PF_PROBE_RETRIES=5        # re-probes of a server with no or a blocking ping
	PF_AREA_KM=150            # measured servers this near lend their ping:
	PF_AREA_MIN=3             # ... the median of this many, else the nearest
	PF_DIST_BASE_MS=10        # distance model: base + km x slope (us/km),
	PF_DIST_SLOPE_US=18       # ... rescaled by this link's measured /24s
	PF_GEO_RETRY=60           # s before a failed location lookup is retried
	PF_MATCH_END_WAIT=30      # s after a match before a put-off block lands
	PF_PRESENCE_PPS=1         # game UDP rate that is matchmaking
	PF_CONN_MIN_PPS=$((PF_ACTIVE_PPS / 2))   # the server being played
	PF_SET_TIMEOUT=43200      # s a block or an estimate allow lasts unseen
	PF_PREFIX_TTL=2592000     # s a measured /24 lends its ping
	PF_MAP_KEEP=3600          # s idle that closes the Map's play window
	PF_GAP_MS=120             # a silence longer than this is a gap (stutter)
	PF_SESSION_MIN=60         # play shorter than this is not graded
	PF_TELE_GAP=20            # a pause longer than this ends a session
	PF_ACTIVE_INTERVAL=1      # scan pause while a game is running (s)
	PF_ARMED_INTERVAL=1       # ... while the console is online, no game yet
	PF_IDLE_INTERVAL=30       # ... with nothing going on
	PF_IDLE_POLL=2            # how often idle re-checks for activity
	PF_RECHECK_INTERVAL=30    # re-probe pace for a server that ignores echo
	PF_SUS_PCT=25             # a first ICMP this far over the estimate is
	PF_SUS_TTL=600            # ... suspect until a second within this pairs
	PF_HS_SUS_X=2             # with no limit, a one-connect handshake over
	PF_HS_SUS_MS=50           # ... estimate x this + this ms waits for a 2nd
	PF_REFRESH_AGE=259200     # s before an ICMP figure is re-measured (idle)
	PF_REFRESH_PER=2          # stale figures re-probed per idle sweep
	PF_PARALLEL_CAP=20        # ICMP bursts in flight at once
	PF_UDP_SAMPLE_SECS=2      # one jitter window
	PF_RTT_INTERVAL=2         # in-play ICMP probe pace
	PF_TELE_JIT_MINPPS=10     # below this a flow is not game-rate
	PF_TELE_RING=120          # live graph samples kept per server
	PF_TELE_CKPT_WIN=12       # jitter windows that make one graded segment
	PF_TELE_EWMA_REF=90       # segment length the history EWMA was tuned for
	PF_MAC_REFRESH=30         # how often a MAC device's address is re-read
	PF_GEO_PER_PASS=2         # location lookups per idle pass (backfill)
	PF_TELE_CKPT=90           # graded segment length (s), over session_min
	PF_TELE_FINALIZE=25       # idle wait (s) before a session is folded in
	# Lite (small routers; Auto Setup turns it on for its low tier): the ping
	# limit or radius, locations, lists, the hold and the session guard.
	# No gameplay grading (telemetry), handshake timing or Ping Catch;
	# slower scans and fewer pings at once.
	config_get PF_LITE pingfilter lite "0"
	if [ "$PF_LITE" = 1 ]; then
		PF_TELEMETRY=0; PF_HS_RTT=0; PF_PING_CATCH=0
		PF_ACTIVE_INTERVAL=2; PF_ARMED_INTERVAL=3; PF_PARALLEL_CAP=4
	else
		PF_LITE=0
	fi
}

_pf_app_bar() { PF_COUNTRIES="${PF_COUNTRIES:+$PF_COUNTRIES|}$1"; }

# "a b/24 c" in $1 -> hosts back in $1, IPv4 prefixes (/8../31) in $2. /32 is
# a host; any other slash is dropped with a warning.
_pf_split_nets() {
	local _v _e _h="" _n="" _b _bad=""
	eval "_v=\${$1}"
	for _e in $_v; do
		case "$_e" in */32) _e=${_e%/*} ;; esac
		# Hosts are validated too: an unchecked entry reaches the geo lookups,
		# the cache and the UI.
		case "$_e" in
			*/*)  _b=${_e#*/}
			      if pf_valid_ip4 "$_e" && [ "$_b" -ge 8 ] && [ "$_b" -le 31 ]; then
			          _n="${_n:+$_n }$_e"
			      else
			          _bad="${_bad:+$_bad }$_e"
			      fi ;;
			*:*)  if pf_valid_ip6 "$_e"; then _h="${_h:+$_h }$_e"; else _bad="${_bad:+$_bad }$_e"; fi ;;
			*)    if pf_valid_ip4 "$_e"; then _h="${_h:+$_h }$_e"; else _bad="${_bad:+$_bad }$_e"; fi ;;
		esac
	done
	eval "$1=\$_h; $2=\$_n"
	if [ -n "$_bad" ]; then
		_pf_warn_once "net-$1" "ping filter: ignoring list entries that are not a host or an IPv4 /8-/31 prefix: $_bad"
	else
		_pf_warn_clear "net-$1"
	fi
}

_pf_ip2int() {
	local IFS=.
	# shellcheck disable=SC2086
	set -- $1
	_I=$(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
}
_pf_in_nets() {
	local _n _i
	[ -n "$2" ] || return 1
	case "$1" in ''|*:*|*[!0-9.]*) return 1 ;; esac
	_pf_ip2int "$1"; _i=$_I
	for _n in $2; do
		_pf_ip2int "${_n%/*}"
		[ $(( (_i ^ _I) >> (32 - ${_n#*/}) )) -eq 0 ] && return 0
	done
	return 1
}
# Which list covers this address, host entries first: _LS = whitelist |
# blacklist | "" (on both prefix lists = neither).
_pf_list_state() {
	_LS=""
	case " $PF_WHITELIST " in *" $1 "*) _LS=whitelist; return 0 ;; esac
	case " $PF_BLACKLIST " in *" $1 "*) _LS=blacklist; return 0 ;; esac
	if _pf_in_nets "$1" "$PF_WL_NETS"; then
		_pf_in_nets "$1" "$PF_BL_NETS" || _LS=whitelist
	elif _pf_in_nets "$1" "$PF_BL_NETS"; then
		_LS=blacklist
	fi
	return 0
}

# "3478-3481, 5000" -> PF_IGNORE_NFT "3478-3481, 5000" (nft set) and
# PF_IGNORE_AWK "3478-3481 5000-5000" (awk). Bad or overlapping entries drop.
_pf_ports_norm() {
	local _t _lo _hi _k _o="" _a="" _ov _had_f
	case "$-" in *f*) _had_f=1 ;; *) _had_f=0 ;; esac
	set -f
	# shellcheck disable=SC2046
	set -- $(echo "$1" | tr ',' ' ')
	[ "$_had_f" = 1 ] || set +f
	for _t in "$@"; do
		case "$_t" in ''|*[!0-9-]*|-*|*-|*-*-*) continue ;; esac
		_lo=${_t%-*}; _hi=${_t#*-}
		_isnum "$_lo" && _isnum "$_hi" && [ "${#_hi}" -le 5 ] || continue
		[ "$_lo" -ge 1 ] && [ "$_hi" -le 65535 ] && [ "$_lo" -le "$_hi" ] || continue
		_ov=0
		for _k in $_a; do
			[ "$_lo" -le "${_k#*-}" ] && [ "$_hi" -ge "${_k%-*}" ] && { _ov=1; break; }
		done
		[ "$_ov" = 1 ] && continue
		_a="${_a:+$_a }$_lo-$_hi"
		if [ "$_lo" = "$_hi" ]; then _o="${_o:+$_o, }$_lo"; else _o="${_o:+$_o, }$_lo-$_hi"; fi
	done
	PF_IGNORE_NFT=$_o; PF_IGNORE_AWK=$_a
}

# MAC -> its current IPv4, from the neighbour table and DHCP leases:
# PF_MAC_MAP = "mac=ip ...". An unseen MAC is not monitored until it appears.
_pf_mac_resolve() {
	GAMING_MAC=$(echo "$GAMING_MAC" | tr 'A-F' 'a-f')
	PF_MAC_MAP=$({
		ip -4 neigh show 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") print tolower($(i + 1)), $1 }'
		[ -r /tmp/dhcp.leases ] && awk '{ print tolower($2), $3 }' /tmp/dhcp.leases 2>/dev/null
	} | awk -v want="$GAMING_MAC" '
		BEGIN { n = split(want, W, " "); for (i = 1; i <= n; i++) M[W[i]] = 1 }
		($1 in M) && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !S[$1 " " $2]++ { printf "%s=%s ", $1, $2 }')
}

pf_is_private_ip() {
	local ip="$1"
	case "$ip" in
		10.*|192.168.*) return 0 ;;
		172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
		100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
		127.*|169.254.*|0.*) return 0 ;;
		22[4-9].*|23[0-9].*|24[0-9].*|25[0-5].*) return 0 ;;
		fe80:*|fc??:*|fd??:*|::1|ff??:*) return 0 ;;
	esac
	return 1
}

# The family of a HOST address, or nothing: the gate for every nft element
# site, which splice the value into nft text (a loose glob let
# "1.2.3.4 }; flush ruleset" through). Prefixes are refused: every set here
# is a plain addr set.
pf_ip_family() {
	case "$1" in
		*/*) echo "" ;;
		*:*) if pf_valid_ip6 "$1"; then echo "v6"; else echo ""; fi ;;
		*)   if pf_valid_ip4 "$1"; then echo "v4"; else echo ""; fi ;;
	esac
}

# Row with tabs -> \037 (US, never in our data), so the caller can split with
# IFS=US and keep empty fields (tab is IFS whitespace and collapses).
_pf_us() { printf '%s' "$1" | tr '\t' '\037'; }
PF_US=$(printf '\037')

# Split a 12-col servers.tsv row into PF_C_* (empty-field-safe, one fork).
# Copy them to locals at once: the next _pf_row / _pf_georow overwrites them.
_pf_row() {
	local _o=$IFS; IFS=$PF_US; set -f; set -- $(_pf_us "$1"); set +f; IFS=$_o
	PF_C_IP=$1; PF_C_STATE=$2; PF_C_PING=$3; PF_C_SRC=$4; PF_C_LAT=$5
	PF_C_LON=$6; PF_C_CO=$7; PF_C_CI=$8; PF_C_TS=$9; PF_C_LAN=${10}
	PF_C_JIT=${11}; PF_C_LOSS=${12}
}
# Split a geo-cache row (ip lat lon country city ts) into PF_G_* (PF_G_IP
# mirrors the schema; no reader).
# shellcheck disable=SC2034
_pf_georow() {
	local _o=$IFS; IFS=$PF_US; set -f; set -- $(_pf_us "$1"); set +f; IFS=$_o
	PF_G_IP=$1; PF_G_LAT=$2; PF_G_LON=$3; PF_G_CO=$4; PF_G_CI=$5; PF_G_TS=$6
}
# Split a "lat<tab>lon<tab>country<tab>city" lookup result into PF_R_*.
_pf_geo4() {
	local _o=$IFS; IFS=$PF_US; set -f; set -- $(_pf_us "$1"); set +f; IFS=$_o
	PF_R_LAT=$1; PF_R_LON=$2; PF_R_CO=$3; PF_R_CI=$4
}

# Remove all per-server runtime scratch for one IP (telemetry rings/counters,
# session stamps, in-play readings).
_pf_purge_ip_runtime() {
	rm -f "$PF_TELE_PREFIX$1" "$PF_RUN_DIR/.ctr-$1" "$PF_RUN_DIR/.samp-$1" \
		"$PF_RUN_DIR/stats-$1" "$PF_TELE_ACC_PREFIX$1" "$PF_RUN_DIR/.play-$1" \
		"$PF_RUN_DIR/.ipr-$1" "$PF_RUN_DIR/.slow-$1" \
		"$PF_RUN_DIR/.rtry-$1" "$PF_RUN_DIR/.trttsil-$1" \
		"$PF_RUN_DIR/.sus-$1" "$PF_RUN_DIR/.fage-$1" 2>/dev/null
}

# Power-cut-safe copy to flash: a temp on the DEST fs, then rename, so a
# half-written cache is never restored as truth.
_pf_atomic_cp() {
	[ -f "$1" ] || return 0
	cmp -s "$1" "$2" 2>/dev/null && return 0
	cp "$1" "$2.tmp" 2>/dev/null && mv "$2.tmp" "$2" 2>/dev/null
	rm -f "$2.tmp" 2>/dev/null
}

# Is this ping_src a REAL round trip? Ping Catch is a measurement-gated
# exception: fed the distance estimate it would be a second, wider radius.
# "real" = an ICMP reading on old rows, and a handshake RTT reading. Retired
# "udp" / "tcp" read as unmeasured and are re-probed.
_pf_src_measured() {
	case "$1" in real|icmp) return 0 ;; esac
	return 1
}

# ICMP probes in EVERY mode: the reading is the ping column and what the /24
# memory learns from. In pure distance it is never a verdict input (only a
# Ping Catch reads it, and the radius when no location can come).

# --- readings -----------------------------------------------------------------
# The limit a figure is held to, into _LIM: the ping limit (ping mode) or the
# Ping Catch (distance), plus ping_var_pct percent (80 ms @ 5% -> 84). 0 =
# none (watch only, pure distance). One copy for the verdict, the fold, the
# group and the kernel /24 sets.
_pf_lim() {
	if [ "${PF_BLOCK_MODE:-ping}" = "distance" ]; then _LIM=${PF_PING_CATCH:-0}; else _LIM=${PF_THRESHOLD_MS:-0}; fi
	_LIM=$((_LIM + _LIM * ${PF_PING_VAR_PCT:-5} / 100))
}
# The one way an ICMP, handshake or in-play reading changes a row's figure.
# _pf_fold <old ms> <old src> <old connects> <ms> <src> <connects> [fresh]
# -> _F_MS _F_SRC _F_N (a handshake's connects, servers.tsv col 12; 0 for
# any other figure); 1 = not taken. Every reading is an upper bound:
#   - no own figure (an estimate, or none): taken -- an estimate is the
#     last resort; a handshake over the limit from one connect is not
#     while the estimate is under it (server think time, one slow connect:
#     a server blocked on it is never timed again); with no limit (watch
#     only, pure distance) only one far over the estimate (over hs_sus_x
#     times it plus hs_sus_ms) is not -- the first reply of a flow that is
#     not a handshake (telemetry, a late matchmaking answer) reads seconds.
#     A second connect lands either;
#   - an own figure (ICMP or handshake): only a LOWER reading is taken, so
#     one over the limit never replaces one under it; the same handshake low
#     timed on more connects updates the count;
#   - Re-check cache (fresh): an ICMP reading replaces an ICMP figure, so it
#     may rise; never a handshake;
#   - confirmed over (a handshake over the limit on 2+ connects) stays while
#     every reading is over the limit: a lower one lowers the figure but
#     keeps src real and the count, and such a handshake over an own figure
#     itself over the limit sets it (the figure stays the lower).
_pf_fold() {
	local om="$1" os="$2" m="$4" s="$5" n="${6:-1}" c=0
	_F_MS=$om; _F_SRC=$os; _F_N=0
	case "$3" in ''|*[!0-9]*) ;; *) [ "$os" = real ] && _F_N=$3 ;; esac
	[ "$m" -gt 0 ] 2>/dev/null || return 1
	case "$n" in ''|*[!0-9]*) n=1 ;; esac
	_pf_lim
	if [ "$_LIM" -gt 0 ] && [ "$m" -gt "$_LIM" ] && _pf_src_measured "$os" \
	   && [ "$om" -gt "$_LIM" ] 2>/dev/null; then
		[ "$os" = real ] && c=$_F_N
		[ "$s" = real ] && [ "$n" -gt "$c" ] && c=$n
		if [ "$c" -ge 2 ]; then
			[ "$m" -lt "$om" ] || { [ "$os" = real ] && [ "$c" -le "$_F_N" ] && return 1; m=$om; }
			_F_MS=$m; _F_SRC=real; _F_N=$c
			return 0
		fi
	fi
	if _pf_src_measured "$os" && [ "$om" -gt 0 ] 2>/dev/null; then
		if [ "$s$os" = realreal ] && [ "$m" -eq "$om" ]; then
			[ "$n" -gt "$_F_N" ] || return 1
		elif ! { [ "$7" = fresh ] && [ "$s$os" = icmpicmp ]; } && ! [ "$m" -lt "$om" ]; then
			return 1
		fi
	elif [ "$s" = real ] && [ "$n" -lt 2 ] && [ "$om" -gt 0 ] 2>/dev/null \
	   && { { [ "$_LIM" -gt 0 ] && [ "$m" -gt "$_LIM" ] && [ "$om" -le "$_LIM" ]; } \
	      || { [ "$_LIM" -eq 0 ] && [ "$m" -gt $((om * ${PF_HS_SUS_X:-2} + ${PF_HS_SUS_MS:-50})) ]; }; }; then
		return 1
	fi
	_F_MS=$m; _F_SRC=$s; _F_N=0
	[ "$s" = real ] && _F_N=$n
	return 0
}
# A first ICMP reading far over the estimate is SUSPECT: a probe can land on
# a loaded line or a slowed echo, and a figure, once taken, only comes down.
# It is stamped (.sus-<ip>, "ms ts") and NOT taken; the row stays unmeasured,
# so the scan's retry probe brings a second opinion within recheck_interval.
# A second reading still over the band within sus_ttl confirms it -- the
# LOWER of the two is taken (both are upper bounds); one back in the band
# lands as usual. Only the scan's own probes (PF_SUS=1, _pf_rtt_ingest) on a
# row still on an estimate are gated: handshakes have their own connect
# rule, in-play readings their play median, a Re-check (fresh) is the
# user's own measurement, and with no estimate there is no anchor.
# _pf_sus <ip> <ms> <src> [fresh] (reads the _pf_row globals):
# 1 = held for confirmation; 0 = fold it, _S_MS the value (0 = the caller's).
_pf_sus() {
	local f="$PF_RUN_DIR/.sus-$1" _n="${PF_NOW:-$(date +%s)}" _t sm="" st=""
	_S_MS=0
	[ "${PF_SUS:-0}" = 1 ] || return 0
	if [ "$3" != icmp ] || [ "$4" = fresh ] || _pf_src_measured "$PF_C_SRC" \
	   || ! [ "$PF_C_PING" -gt 0 ] 2>/dev/null; then
		[ -f "$f" ] && rm -f "$f" 2>/dev/null
		return 0
	fi
	_t=$((PF_C_PING + PF_C_PING * ${PF_SUS_PCT:-25} / 100))
	if [ "$2" -le "$_t" ] 2>/dev/null; then
		[ -f "$f" ] && rm -f "$f" 2>/dev/null
		return 0
	fi
	[ -f "$f" ] && read -r sm st < "$f" 2>/dev/null
	if [ "$sm" -gt 0 ] 2>/dev/null && [ $((_n - ${st:-0})) -le "${PF_SUS_TTL:-600}" ] 2>/dev/null; then
		rm -f "$f" 2>/dev/null
		_S_MS=$2
		[ "$sm" -lt "$2" ] 2>/dev/null && _S_MS=$sm
		return 0
	fi
	printf '%s %s\n' "$2" "$_n" > "$f" 2>/dev/null
	pf_note "INFO" "ping filter: ICMP ${2}ms for $1 is over its ${PF_C_PING}ms estimate by more than ${PF_SUS_PCT:-25}% - checked again before it is taken"
	return 1
}
# _pf_reading <ip> <ms> <src> <connects> <keep> [fresh]: one reading for a
# server with a row, folded; a reading taken teaches the /24 memory and the
# row is graded on the shared path (_pf_verdict). 1 = not taken, or no row.
_pf_reading() {
	local ex ms="$2" PF_HSN
	_V=""; _V_OLD=""
	ex=$(pf_cache_get "$1")
	[ -n "$ex" ] || return 1
	_pf_row "$ex"
	_pf_sus "$1" "$ms" "$3" "$6" || return 1
	[ "$_S_MS" -gt 0 ] 2>/dev/null && ms=$_S_MS
	_pf_fold "$PF_C_PING" "$PF_C_SRC" "$PF_C_LOSS" "$ms" "$3" "$4" "$6" || return 1
	_pf_prefix_learn "$1" "$ms" "$PF_C_LAT" "$PF_C_LON" "$PF_C_CO" "$PF_C_CI"
	PF_HSN=$_F_N
	_pf_verdict "$1" "$_F_MS" "$_F_SRC" "$5"
}

# --- the session guard --------------------------------------------------------
# A server being played is never cut by the filter's own re-grades: an allow
# that a reading, a location or a re-grade turns into a block while the
# server is IN SESSION stays allowed and is marked due ($PF_RUN_DIR/.due-<ip>);
# once the session is over pf_due_apply grades it again, blocked then only
# if still over. In session (_pf_sess_tick, from the daemon's conntrack
# snapshot): its reply packets reached conn_min_pps, then any reply packet
# keeps it in, and it ends match_end_wait s after the last one; a server
# first seen while another server of the same device was at game rate in
# the last 5 s (a relay or host handoff) is in session from its first
# packet, and its first verdict is guarded too (_pf_decide). .play-<ip> =
# the last packet of a server in session. tmpfs: kept over a daemon
# restart, gone at boot, disable, Clear cache, New game and forget. A change
# the user makes from the live controls (mode, limit, radius, Ping Catch,
# presets, Re-check cache) runs with PF_USER_NOW=1 and lands at once.
_pf_in_session() {
	local t=""
	[ -f "$PF_RUN_DIR/.play-$1" ] && read -r t < "$PF_RUN_DIR/.play-$1" 2>/dev/null
	case "$t" in ''|*[!0-9]*) return 1 ;; esac
	[ $(( ${PF_NOW:-$(date +%s)} - t )) -lt "${PF_MATCH_END_WAIT:-30}" ]
}
# _pf_defer <ip>: 0 = in session, kept allowed and marked due.
_pf_defer() {
	_pf_in_session "$1" || return 1
	if [ ! -f "$PF_RUN_DIR/.due-$1" ]; then
		: > "$PF_RUN_DIR/.due-$1" 2>/dev/null
		pf_note "INFO" "ping filter: $1 over the limit while being played - kept, blocked after the game on it"
	fi
	return 0
}
# One awk per daemon loop over this tick's snapshot (game-port UDP rows of
# $PF_CT_DST). $PF_RUN_DIR/.sess, one line per server: ip reply-packets
# epoch last-at-game-rate last-packet-in-session (0 = not in session)
# device. A handoff is per device; only a server that reached game rate
# itself is kept in by a stray packet. A stamp gone (forget, evict) ends
# its session; the stamp of a server gone from the snapshot and out of
# session is removed.
_pf_sess_tick() {   # now
	[ "${PF_CT_FRESH:-0}" = 1 ] || return 0
	local f="$PF_RUN_DIR/.sess" gone
	[ -f "$f" ] || : > "$f"
	gone=$(awk -F'\t' -v now="$1" -v cmp="${PF_CONN_MIN_PPS:-10}" -v w="${PF_MATCH_END_WAIT:-30}" \
	    -v dir="$PF_RUN_DIR" -v sf="$f" -v out="$f.$$" '
		BEGIN {
			while ((getline l < sf) > 0) {
				split(l, a, "\t"); P[a[1]] = a[2]; T[a[1]] = a[3]; G[a[1]] = a[4]; S[a[1]] = a[5]; D[a[1]] = a[6]
				if (a[5] + 0) { o = dir "/.play-" a[1]; if ((getline x < o) <= 0) { S[a[1]] = 0; G[a[1]] = 0 }; close(o) }
				if (now - G[a[1]] <= 5) H[a[6]] = 1
			}
			close(sf)
		}
		$5 == 1 { C[$1] += $3; if (D[$1] == "") D[$1] = $2 }
		END {
			for (ip in C) {
				s = (now - S[ip] < w) ? S[ip] + 0 : 0
				if (ip in P) {
					d = C[ip] - P[ip]; if (d < 0) d = C[ip]
					dt = now - T[ip]; if (dt < 1) dt = 1
					if (d / dt >= cmp + 0) { G[ip] = now; s = now }
					else if (d > 0 && s && G[ip] + 0 > 0) s = now
				} else if (H[D[ip]]) s = now
				if (s == now) { o = dir "/.play-" ip; print now > o; close(o) }
				printf "%s\t%.0f\t%.0f\t%.0f\t%.0f\t%s\n", ip, C[ip], now, G[ip], s, D[ip] > out
			}
			# Gone from conntrack: in session until its wait is over.
			for (ip in P) if (!(ip in C)) {
				if (now - S[ip] < w) printf "%s\t%.0f\t%.0f\t%.0f\t%.0f\t%s\n", ip, P[ip], T[ip], G[ip], S[ip], D[ip] > out
				else { o = dir "/.play-" ip; if ((getline x < o) > 0) printf "%s ", o; close(o) }
			}
			printf "" > out
		}' "$PF_CT_DST" 2>/dev/null) && mv "$f.$$" "$f" 2>/dev/null
	[ -f "$f.$$" ] && rm -f "$f.$$" 2>/dev/null
	# shellcheck disable=SC2086 # stamp paths: no blanks or glob characters
	[ -n "$gone" ] && rm -f $gone 2>/dev/null
	return 0
}
# Land the blocks put off while a server was played: once it is out of
# session it is graded on what it holds now (no guard), blocked (conntrack
# cut) only if still over. $1 = the loop's clock.
pf_due_apply() {
	local f ip ex pg sr PF_NOW="${1:-$PF_NOW}"
	for f in "$PF_RUN_DIR"/.due-*; do
		[ -f "$f" ] || continue
		ip=${f##*/.due-}
		_pf_in_session "$ip" && continue
		rm -f "$f" 2>/dev/null
		ex=$(pf_cache_get "$ip")
		[ -n "$ex" ] || continue
		_pf_row "$ex"
		[ "$PF_C_STATE" = "allowed" ] || continue
		pg=$PF_C_PING; sr=$PF_C_SRC
		_pf_verdict "$ip" "$pg" "$sr" 0
		[ "$_V" = "blocked" ] && pf_note "INFO" "ping filter: blocked $ip after the game on it (${pg}ms ${sr}, over the limit)"
	done
	return 0
}

# --- handshake RTT ------------------------------------------------------------
# A server that ignores echo still answers the game. conntrack raises NEW on a
# flow's first packet and UPDATE on the first reply (IPS_SEEN_REPLY): the gap
# is one round trip on the game's port, plus server think time. Nothing sent,
# nothing captured; both events land before flow offload takes the flow.
#   - An UPPER bound: keep the MINIMUM per server, with the number of
#     connects it was timed on (_pf_fold: over the limit on one connect does
#     not outweigh an estimate under it; on two it is confirmed over). Flows
#     started within tele_gap s of the last counted one are the same connect
#     (a game opens several at once).
#   - Only the handshake: a flow re-made just after its entry died is skipped.
#   - A new server under the hold: its first first_pkts packets pass, so the
#     first exchange is timed (_pf_hold_on).
# Output: $PF_RUN_DIR/hs-<ip> = "min_ms connects", written when either moves.
# Scope matches @pf_seen.
pf_hs_listen() {
	_pf_exec_as qos-ex-pf-handshake conntrack -E -p udp -e NEW,UPDATES,DESTROY -o timestamp 2>/dev/null | \
	awk -v qos_ex_pf=handshake -v gips="$GAMING_IP4" -v pmin="${PF_UDP_PORT_MIN:-1024}" -v dir="$PF_RUN_DIR" -v ign="$PF_IGNORE_AWK" \
	    -v gap="${PF_TELE_GAP:-20}" '
		BEGIN { n = split(gips, A, " "); for (i = 1; i <= n; i++) G[A[i]] = 1
			ni = split(ign, R, " "); for (i = 1; i <= ni; i++) { split(R[i], q, "-"); IL[i] = q[1] + 0; IH[i] = q[2] + 0 } }
		function ignored(p,    i) { for (i = 1; i <= ni; i++) if (p >= IL[i] && p <= IH[i]) return 1; return 0 }
		$2 != "[NEW]" && $2 != "[UPDATE]" && $2 != "[DESTROY]" { next }
		{
			src = ""; dst = ""; sp = ""; dp = ""
			for (i = 3; i <= NF && dp == ""; i++) {
				if      (src == "" && substr($i, 1, 4) == "src=")   src = substr($i, 5)
				else if (dst == "" && substr($i, 1, 4) == "dst=")   dst = substr($i, 5)
				else if (sp  == "" && substr($i, 1, 6) == "sport=") sp  = substr($i, 7)
				else if (substr($i, 1, 6) == "dport=")              dp  = substr($i, 7)
			}
			if (!(src in G) || dp + 0 < pmin + 0 || ignored(dp + 0)) next
			if (dst !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
			k = src " " dst " " sp " " dp
			# "[sec.usec]": kept as two integers, a double cannot hold both.
			t = substr($1, 2, length($1) - 2)
			p = index(t, "."); if (p < 2) next
			s = substr(t, 1, p - 1) + 0; u = substr(t, p + 1) + 0
			# A flow destroyed and re-made within 2 s was flushed mid-stream
			# (conntrack -F, a firewall or shaper restart): the next packet
			# back is the stream, not an answer. Not a handshake -- skipped.
			if ($2 == "[DESTROY]") {
				if (++nx > 512) { split("", X); nx = 1 }
				X[k] = s
				next
			}
			if ($2 == "[NEW]") {
				if ((k in X) && s - X[k] < 2) { delete S[k]; next }
				if (++np > 512) { split("", S); split("", U); np = 1 }
				S[k] = s; U[k] = u
				next
			}
			if (!(k in S) || index($0, "[UNREPLIED]")) next
			st = S[k]
			ms = int((s - S[k]) * 1000 + (u - U[k]) / 1000 + 0.5)
			delete S[k]; delete U[k]; np--
			if (ms > 2000) next
			if (ms < 1) ms = 1
			if (!(dst in N) && ++nd > 2048) { split("", N); split("", M); split("", T); nd = 1 }
			c = 0
			if (!(dst in N) || st - T[dst] >= gap + 0) { N[dst]++; T[dst] = st; c = 1; if (N[dst] == 1) M[dst] = ms }
			if (ms < M[dst]) { M[dst] = ms; c = 1 }
			if (!c) next
			f = dir "/hs-" dst
			print M[dst], N[dst] > f
			close(f)
		}'
}

# One listener, restarted when it died or the device list changed.
# PF_HS_PID / PF_HS_SRC are daemon globals.
_pf_hs_stop() {
	[ -n "$PF_HS_PID" ] || return 0
	# shellcheck disable=SC2046
	kill $(_pf_proc_table | _pf_pick kids "$PF_HS_PID") "$PF_HS_PID" 2>/dev/null
	PF_HS_PID=""
}
_pf_hs_tick() {
	if [ "${PF_HS_RTT:-0}" != "1" ] || [ -z "$GAMING_IP4" ]; then
		_pf_hs_stop
		return 0
	fi
	[ -n "$PF_HS_PID" ] && [ "$PF_HS_SRC" = "$GAMING_IP4" ] \
		&& kill -0 "$PF_HS_PID" 2>/dev/null && return 0
	local _n="${now:-$(date +%s)}"
	# A listener dead within 10 s of starting (no conntrack events) is tried
	# again once a minute, not every tick.
	if [ -n "$PF_HS_PID" ] && [ "$PF_HS_SRC" = "$GAMING_IP4" ] \
	   && [ $((_n - ${PF_HS_T:-0})) -lt 10 ] 2>/dev/null; then
		PF_HS_NEXT=$((_n + 60))
		_pf_warn_once hsdead "ping filter: handshake listener (conntrack -E) exits at once - retried once a minute"
	fi
	_pf_hs_stop
	[ "$_n" -lt "${PF_HS_NEXT:-0}" ] 2>/dev/null && return 0
	rm -f "$PF_RUN_DIR"/hs-* 2>/dev/null
	( _pf_title pf-handshake; pf_hs_listen ) </dev/null >/dev/null 2>&1 &
	PF_HS_PID=$!; PF_HS_SRC=$GAMING_IP4; PF_HS_T=$_n
}

# --- server owner -------------------------------------------------------------
# A location lookup's network owner ($2): a game company's own network
# names its servers (PF_OWNER_TSV). Hosting companies name no game.
# OpenWrt's BusyBox tr has no [:upper:] classes: ranges only.
_pf_owner_put() {
	local _l _lk tmp="$PF_OWNER_TSV.$$"
	case "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" in
		*riot\ games*) _l="Riot Games" ;;
		*valve*) _l="Valve" ;;
		*blizzard*) _l="Blizzard" ;;
		*ubisoft*) _l="Ubisoft" ;;
		*demonware*) _l="Call of Duty" ;;
		*activision*) _l="Activision" ;;
		*electronic\ arts*) _l="EA" ;;
		*epic\ games*) _l="Epic Games" ;;
		*bungie*) _l="Destiny 2" ;;
		*rockstar*) _l="Rockstar Games" ;;
		*nintendo*) _l="Nintendo" ;;
		*roblox*) _l="Roblox" ;;
		*) return 0 ;;
	esac
	_pf_side_lock
	{ [ -f "$PF_OWNER_TSV" ] && awk -F'\t' -v ip="$1" '$1 != ip' "$PF_OWNER_TSV"; printf '%s\t%s\n' "$1" "$_l"; } \
		> "$tmp" 2>/dev/null && mv "$tmp" "$PF_OWNER_TSV" 2>/dev/null
	rm -f "$tmp" 2>/dev/null
	_pf_side_unlock
}

# Fold handshake readings into rows and kernel sets (_pf_reading; pins keep
# their verdict and take the value). Runs from pf_scan_once (reads its $now).
_pf_hs_ingest() {
	[ "${PF_HS_RTT:-0}" = "1" ] || return 0
	local f ip ms n ex _w
	for f in "$PF_RUN_DIR"/hs-*; do
		[ -f "$f" ] || continue
		ip=${f##*/hs-}
		ms=""; n=""
		read -r ms n < "$f" 2>/dev/null
		case "$ms" in ''|*[!0-9]*) continue ;; esac
		ex=$(pf_cache_get "$ip")
		if [ -z "$ex" ]; then
			# No row yet: folded in by the pass that creates it. Unclaimed =
			# dropped.
			[ "$((now - $(date -r "$f" +%s 2>/dev/null || echo "$now")))" -gt 60 ] 2>/dev/null \
				&& rm -f "$f" 2>/dev/null
			continue
		fi
		rm -f "$f" 2>/dev/null
		if _pf_reading "$ip" "$ms" real "${n:-1}" 1; then
			pf_note "INFO" "ping filter: handshake RTT ${ms}ms for $ip ($_V, ${n:-1} connect(s))"
		elif ! _pf_src_measured "$PF_C_SRC"; then
			_pf_lim
			_w="far over its estimate (${PF_C_PING}ms)"
			[ "$_LIM" -gt 0 ] && _w="over the limit, its estimate (${PF_C_PING}ms) under it"
			pf_note "INFO" "ping filter: handshake RTT ${ms}ms for $ip not used yet - one connect $_w; a second connect confirms it"
		fi
	done
}

# --- /24 memory -------------------------------------------------------------
# Game servers live in datacentre blocks: once one IP in a /24 is MEASURED,
# the next one seen there is graded on it at first sight. A prefix reading is
# an ESTIMATE: never satisfies Ping Catch, is re-probed. Only readings a row
# took (_pf_fold) teach it. bound_km = physics upper bound (RTT ms x 100 km),
# tightest.
_pf_prefix_learn() {  # ip rtt lat lon country city
	[ "${PF_PREFIX_TTL:-0}" -gt 0 ] 2>/dev/null || return 0
	case "$1" in *:*|'') return 0 ;; esac
	pf_valid_ip4 "$1" || return 0
	# A sub-2 ms "reply" from a WAN server is more likely a middlebox
	# answering echo than physics: it teaches nothing.
	[ "$2" -ge 2 ] 2>/dev/null || return 0
	local la="$3" lo="$4" co="$5" ci="$6" tmp="$PF_PREFIX_TSV.$$" _lk
	_pf_geo_known "$la" "$lo" || { la=""; lo=""; co=""; ci=""; }
	_PF_IRM=""
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	[ -f "$PF_PREFIX_TSV" ] || : > "$PF_PREFIX_TSV"
	_pf_side_lock
	awk -F'\t' -v OFS='\t' -v p="${1%.*}" -v r="$2" -v la="$la" -v lo="$lo" \
	    -v co="$co" -v ci="$ci" -v now="${PF_NOW:-$(date +%s)}" '
		BEGIN { rb = r * 100 }
		$1 == p { f = 1; n = $2 + 1; if (n > 50) n = 50
			e = int($3 * 0.7 + r * 0.3 + 0.5); if (e < 1) e = 1
			b = $4 + 0; if (rb > 0 && (b <= 0 || rb < b)) b = rb
			if (la == "") { la = $5; lo = $6; co = $7; ci = $8 }
			print p, n, e, b, la, lo, co, ci, now; next }
		{ print }
		END { if (!f) print p, 1, r, rb, la, lo, co, ci, now }
	' "$PF_PREFIX_TSV" > "$tmp" 2>/dev/null && mv "$tmp" "$PF_PREFIX_TSV" 2>/dev/null
	rm -f "$tmp" 2>/dev/null
	_pf_side_unlock
}
# Sets PF_P_RTT/LAT/LON/CO/CI; 1 = unknown / stale. (The bound is read by
# _pf_in_radius.)
_pf_prefix_get() {
	PF_P_RTT=0; PF_P_LAT=""; PF_P_LON=""; PF_P_CO=""; PF_P_CI=""
	[ "${PF_PREFIX_TTL:-0}" -gt 0 ] 2>/dev/null || return 1
	case "$1" in *:*|'') return 1 ;; esac
	[ -s "$PF_PREFIX_TSV" ] || return 1
	local row
	row=$(awk -F'\t' -v p="${1%.*}" -v now="${PF_NOW:-$(date +%s)}" -v ttl="$PF_PREFIX_TTL" \
		'$1 == p && (now - $9) < ttl { print; exit }' "$PF_PREFIX_TSV" 2>/dev/null)
	[ -n "$row" ] || return 1
	local _o=$IFS; IFS=$PF_US; set -f; set -- $(_pf_us "$row"); set +f; IFS=$_o
	PF_P_RTT=$3; PF_P_LAT=$5; PF_P_LON=$6; PF_P_CO=$7; PF_P_CI=$8
	return 0
}
# A forgotten server's /24 row goes when no other measured server is left in
# that /24 (it may be the only one that taught it).
_pf_prefix_forget() {
	[ -s "$PF_PREFIX_TSV" ] || return 0
	case "$1" in *:*|'') return 0 ;; esac
	[ -s "$PF_SERVERS_TSV" ] && awk -F'\t' -v p="${1%.*}." \
		'index($1, p) == 1 && ($4 == "icmp" || $4 == "real") { f = 1; exit } END { exit !f }' \
		"$PF_SERVERS_TSV" 2>/dev/null && return 0
	local tmp="$PF_PREFIX_TSV.f.$$" _lk
	_PF_IRM=""
	_pf_side_lock
	awk -F'\t' -v p="${1%.*}" '$1 != p { print }' "$PF_PREFIX_TSV" > "$tmp" 2>/dev/null \
		&& mv "$tmp" "$PF_PREFIX_TSV" 2>/dev/null
	rm -f "$tmp" 2>/dev/null
	_pf_side_unlock
}
# Give a /24 row learned before its location resolved that location, so the
# next server in the block skips the lookup. Rows with one are left alone.
_pf_prefix_geo() {
	[ -s "$PF_PREFIX_TSV" ] || return 0
	case "$1" in *:*|'') return 0 ;; esac
	awk -F'\t' -v p="${1%.*}" '$1 == p && $5 == "" { f = 1; exit } END { exit !f }' \
		"$PF_PREFIX_TSV" 2>/dev/null || return 0
	local tmp="$PF_PREFIX_TSV.g.$$" _lk
	_pf_side_lock
	awk -F'\t' -v OFS='\t' -v p="${1%.*}" -v la="$2" -v lo="$3" -v co="$4" -v ci="$5" '
		$1 == p && $5 == "" { $5 = la; $6 = lo; $7 = co; $8 = ci }
		{ print }
	' "$PF_PREFIX_TSV" > "$tmp" 2>/dev/null && mv "$tmp" "$PF_PREFIX_TSV" 2>/dev/null
	rm -f "$tmp" 2>/dev/null
	_pf_side_unlock
}
# Median of awk array a[1..n] (sorts it). Spliced into awk programs.
PF_MED_AWK='
function med(a, n,   i, j, t) {
	for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
	return (n % 2) ? a[(n + 1) / 2] : int((a[n / 2] + a[n / 2 + 1]) / 2 + 0.5)
}'
# The LOWEST figure of the MEASURED servers in $1's /24 (each an upper bound
# on the block's distance), 2 ms or more (a middlebox answers faster). 0 =
# none.
_pf_p24_low() {
	case "$1" in *:*|'') echo 0; return ;; esac
	[ -s "$PF_SERVERS_TSV" ] || { echo 0; return; }
	awk -F'\t' -v ip="$1" -v p="${1%.*}." '
		index($1, p) == 1 && $1 != ip && ($4 == "icmp" || $4 == "real") && $3 + 0 >= 2 \
		    && (!lo || $3 + 0 < lo) { lo = $3 + 0 }
		END { print lo + 0 }
	' "$PF_SERVERS_TSV" 2>/dev/null || echo 0
}
# The best UNMEASURED figure into PF_E_MS / PF_E_SRC, in ms whenever one can
# be had: measured servers in the same /24 > its /24 memory > the area >
# the distance model (last resort) > -1 pending.
_pf_estimate() {
	PF_E_MS=-1; PF_E_SRC=pending
	local _e
	_e=$(_pf_p24_low "$1")
	if [ "$_e" -gt 0 ] 2>/dev/null; then
		PF_E_MS=$_e; PF_E_SRC=prefix; return 0
	fi
	if _pf_prefix_get "$1" && [ "$PF_P_RTT" -gt 0 ] 2>/dev/null; then
		PF_E_MS=$PF_P_RTT; PF_E_SRC=prefix; return 0
	fi
	_e=$(_pf_geo_est "$2" "$3")
	[ "${_e%% *}" -gt 0 ] 2>/dev/null && { PF_E_MS=${_e%% *}; PF_E_SRC=${_e#* }; }
	return 0
}

# "ms area" | "ms distance" | "-1 pending", from MEASURED readings that carry
# a location:
#  area     -- area_min or more measured servers within area_km: their
#              MEDIAN ping (of the ICMP readings when area_min of them are
#              ICMP; handshake RTT reads high), lowered area_adjust_pct
#              percent. Fewer: the nearest measured /24 within area_km.
#  distance -- dist_base_ms + km*dist_slope_us, scaled by this link's mean
#              measured/model ratio over known blocks, each weighted by
#              1 / (1 + (km/1000)^2), with a 0.25-weight prior at 1.0.
#              Clamped 0.5-3x, never under the fibre floor (1 ms / 100 km).
# $3 = km: the distance model alone for that many km from home (the radius
# in ms, _pf_classify), blocks weighted by their distance from home.
_pf_geo_est() {
	if [ -z "$PF_HOME_LAT" ] || [ -z "$PF_HOME_LON" ] || ! _pf_geo_known "$1" "$2"; then
		echo "-1 pending"; return
	fi
	local _f=/dev/null _s=/dev/null
	[ "${PF_PREFIX_TTL:-0}" -gt 0 ] 2>/dev/null && [ -s "$PF_PREFIX_TSV" ] && _f=$PF_PREFIX_TSV
	[ -z "$3" ] && [ "${PF_AREA_MIN:-0}" -gt 0 ] 2>/dev/null && [ -s "$PF_SERVERS_TSV" ] && _s=$PF_SERVERS_TSV
	awk -F'\t' -v la="$1" -v lo="$2" -v hla="$PF_HOME_LAT" -v hlo="$PF_HOME_LON" -v km="$3" \
	    -v b="${PF_DIST_BASE_MS:-10}" -v sl="${PF_DIST_SLOPE_US:-18}" -v ak="${PF_AREA_KM:-150}" \
	    -v am="${PF_AREA_MIN:-0}" -v adj="${PF_AREA_ADJ:-0}" -v sf="$_s" \
	    -v now="${PF_NOW:-$(date +%s)}" -v ttl="${PF_PREFIX_TTL:-0}" "$PF_HAV_AWK$PF_MED_AWK"'
		function model(k) { return b + k * sl / 1000 }
		BEGIN { d = (km != "") ? km + 0 : hav(hla, hlo, la, lo); if (km != "") ak = 0
			sw = 0.25; sr = 0.25; best = -1; an = 0; ni = 0 }
		FILENAME == sf {
			if (ak + 0 > 0 && $3 + 0 > 0 && ($4 == "icmp" || $4 == "real") && ($5 + 0 != 0 || $6 + 0 != 0) \
			    && hav(la, lo, $5, $6) <= ak + 0) { A[++an] = $3 + 0; if ($4 == "icmp") I[++ni] = $3 + 0 }
			next
		}
		NF >= 9 && $3 + 0 > 0 && ($5 + 0 != 0 || $6 + 0 != 0) && (now - $9) < ttl + 0 {
			g = hav(la, lo, $5, $6)
			if (ak + 0 > 0 && g <= ak + 0 && (best < 0 || g < best)) { best = g; arr = $3 + 0 }
			w = 1 / (1 + (g / 1000) ^ 2)
			m = model(hav(hla, hlo, $5, $6)); if (m < 1) m = 1
			sr += w * ($3 / m); sw += w
		}
		END {
			if (am + 0 > 0 && an >= am + 0) {
				v = (ni >= am + 0) ? med(I, ni) : med(A, an)
				v = int(v * (100 - adj) / 100 + 0.5); if (v < 1) v = 1
				printf "%d area\n", v; exit
			}
			if (best >= 0) { printf "%d area\n", arr; exit }
			f = sr / sw; if (f < 0.5) f = 0.5; if (f > 3) f = 3
			v = model(d) * f; if (v < d / 100) v = d / 100; if (v < 1) v = 1
			printf "%d distance\n", int(v + 0.5)
		}' "$_s" "$_f" 2>/dev/null || echo "-1 pending"
}

# Ping Catch group verdict into _AV, counted from the READINGS of the
# measured graded servers (pins aside) in $1's /24, and once it is located
# ($2 $3) within area_km of it: u = an own figure at or under the catch; o =
# a handshake over it on 2+ connects (confirmed over, col 12), or a country
# outside allow_country. Over the catch on ICMP alone counts on neither side
# (an echo the provider slows). Allowed: u > o, and u >= 1 in the same /24
# or u >= auto_pin in all. Blocked: o >= auto_pin and u = 0. Else "". Off
# with auto_pin 0.
_pf_area_verdict() {
	_AV=""
	[ "${PF_PING_CATCH:-0}" -gt 0 ] 2>/dev/null && [ "${PF_AUTO_PIN:-0}" -gt 0 ] 2>/dev/null \
		&& [ -s "$PF_SERVERS_TSV" ] || return 0
	case "$1" in *:*|'') return 0 ;; esac
	local la="$2" lo="$3" _LIM
	_pf_geo_known "$la" "$lo" || { la=""; lo=""; }
	_pf_lim
	_AV=$(awk -F'\t' -v ip="$1" -v p="${1%.*}." -v la="$la" -v lo="$lo" -v ak="${PF_AREA_KM:-150}" \
	    -v m="$PF_AUTO_PIN" -v cl="|$PF_COUNTRIES|" -v lim="$_LIM" "$PF_HAV_AWK"'
		$1 != ip && ($2 == "allowed" || $2 == "blocked") && ($4 == "icmp" || $4 == "real") && $3 + 0 > 0 {
			s = (index($1, p) == 1)
			if (!s && (la == "" || ($5 + 0 == 0 && $6 + 0 == 0) || hav(la, lo, $5, $6) > ak + 0)) next
			if (cl != "||" && $7 != "" && !index(cl, "|" $7 "|")) o++
			else if ($3 + 0 <= lim + 0) { u++; us += s }
			else if ($4 == "real" && $12 + 0 >= 2) o++
		}
		END { if (u > o && (us >= 1 || u >= m)) print "allowed"; else if (o >= m && !u) print "blocked" }' \
		"$PF_SERVERS_TSV" 2>/dev/null)
	return 0
}

# --- the Ping Filter's own nft table -----------------------------------------
#   @pf_gaming_src    the monitored devices
#   @pf_seen          every public UDP server they talk to (discovery)
#   @ping_allowed     the verdicts; every element has its own timeout
#   @ping_blocked
#   @wl_net / @bl_net whitelist / blacklist prefixes
#   chain seen        forward, priority -145: fills @pf_seen
#   chain enforce     forward, priority filter - 5: ahead of fw4's
#                     established-accept, so a block lands on a live flow.
#                     Drops UDP both directions regardless of ct state;
#                     other traffic to a blocked address (TCP logins, store,
#                     web on a shared cloud address) passes.
# fw4 never touches a foreign table: a firewall reload loses nothing, and PF
# writes nothing to /etc/config/firewall. First-packet drops keep new flows
# out of flow offload; flows up before the verdict need pf_ct_kill.
PF_FW_TABLE="inet qos_ex_pf"
PF_SET_NAME="ping_blocked"
PF_ALLOWED_SET_NAME="ping_allowed"
PF_SEEN_SET_NAME="pf_seen"
PF_GAMING_SET_NAME="pf_gaming_src"
PF_SEEN_TIMEOUT="600"
# IPv6 objects exist only when a monitored IPv6 device does.
PF_SET_NAME6="ping_blocked6"
PF_ALLOWED_SET_NAME6="ping_allowed6"
PF_SEEN_SET_NAME6="pf_seen6"
PF_GAMING_SET_NAME6="pf_gaming_src6"
# Non-public IPv4 destinations: never discovered, never held.
PF_PRIV4="{ 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 }"

pf_fw_reload() {
	if command -v fw4 >/dev/null 2>&1; then
		fw4 reload >/dev/null 2>&1
	elif [ -x /etc/init.d/firewall ]; then
		/etc/init.d/firewall reload >/dev/null 2>&1
	fi
}
# Process titles, so the process list says what each PF process is (workers
# are subshells and would show the daemon's command line).
#   _pf_title NAME      the calling shell's comm (15 chars max; shown by ps /
#                       top / LuCI). A builtin write, so /proc/self is this
#                       shell. Names start "pf-": _pf_proc_table reads comm.
#                       printf: the kernel keeps a newline.
#   _pf_exec_as NAME C  exec C with argv[0] NAME (exec -a). Real binaries
#                       only (an applet is picked by argv[0]); C by full path
#                       (BusyBox 1.36 ash searches PATH for NAME).
_pf_title() {
	{ printf '%s' "$1" > /proc/self/comm; } 2>/dev/null
	return 0
}
_pf_exec_as() {
	local _a="$1" _c
	shift
	_c=$(command -v "$1" 2>/dev/null)
	case "$_c" in
	/*)	if ( exec -a true true ) 2>/dev/null; then
			shift
			exec -a "$_a" "$_c" "$@"
		fi ;;
	esac
	exec "$@"
}
_pf_run_with_timeout() {
	if command -v timeout >/dev/null 2>&1; then
		timeout "$@"
		return
	fi
	local _t="$1" _p _w _rc
	shift
	"$@" &
	_p=$!
	# The watchdog takes its sleep with it, or the sleep runs on orphaned.
	( _pf_title pf-watchdog; trap 'kill "$_s" 2>/dev/null; exit 0' TERM
	  sleep "$_t" & _s=$!
	  wait "$_s" && kill "$_p" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
	_w=$!
	# The shell reports a killed job on stderr (the daemon log).
	wait "$_p" 2>/dev/null; _rc=$?
	kill "$_w" 2>/dev/null
	return "$_rc"
}
# Left by older versions: a mirror table, a fw4 include, UCI ipset / rule
# sections. One firewall reload, only when something was there.
PF_SEEN_INCLUDE="/etc/nftables.d/35-qos-ex-pf-seen.nft"
_pf_legacy_cleanup() {
	local n removed=0
	# Once per boot: nothing recreates them.
	[ -f "$PF_RUN_DIR/.legacy-done" ] && return 0
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	: > "$PF_RUN_DIR/.legacy-done"
	nft delete table inet qos_ex_pf_enf 2>/dev/null
	for n in pingfilter_block_rule pingfilter_allow_rule ping_blocked ping_allowed \
		pingfilter_block_rule6 pingfilter_allow_rule6 ping_blocked6 ping_allowed6 \
		pingfilter_set pingfilter_blocked pingfilter_allowed pingfilter_rule; do
		uci -q get "firewall.$n" >/dev/null 2>&1 || continue
		uci -q delete "firewall.$n" 2>/dev/null && removed=1
	done
	[ -f "$PF_SEEN_INCLUDE" ] && { rm -f "$PF_SEEN_INCLUDE" 2>/dev/null; removed=1; }
	[ "$removed" = 1 ] || return 0
	uci -q commit firewall
	pf_fw_reload
	msg "ping filter: old firewall sections removed (rules now live in table $PF_FW_TABLE)"
}

# Flow offloading on (software or hardware): established flows skip the
# forward hook, and with it discovery, the activity counters and liveness.
_pf_offload_on() {
	[ "$(uci -q get firewall.@defaults[0].flow_offloading)" = 1 ] \
		|| [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 1 ]
}

# The UDP dports PF watches: 1024 and up, less the ignore list.
_pf_port_match() {
	_PM="udp dport ${PF_UDP_PORT_MIN:-1024}-${PF_UDP_PORT_MAX:-65535}"
	[ -n "$PF_IGNORE_NFT" ] && _PM="$_PM udp dport != { $PF_IGNORE_NFT }"
	return 0
}

# The new-server hold, by mode, into _HOLD (1 = none):
#   full   game UDP to a server with no verdict is dropped: pure distance
#          (held until located), and any mode with a country list;
#   first  the first first_pkts packets of each flow pass, so conntrack
#          times the game's handshake, the rest wait until graded: a ping
#          limit, or distance + Ping Catch. first_pkts 0 = no hold (a new
#          server is allowed until graded);
#   none   watch only (ping limit 0) without a country list.
_pf_hold_on() {
	_HOLD=""
	if { [ "${PF_BLOCK_MODE:-ping}" = "distance" ] && ! [ "${PF_PING_CATCH:-0}" -gt 0 ] 2>/dev/null; } \
	   || [ -n "$PF_COUNTRIES" ]; then
		_HOLD=full
	elif { [ "${PF_BLOCK_MODE:-ping}" = "distance" ] || [ "${PF_THRESHOLD_MS:-0}" -gt 0 ] 2>/dev/null; } \
	   && [ "${PF_FIRST_PKTS:-2}" -gt 0 ] 2>/dev/null; then
		_HOLD=first
	fi
	[ -n "$_HOLD" ]
}
# The table as text. v6 objects only when a v6 device is monitored (a v6-less
# kernel would fail the whole file).
_pf_table_body() {
	local _PM _HOLD _pk="" v6=0 g=$PF_GAMING_SET_NAME a=$PF_ALLOWED_SET_NAME b=$PF_SET_NAME
	_pf_port_match
	[ -n "$GAMING_IP6" ] && v6=1
	echo "table $PF_FW_TABLE {"
	echo "	set $g { type ipv4_addr; }"
	echo "	set $PF_SEEN_SET_NAME { type ipv4_addr; flags dynamic,timeout; timeout ${PF_SEEN_TIMEOUT}s; size 65535; }"
	echo "	set $a { type ipv4_addr; flags timeout; }"
	echo "	set $b { type ipv4_addr; flags timeout; }"
	echo "	set wl_net { type ipv4_addr; flags interval; auto-merge; }"
	echo "	set bl_net { type ipv4_addr; flags interval; auto-merge; }"
	echo "	set auto_ok { type ipv4_addr; flags interval; }"
	echo "	set auto_bad { type ipv4_addr; flags interval; }"
	# Packets to and from the devices (all, and game-port UDP) for the
	# activity gate: one nft call reads both.
	echo "	counter pf_all { }"
	echo "	counter pf_udp { }"
	if [ "$v6" = 1 ]; then
		echo "	set $PF_GAMING_SET_NAME6 { type ipv6_addr; }"
		echo "	set $PF_SEEN_SET_NAME6 { type ipv6_addr; flags dynamic,timeout; timeout ${PF_SEEN_TIMEOUT}s; size 65535; }"
		echo "	set $PF_ALLOWED_SET_NAME6 { type ipv6_addr; flags timeout; }"
		echo "	set $PF_SET_NAME6 { type ipv6_addr; flags timeout; }"
	fi
	echo "	chain seen {"
	echo "		type filter hook forward priority -145; policy accept;"
	# Gate: the hook sees every forwarded packet; one with no gaming device
	# at either end leaves on one rule instead of failing a set lookup in
	# each. No IPv6 devices = no IPv6 rules: one compare for IPv6.
	[ "$v6" = 1 ] || echo "		meta nfproto ipv6 return"
	echo "		ip saddr != @$g ip daddr != @$g return"
	[ "$v6" = 1 ] && \
	echo "		ip6 saddr != @$PF_GAMING_SET_NAME6 ip6 daddr != @$PF_GAMING_SET_NAME6 return"
	echo "		ip saddr @$g counter name pf_all"
	echo "		ip daddr @$g counter name pf_all"
	echo "		ip saddr @$g udp dport >= ${PF_UDP_PORT_MIN:-1024} counter name pf_udp"
	echo "		ip daddr @$g udp sport >= ${PF_UDP_PORT_MIN:-1024} counter name pf_udp"
	if [ "$v6" = 1 ]; then
		echo "		ip6 saddr @$PF_GAMING_SET_NAME6 counter name pf_all"
		echo "		ip6 daddr @$PF_GAMING_SET_NAME6 counter name pf_all"
		echo "		ip6 saddr @$PF_GAMING_SET_NAME6 udp dport >= ${PF_UDP_PORT_MIN:-1024} counter name pf_udp"
		echo "		ip6 daddr @$PF_GAMING_SET_NAME6 udp sport >= ${PF_UDP_PORT_MIN:-1024} counter name pf_udp"
	fi
	echo "		meta l4proto udp ip saddr @$g $_PM ip daddr != $PF_PRIV4 update @$PF_SEEN_SET_NAME { ip daddr }"
	[ "$v6" = 1 ] && \
	echo "		meta l4proto udp ip6 saddr @$PF_GAMING_SET_NAME6 $_PM ip6 daddr != { ::1, ::/128, fe80::/10, fc00::/7, ff00::/8 } update @$PF_SEEN_SET_NAME6 { ip6 daddr }"
	echo "	}"
	echo "	chain enforce {"
	echo "		type filter hook forward priority filter - 5; policy accept;"
	# Gate: only UDP is ever dropped here, so every other protocol passes
	# on one rule, and a packet with no gaming device at either end on the
	# next; the verdict rules run for game traffic only.
	echo "		meta l4proto != udp return"
	[ "$v6" = 1 ] || echo "		meta nfproto ipv6 return"
	echo "		ip saddr != @$g ip daddr != @$g return"
	[ "$v6" = 1 ] && \
	echo "		ip6 saddr != @$PF_GAMING_SET_NAME6 ip6 daddr != @$PF_GAMING_SET_NAME6 return"
	# Host verdicts first, then the listed prefixes (the scan gives a server
	# inside one its own host entry; prefixes meet the first packet).
	echo "		ip saddr @$g ip daddr @$a return"
	echo "		ip saddr @$a ip daddr @$g return"
	echo "		ip saddr @$g ip daddr @$b meta l4proto udp counter drop"
	echo "		ip saddr @$b ip daddr @$g meta l4proto udp counter drop"
	echo "		ip saddr @$g ip daddr @wl_net return"
	echo "		ip saddr @wl_net ip daddr @$g return"
	echo "		ip saddr @$g ip daddr @bl_net meta l4proto udp counter drop"
	echo "		ip saddr @bl_net ip daddr @$g meta l4proto udp counter drop"
	# Ping Catch /24s (_pf_auto_nets): after the hosts and the lists, so a
	# server's own verdict and the manual lists come first.
	echo "		ip saddr @$g ip daddr @auto_ok return"
	echo "		ip saddr @auto_ok ip daddr @$g return"
	echo "		ip saddr @$g ip daddr @auto_bad meta l4proto udp counter drop"
	echo "		ip saddr @auto_bad ip daddr @$g meta l4proto udp counter drop"
	if [ "$v6" = 1 ]; then
		echo "		ip6 saddr @$PF_GAMING_SET_NAME6 ip6 daddr @$PF_ALLOWED_SET_NAME6 return"
		echo "		ip6 saddr @$PF_ALLOWED_SET_NAME6 ip6 daddr @$PF_GAMING_SET_NAME6 return"
		echo "		ip6 saddr @$PF_GAMING_SET_NAME6 ip6 daddr @$PF_SET_NAME6 meta l4proto udp counter drop"
		echo "		ip6 saddr @$PF_SET_NAME6 ip6 daddr @$PF_GAMING_SET_NAME6 meta l4proto udp counter drop"
	fi
	# Hold: a game-port UDP packet to a public address with no verdict stops
	# here; "first" only past the flow's first first_pkts packets (conntrack
	# accounting, which the daemon turns on: without it the count reads 0
	# and nothing is held). Outbound only; IPv4 only (IPv6 servers are not
	# graded).
	if _pf_hold_on; then
		[ "$_HOLD" = first ] && _pk=" ct original packets > ${PF_FIRST_PKTS:-2}"
		echo "		ip saddr @$g meta l4proto udp $_PM ip daddr != $PF_PRIV4$_pk counter drop comment \"pf-hold\""
	fi
	echo "	}"
	# Allow / block / hold rules only. Never a `ct mark` write: only the
	# shaper's LAN->WAN egress path touches the connmark.
	echo "}"
	# The listed prefixes, replaced whole in the same transaction.
	echo "flush set $PF_FW_TABLE wl_net"
	echo "flush set $PF_FW_TABLE bl_net"
	[ -n "$PF_WL_NETS" ] && echo "add element $PF_FW_TABLE wl_net { $(echo $PF_WL_NETS | sed 's/ /, /g') }"
	[ -n "$PF_BL_NETS" ] && echo "add element $PF_FW_TABLE bl_net { $(echo $PF_BL_NETS | sed 's/ /, /g') }"
	return 0
}

pf_table_present() { nft list table $PF_FW_TABLE >/dev/null 2>&1; }

# In place when the table exists: flush + refill the chains and re-declare the
# sets (a no-op for existing ones), so verdicts and @pf_seen keep their
# members and a reload never opens a gap under hold. Full rebuild only when
# the table is new or the in-place transaction is refused; pf_reclassify then
# refills the verdict sets.
pf_table_install() {
	local tmp="$PF_RUN_DIR/.tbl.$$"
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	if pf_table_present; then
		{ echo "flush chain $PF_FW_TABLE seen"; echo "flush chain $PF_FW_TABLE enforce"; _pf_table_body; } > "$tmp"
		if nft -f "$tmp" 2>"$PF_NFT_ERR"; then
			rm -f "$tmp" "$PF_NFT_ERR" 2>/dev/null
			pf_seed_gaming_set
			return 0
		fi
	fi
	PF_PUTS=""; _pf_setgen_bump
	# New, empty auto /24 sets: the next pass fills them again.
	rm -f "$PF_RUN_DIR/.auto24" 2>/dev/null
	{ echo "table $PF_FW_TABLE"; echo "delete table $PF_FW_TABLE"; _pf_table_body; } > "$tmp"
	if ! nft -f "$tmp" 2>"$PF_NFT_ERR"; then
		{ echo ""; echo "=== ruleset ==="; cat "$tmp"; } >> "$PF_NFT_ERR" 2>/dev/null
		rm -f "$tmp" 2>/dev/null
		err "ping filter: nft table install FAILED — see $PF_NFT_ERR"
		return 1
	fi
	rm -f "$tmp" "$PF_NFT_ERR" 2>/dev/null
	pf_seed_gaming_set
	_pf_keep_played
	return 0
}
# A server still being played goes back into @ping_allowed as soon as a new
# table is in: its sets are empty, so the hold would drop the server's
# packets for the whole re-grade that fills them (pf_reclassify after a
# start, pf_sets_self_heal after the daemon put a deleted table back). Not a
# blacklisted one.
_pf_keep_played() {
	local f
	for f in "$PF_RUN_DIR"/.play-*; do
		[ -f "$f" ] || continue
		f=${f##*/.play-}
		case "$f" in *:*) continue ;; esac
		_pf_list_state "$f"
		[ "$_LS" = blacklist ] || ! _pf_in_session "$f" || pf_allow_add "$f" 2
	done
	return 0
}

# (Re)seed a source set with the monitored devices: compare kernel members
# with the config and rewrite atomically on drift.
_pf_seed_set() {
	local set="$1" vfn="$2" ips="$3" want have ip
	nft list set $PF_FW_TABLE "$set" >/dev/null 2>&1 || return 0
	want=$(for ip in $ips; do [ -z "$ip" ] && continue; "$vfn" "$ip" || continue; echo "$ip"; done | sort -u)
	have=$(_pf_set_dump "$set" | awk -F'\t' '{print $1}' | sort -u)
	[ "$want" = "$have" ] && { _pf_warn_clear "seed-$set"; return 0; }
	local script="$PF_RUN_DIR/.gseed.$$"
	{ echo "flush set $PF_FW_TABLE $set"
	  for ip in $want; do echo "add element $PF_FW_TABLE $set { $ip }"; done; } > "$script"
	if nft -f "$script" 2>/dev/null; then
		rm -f "$script" 2>/dev/null
		msg "ping filter: seeded @$set with $(echo "$want" | grep -c .) gaming IP(s)"
		_pf_warn_clear "seed-$set"
		return 0
	fi
	rm -f "$script" 2>/dev/null
	# An empty @$set blinds discovery for every device: say so.
	_pf_warn_once "seed-$set" "ping filter: nft refused to seed @$set ($(echo $want)) — discovery sees no gaming source"
	return 1
}
pf_seed_gaming_set() {
	_pf_seed_set "$PF_GAMING_SET_NAME"  pf_valid_ip4 "$GAMING_IP4"
	_pf_seed_set "$PF_GAMING_SET_NAME6" pf_valid_ip6 "$GAMING_IP6"
	return 0
}

# @pf_seen as "ip<TAB>age-seconds" (age = set timeout - remaining expiry).
pf_seen_dump() { _pf_set_dump "$PF_SEEN_SET_NAME" age "${PF_SEEN_TIMEOUT:-600}"; }

# Every gaming device entry (Setup -> Devices & Ports) with its PF-monitoring
# state.
pf_devices_list() {
	local _e _s _m
	printf '# entry\tfamily\tmonitored\n'
	for _e in $GAMING_IP4_ALL; do
		_m=0
		for _s in $PF_DEVICES; do [ "$_s" = "$_e" ] && { _m=1; break; }; done
		printf '%s\tv4\t%s\n' "$_e" "$_m"
	done
	for _e in $GAMING_IP6_ALL; do
		_m=0
		for _s in $PF_DEVICES; do [ "$_s" = "$_e" ] && { _m=1; break; }; done
		printf '%s\tv6\t%s\n' "$_e" "$_m"
	done
	for _e in $GAMING_MAC; do
		_m=0
		case " $PF_MAC_SEL " in *" $_e "*) _m=1 ;; esac
		printf '%s\tmac\t%s\n' "$_e" "$_m"
	done
	for _s in $PF_DEVICES; do
		_m=0
		for _e in $GAMING_IP4_ALL $GAMING_IP6_ALL $PF_MAC_SEL; do
			[ "$_e" = "$_s" ] && { _m=1; break; }
		done
		[ "$_m" = "0" ] && printf '%s\tstale\t0\n' "$_s"
	done
	return 0
}
# Cut the live UDP flows between the monitored devices and a newly blocked
# server: enforce stops new packets, this removes the conntrack entry (and any
# offloaded path). TCP and other LAN hosts keep their flows.
pf_ct_kill() {
	local ip="$1" fam="" dev devs
	[ -z "$ip" ] && return 0
	if ! command -v conntrack >/dev/null 2>&1; then
		_pf_warn_once noct "ping filter: conntrack tool missing — live flows are not cut on a block. Run: $(pkg_install_hint conntrack)"
		return 0
	fi
	case "$(pf_ip_family "$ip")" in
		v4) devs=$GAMING_IP4 ;;
		v6) devs=$GAMING_IP6; fam="-f ipv6" ;;
		*)  return 0 ;;
	esac
	for dev in $devs; do
		# The device opened it, or it was opened towards the device (port forward).
		conntrack -D $fam -p udp -s "$dev" -d "$ip" >/dev/null 2>&1
		conntrack -D $fam -p udp -s "$ip" -r "$dev" >/dev/null 2>&1
	done
	return 0
}

# Kernel timeout into $_t: perm 1 = pin (30 d); 2 = MEASURED allow, kept as
# long as its row (row_ttl) so a known-good server passes hold at once
# (pf_cache_age_out evicts it with the row); else set_timeout. Only allows
# get 2.
_pf_tmo() {
	case "$1" in
		1) _t=30d ;;
		2) _t="${PF_ROW_TTL:-604800}s" ;;
		*) _t="${PF_SET_TIMEOUT:-43200}s" ;;
	esac
}
_pf_emit_add() {
	local _t; _pf_tmo "$3"
	echo "add element $PF_FW_TABLE $1 { $2 timeout $_t }"
}

# Rebuild BOTH verdict sets in ONE nft transaction (one `nft -f` = one
# commit): rules never see a half-built set. Never flush and re-add as
# separate commands. A failure leaves the sets as they were.
#   $1  file of "ip<TAB>perm" lines for @ping_allowed  (perm=1 -> timeout 30d)
#   $2  file of "ip<TAB>perm" lines for @ping_blocked
pf_apply_sets_atomic() {
	local allow_f="$1" block_f="$2"
	local script="$PF_RUN_DIR/.apply.$$"
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	local ip perm have6=0
	# What was blocked before this rebuild: only a NEW block cuts a flow.
	local prev_blk="$PF_RUN_DIR/.prevblk.$$"
	pf_block_ips 2>/dev/null > "$prev_blk" || : > "$prev_blk"
	nft list set $PF_FW_TABLE $PF_SET_NAME6 >/dev/null 2>&1 && have6=1
	{
		echo "flush set $PF_FW_TABLE $PF_ALLOWED_SET_NAME"
		echo "flush set $PF_FW_TABLE $PF_SET_NAME"
		[ "$have6" = 1 ] && { echo "flush set $PF_FW_TABLE $PF_ALLOWED_SET_NAME6"
			 echo "flush set $PF_FW_TABLE $PF_SET_NAME6"; }
		if [ -f "$allow_f" ]; then
			while IFS='	' read -r ip perm; do
				[ -z "$ip" ] && continue
				case "$(pf_ip_family "$ip")" in
					v4) _pf_emit_add "$PF_ALLOWED_SET_NAME"  "$ip" "$perm" ;;
					v6) [ "$have6" = 1 ] && _pf_emit_add "$PF_ALLOWED_SET_NAME6" "$ip" "$perm" ;;
				esac
			done < "$allow_f"
		fi
		if [ -f "$block_f" ]; then
			while IFS='	' read -r ip perm; do
				[ -z "$ip" ] && continue
				case "$(pf_ip_family "$ip")" in
					v4) _pf_emit_add "$PF_SET_NAME"  "$ip" "$perm" ;;
					v6) [ "$have6" = 1 ] && _pf_emit_add "$PF_SET_NAME6" "$ip" "$perm" ;;
				esac
			done < "$block_f"
		fi
	} > "$script"
	if ! nft -f "$script" 2>"$PF_NFT_ERR.apply"; then
		rm -f "$script" "$prev_blk" 2>/dev/null
		err "ping filter: atomic set rebuild FAILED (sets unchanged) — see $PF_NFT_ERR.apply"
		return 1
	fi
	rm -f "$script" 2>/dev/null
	PF_PUTS=""; _pf_setgen_bump
	if [ -f "$block_f" ]; then
		while IFS='	' read -r ip perm; do
			[ -z "$ip" ] && continue
			grep -qxF "$ip" "$prev_blk" 2>/dev/null || pf_ct_kill "$ip"
		done < "$block_f"
	fi
	rm -f "$prev_blk" 2>/dev/null
	return 0
}

# Both verdict sets empty while graded rows exist (table rebuilt behind our
# back, or every entry timed out over a long idle): re-grade the cache. An
# allow with no figure yet is in neither set by design (the hold).
pf_sets_self_heal() {
	[ -s "$PF_SERVERS_TSV" ] || return 0
	local a b
	a=$(pf_allow_ips 2>/dev/null | head -1)
	b=$(pf_block_ips 2>/dev/null | head -1)
	{ [ -n "$a" ] || [ -n "$b" ]; } && return 0
	awk -F'\t' '($2=="allowed"&&$3+0>0)||$2=="blocked"||$2=="whitelist"||$2=="blacklist"{f=1;exit} END{exit f?0:1}' \
		"$PF_SERVERS_TSV" 2>/dev/null || return 0
	msg "ping filter: enforcement sets empty with cached rows present — rebuilding atomically"
	pf_reclassify
}
# Install the table; start, reload and the supervised entry come through here.
pf_install_fw_rules() {
	command -v nft >/dev/null 2>&1 || { err "ping filter: nft not found"; return 1; }
	# Only procd runs the grading daemon: a table put in without one holds
	# every new server with nothing to grade it (a Start or Enable from LuCI
	# before the service ever came up, a CLI scan).
	_pf_supervised || { err "ping filter: the QoS-Ex service is not running — rules not installed (start it with: /etc/init.d/QoS-Ex start)"; return 1; }
	if [ -z "$GAMING_IP4$GAMING_IP6$PF_MAC_SEL" ]; then
		if [ -n "$PF_DEVICES" ]; then
			err "ping filter: the Monitored-devices selection (pf_devices) matches no current gaming device — fix Ping Filter → Settings → Devices"
		elif [ -n "$GAMING_IP4_ALL$GAMING_IP6_ALL" ]; then
			err "ping filter: no device ticked in Ping Filter → Settings → Devices — Ping Filter stays OFF until at least one gaming device is selected"
		else
			err "ping filter: no gaming device configured (set one on Setup → Devices & Ports first)"
		fi
		return 1
	fi
	_pf_legacy_cleanup
	pf_table_install
}

pf_uninstall_fw_rules() {
	_pf_legacy_cleanup
	nft delete table $PF_FW_TABLE 2>/dev/null
	rm -f "$PF_RUN_DIR/.auto24" 2>/dev/null
	return 0
}

pf_verify_install() {
	local ok=1 s n ct_ok=0
	command -v conntrack >/dev/null 2>&1 && ct_ok=1
	if ! pf_table_present; then
		printf "  %-32s %s\n" "Table ($PF_FW_TABLE):" "NO"
		err "verify FAILED — try: $0 restart"
		return 1
	fi
	printf "  %-32s %s\n" "Table ($PF_FW_TABLE):" "YES"
	for s in "$PF_GAMING_SET_NAME" "$PF_SEEN_SET_NAME" "$PF_ALLOWED_SET_NAME" "$PF_SET_NAME" wl_net bl_net auto_ok auto_bad; do
		if nft list set $PF_FW_TABLE "$s" >/dev/null 2>&1; then
			n=$(_pf_set_dump "$s" | wc -l)
			printf "  %-32s %s\n" "Set @$s:" "YES ($n)"
		else
			printf "  %-32s %s\n" "Set @$s:" "NO"; ok=0
		fi
	done
	for s in seen enforce; do
		if nft list chain $PF_FW_TABLE "$s" 2>/dev/null | grep -q '@'; then
			printf "  %-32s %s\n" "Chain $s:" "YES"
		else
			printf "  %-32s %s\n" "Chain $s:" "NO"; ok=0
		fi
	done
	printf "  %-32s %s\n" "Hold rule:" "$(nft list chain $PF_FW_TABLE enforce 2>/dev/null | grep -q pf-hold && echo "on" || echo "off (watch only, or first_pkts 0)")"
	printf "  %-32s %s\n" "conntrack tool:" "$([ $ct_ok = 1 ] && echo "YES (cuts live flows on block)" || echo "NO — $(pkg_install_hint conntrack)")"
	_pf_offload_on && { printf "  %-32s %s\n" "Flow offloading:" "ON — established game flows bypass the Ping Filter; turn it off"; ok=0; }
	if [ "$ok" = 0 ]; then
		err "verify FAILED — try: $0 restart"
		return 1
	fi
	msg "verify OK — ping filter table loaded"
	return 0
}

pf_block_add() {
	local ip="$1"
	[ -z "$ip" ] && return 1
	local _bset
	case "$(pf_ip_family "$ip")" in
		v4) _bset=$PF_SET_NAME ;;
		v6) _bset=$PF_SET_NAME6 ;;
		*) return 0 ;;
	esac
	local was_blocked=0
	nft get element $PF_FW_TABLE $_bset "{ $ip }" >/dev/null 2>&1 && was_blocked=1
	_pf_set_put block "$ip" "${2:-0}"
	[ "$was_blocked" = "0" ] && pf_ct_kill "$ip"
	:
}
pf_block_del() {
	[ -z "$1" ] && return 1
	_pf_set_put none "$1" 0
}

# Put ip in ONE verdict set (or none) and out of the other, as ONE nft
# transaction, so a live server is never in neither. "add then delete" is
# the idempotent remove (nft refuses to delete an absent element).
_pf_set_put() {
	local kind="$1" ip="$2" perm="$3" a b s c="" _t
	case "$(pf_ip_family "$ip")" in
		v4) a=$PF_ALLOWED_SET_NAME; b=$PF_SET_NAME ;;
		v6) a=$PF_ALLOWED_SET_NAME6; b=$PF_SET_NAME6
		    nft list set $PF_FW_TABLE "$b" >/dev/null 2>&1 || return 0 ;;
		*) return 0 ;;
	esac
	_pf_tmo "$perm"
	# No script file: forked workers share the daemon's $$, so a ".put.$$"
	# file could change under a running nft -f.
	for s in "$a" "$b"; do
		c="${c:+$c; }add element $PF_FW_TABLE $s { $ip }; delete element $PF_FW_TABLE $s { $ip }"
	done
	case "$kind" in
		allow) c="$c; add element $PF_FW_TABLE $a { $ip timeout $_t }" ;;
		block) c="$c; add element $PF_FW_TABLE $b { $ip timeout $_t }" ;;
	esac
	nft "$c" 2>/dev/null
	case "$kind" in
		allow) _pf_put_mark "$ip" "a$perm" ;;
		block) _pf_put_mark "$ip" "b$perm" ;;
		*)     _pf_put_mark "$ip" "" ;;
	esac
	_pf_setgen_bump
	return 0
}

# --- verdict puts this process has made -------------------------------------
# PF_PUTS = "ip=key@epoch ..." (key a|b + perm: a2 measured allow, b0 graded
# block, a1/b1 pins). _pf_put_due: put again only when the verdict differs or
# the last put is a minute old (not an nft run per server per tick). Emptied
# when the sets are rebuilt or flushed here; another process that changes them
# writes .setgen, which empties it in the daemon's scan (PF_MAIN = the daemon
# and its workers, which write no .setgen).
PF_PUTS=""
PF_MAIN=""
_pf_put_mark() {   # ip key ("" = forget)
	local s=" $PF_PUTS " pre suf
	case "$s" in
		*" $1="*) pre=${s%%" $1="*}; suf=${s#*" $1="*' '}; s="$pre $suf" ;;
	esac
	[ -n "$2" ] && s="$s $1=$2@${PF_NOW:-$(date +%s)}"
	set -f
	# shellcheck disable=SC2086
	set -- $s
	set +f
	PF_PUTS="$*"
}
_pf_put_due() {    # ip key -> 0 when a put is due
	local e=" $PF_PUTS "
	case "$e" in *" $1="*) ;; *) return 0 ;; esac
	e=${e#*" $1="}; e=${e%% *}
	[ "${e%@*}" = "$2" ] || return 0
	[ $(( ${PF_NOW:-$(date +%s)} - ${e#*@} )) -ge 60 ] 2>/dev/null && return 0
	return 1
}
_pf_setgen_bump() {
	[ -n "$PF_MAIN" ] && return 0
	_PF_GN=$((${_PF_GN:-0} + 1))
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	printf '%s %s %s\n' "$$" "$(date +%s)" "$_PF_GN" > "$PF_RUN_DIR/.setgen" 2>/dev/null
	return 0
}
pf_block_flush() {
	nft flush set $PF_FW_TABLE $PF_SET_NAME 2>/dev/null
	nft flush set $PF_FW_TABLE $PF_SET_NAME6 2>/dev/null
	PF_PUTS=""; _pf_setgen_bump
}

_pf_set_dump() {
	local set="$1" mode="${2:-expiry}" tmo="${3:-600}"
	nft list set $PF_FW_TABLE "$set" 2>/dev/null \
	| awk '/elements *= *\{/, /}/ { gsub(/elements *= *\{/,""); gsub(/}/,""); gsub(/,/,"\n"); print }' \
	| awk -v mode="$mode" -v tmo="$tmo" '
		{
			gsub(/^[ \t]+/, "")
			if ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || $1 ~ /^[0-9A-Fa-f:]+$/) {
				ip = $1; secs = 0
				for (i = 2; i <= NF; i++) {
					if ($i == "expires" && (i + 1) <= NF) {
						t = $(i + 1); sub(/[0-9]+ms/, "", t)
						while (match(t, /[0-9]+[dhms]/)) {
							c = substr(t, RSTART, RLENGTH); n = c + 0
							u = substr(c, length(c), 1)
							secs += (u == "d") ? n*86400 : (u == "h") ? n*3600 : (u == "m") ? n*60 : n
							t = substr(t, RSTART + RLENGTH)
						}
					}
				}
				v = (mode == "age") ? (secs < 0 ? 0 : tmo - secs) : secs
				if (v < 0) v = 0
				print ip "\t" v
			}
		}' | sort -u
}

pf_block_dump()  { _pf_set_dump "$PF_SET_NAME"; }
pf_block_dump6() { _pf_set_dump "$PF_SET_NAME6"; }

pf_block_ips() {
	{ pf_block_dump; pf_block_dump6; } | awk -F'\t' '{print $1}'
}

pf_allow_add() {
	[ -z "$1" ] && return 1
	_pf_set_put allow "$1" "${2:-0}"
}
pf_allow_del() {
	[ -z "$1" ] && return 1
	_pf_set_put none "$1" 0
}
pf_allow_flush() {
	nft flush set $PF_FW_TABLE $PF_ALLOWED_SET_NAME 2>/dev/null
	nft flush set $PF_FW_TABLE $PF_ALLOWED_SET_NAME6 2>/dev/null
	PF_PUTS=""; _pf_setgen_bump
}

pf_allow_dump()  { _pf_set_dump "$PF_ALLOWED_SET_NAME"; }
pf_allow_dump6() { _pf_set_dump "$PF_ALLOWED_SET_NAME6"; }

pf_allow_ips() {
	{ pf_allow_dump; pf_allow_dump6; } | awk -F'\t' '{print $1}'
}

pf_runtime_flush() {
	pf_block_flush
	pf_allow_flush
}

pf_geo_cache_get() {
	local ip="$1"
	[ -z "$ip" ] && return 1
	[ -f "$PF_GEO_CACHE" ] || return 1
	awk -F'\t' -v ip="$ip" '$1==ip { lat=$2; lon=$3; co=$4; ci=$5 }
		END { if (lat!="") print lat "\t" lon "\t" co "\t" ci }' "$PF_GEO_CACHE"
}

# Seeds the kernel sets from the UCI lists and re-labels an EXISTING row. It
# never creates one: a row is evidence, a pin is intent (pf_servers_json hides
# a pin without evidence).
pf_seed_lists() {
	local ip
	for ip in $PF_WHITELIST; do
		[ -z "$ip" ] && continue
		pf_allow_add "$ip" 1
		[ -n "$(pf_cache_get "$ip")" ] && pf_cache_set_state "$ip" "whitelist"
	done
	for ip in $PF_BLACKLIST; do
		[ -z "$ip" ] && continue
		pf_block_add "$ip" 1
		[ -n "$(pf_cache_get "$ip")" ] && pf_cache_set_state "$ip" "blacklist"
	done
}

# Does this ping accept -A? Probed once per boot against loopback, cached in
# $PF_RUN_DIR/.ping-adaptive.
_pf_ping_adaptive() {
	local f="$PF_RUN_DIR/.ping-adaptive" v=""
	[ -f "$f" ] && read -r v < "$f" 2>/dev/null
	case "$v" in
		1) return 0 ;;
		0) return 1 ;;
	esac
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	if _pf_run_with_timeout 3 ping -A -c 2 -W 1 127.0.0.1 >/dev/null 2>&1; then
		echo 1 > "$f" 2>/dev/null; return 0
	fi
	echo 0 > "$f" 2>/dev/null; return 1
}

# One RTT sample per line, warm-up EXCLUDED: the single source of ICMP samples,
# so the aggregation rule cannot drift. The first sample reads 2-3x the rest
# (route resolution, ARP), so it is dropped and the median is the statistic
# (one spike in a burst does not move it).
# Plain ping / ping6 under _pf_run_with_timeout: a slow burst never overruns
# the scan.
_pf_icmp_burst() {
	local ip="$1" c="${2:-5}" fam out cap
	[ -z "$ip" ] && return 0
	fam=$(pf_ip_family "$ip")
	# The same invocation LuCI's Network -> Diagnostics uses, so the readings
	# compare directly:
	#   ping  -4 -c 5 -W 1 <addr>
	#   ping6 -6 -c 5      <addr>
	# No -W on v6 (BusyBox ping6 has not always taken it). A basename through
	# $PATH: iputils-ping wins when installed. No -i (support varies). The
	# -4/-6 retry is ours: an unsupported flag fails at parse time, before any
	# packet, and a silent failure would leave every server on its estimate.
	# Without -i pacing is 1/s: cap = (c-1) s of gaps + the -W wait + margin.
	cap=$((c + 4))
	# -A sends the next echo as a reply lands (~c x RTT, not ~c s), and -w 2
	# ends the burst at 2 s, so a server that ignores echo costs 2 s, not
	# ~c s. Probed once and cached; without -A, 1/s pacing and no deadline.
	local af=""
	_pf_ping_adaptive && af="-A -w 2"
	if [ "$fam" = "v6" ]; then
		# Diagnostics runs a basename through $PATH: a check that agrees with
		# PATH resolution answers the same question.
		local p6="ping"
		command -v ping6 >/dev/null 2>&1 && p6="ping6"
		out=$(_pf_run_with_timeout "$cap" "$p6" -6 $af -c "$c" "$ip" 2>/dev/null)
		[ -z "$out" ] && out=$(_pf_run_with_timeout "$cap" "$p6" $af -c "$c" "$ip" 2>/dev/null)
	else
		out=$(_pf_run_with_timeout "$cap" ping -4 $af -c "$c" -W 1 "$ip" 2>/dev/null)
		[ -z "$out" ] && out=$(_pf_run_with_timeout "$cap" ping $af -c "$c" -W 1 "$ip" 2>/dev/null)
	fi
	[ -z "$out" ] && return 0
	# No portable seq field: the warm-up is dropped positionally.
	printf '%s\n' "$out" | awk '
		/time=/ {
			for (i = 1; i <= NF; i++)
				if (substr($i, 1, 5) == "time=") {
					v = substr($i, 6); gsub(/[^0-9.]/, "", v)
					if (v + 0 > 0) { n++; if (n > 1) print v + 0 }
				}
		}'
}

# MEDIAN of the burst, warm-up excluded. Empty when nothing answered.
pf_rtt_icmp() {
	local c="${2:-${PF_PING_COUNT:-5}}"
	[ "$c" -ge 2 ] 2>/dev/null || c=2
	_pf_icmp_burst "$1" "$c" | awk "$PF_MED_AWK"'{ v[++n] = $1 + 0 }
		END { if (n > 0) { a = int(med(v, n) + 0.5); if (a < 1) a = 1; printf "%d", a } }'
}

pf_ping_stats() {
	local ip="$1"
	# Output: "avg_ms jitter_ms 0 icmp" (field 3 an inert loss slot), or
	# "-1 0 0" when nothing answered. Every mode probes.
	[ -z "$ip" ] && { echo "-1 0 0"; return; }
	# Under 3 usable samples jitter is meaningless: with the warm-up dropped,
	# at least 4 are sent. The configured count rules everywhere else.
	local c="$PF_PING_COUNT"
	[ "$c" -ge 4 ] 2>/dev/null || c=4
	local out
	out=$(_pf_icmp_burst "$ip" "$c")
	if [ -n "$out" ]; then
		local stats
		# RTT = the median; jitter = mean |consecutive difference|; loss a hard
		# 0: ICMP burst loss must never reach telemetry or _pf_classify.
		stats=$(printf '%s\n' "$out" | awk "$PF_MED_AWK"'
			{
				x = $1 + 0
				if (x > 0) {
					if (n > 0) { d = x - prev; if (d < 0) d = -d; js += d; jn++ }
					v[++n] = x; prev = x
				}
			}
			END { if (n > 0) { a = int(med(v, n) + 0.5); if (a < 1) a = 1
					printf "%d %d %d icmp", a, (jn > 0 ? (js / jn) + 0.5 : 0), 0 } }')
		[ -n "$stats" ] && { echo "$stats"; return; }
	fi
	# Echo silent = no measurement: the estimate stands, no fourth field.
	echo "-1 0 0"
}


# Geo-cache upsert: remove the IP's row, then append. Readers take the
# first / last match, so a duplicate old row could shadow a fresh one.
_pf_geo_cache_put() {
	local ip="$1" lat="$2" lon="$3" country="$4" city="$5"
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	[ -f "$PF_GEO_CACHE" ] || : > "$PF_GEO_CACHE"
	local tmp="$PF_GEO_CACHE.put.$$" _lk
	_pf_side_lock
	awk -F'\t' -v ip="$ip" '$1 != ip { print }' "$PF_GEO_CACHE" > "$tmp" 2>/dev/null
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$ip" "$lat" "$lon" "$country" "$city" "$(date +%s)" >> "$tmp"
	mv "$tmp" "$PF_GEO_CACHE" 2>/dev/null
	_pf_side_unlock
}

# One fetch, bounded: -4 only when this wget takes it (uclient-fetch and GNU
# wget do, BusyBox wget does not), probed once per boot. $1 = seconds, then
# the wget arguments.
_pf_fetch() {
	local f="$PF_RUN_DIR/.wget4" v="" t="$1"
	shift
	[ -f "$f" ] && read -r v < "$f" 2>/dev/null
	case "$v" in
		0|1) ;;
		*) v=0; wget --help 2>&1 | grep -q -- '-4' && v=1
		   echo "$v" > "$f" 2>/dev/null ;;
	esac
	if [ "$v" = 1 ]; then
		_pf_run_with_timeout "$t" wget -4 "$@"
	else
		_pf_run_with_timeout "$t" wget "$@"
	fi
}

_pf_geo_try() {
	local provider="$1" ip="$2"
	local url resp lat lon country city own=""
	case "$provider" in
		ip-api)
			url="${PF_GEOIP_API}/$ip?fields=status,country,city,lat,lon,as"
			resp=$(_pf_fetch 5 -T 5 -qO- "$url" 2>/dev/null)
			[ -z "$resp" ] && return 1
			echo "$resp" | grep -q '"status":"success"' || return 1
			lat=$(echo     "$resp" | jsonfilter -e '@.lat'     2>/dev/null)
			lon=$(echo     "$resp" | jsonfilter -e '@.lon'     2>/dev/null)
			country=$(echo "$resp" | jsonfilter -e '@.country' 2>/dev/null)
			city=$(echo    "$resp" | jsonfilter -e '@.city'    2>/dev/null)
			own=$(echo     "$resp" | jsonfilter -e '@.as'      2>/dev/null)
			;;
		ipwhois)
			url="https://ipwho.is/$ip?fields=success,latitude,longitude,country,city,connection"
			resp=$(_pf_fetch 5 -T 5 -qO- "$url" 2>/dev/null)
			[ -z "$resp" ] && return 1
			echo "$resp" | grep -q '"success":true' || return 1
			lat=$(echo     "$resp" | jsonfilter -e '@.latitude'  2>/dev/null)
			lon=$(echo     "$resp" | jsonfilter -e '@.longitude' 2>/dev/null)
			country=$(echo "$resp" | jsonfilter -e '@.country'   2>/dev/null)
			city=$(echo    "$resp" | jsonfilter -e '@.city'      2>/dev/null)
			own=$(echo     "$resp" | jsonfilter -e '@.connection.org' 2>/dev/null)
			;;
		geojs)
			# Coordinates come as strings ("nil" when unknown).
			resp=$(_pf_fetch 5 -T 5 -qO- "https://get.geojs.io/v1/ip/geo/$ip.json" 2>/dev/null)
			[ -z "$resp" ] && return 1
			lat=$(echo     "$resp" | jsonfilter -e '@.latitude'  2>/dev/null)
			lon=$(echo     "$resp" | jsonfilter -e '@.longitude' 2>/dev/null)
			country=$(echo "$resp" | jsonfilter -e '@.country'   2>/dev/null)
			city=$(echo    "$resp" | jsonfilter -e '@.city'      2>/dev/null)
			own=$(echo     "$resp" | jsonfilter -e '@.organization_name' 2>/dev/null)
			;;
		freeipapi)
			resp=$(_pf_fetch 5 -T 5 -qO- "https://freeipapi.com/api/json/$ip" 2>/dev/null)
			[ -z "$resp" ] && return 1
			lat=$(echo     "$resp" | jsonfilter -e '@.latitude'    2>/dev/null)
			lon=$(echo     "$resp" | jsonfilter -e '@.longitude'   2>/dev/null)
			country=$(echo "$resp" | jsonfilter -e '@.countryName' 2>/dev/null)
			city=$(echo    "$resp" | jsonfilter -e '@.cityName'    2>/dev/null)
			;;
		ipapico)
			resp=$(_pf_fetch 5 -T 5 -qO- "https://ipapi.co/$ip/json/" 2>/dev/null)
			[ -z "$resp" ] && return 1
			echo "$resp" | grep -q '"error": *true' && return 1
			lat=$(echo     "$resp" | jsonfilter -e '@.latitude'     2>/dev/null)
			lon=$(echo     "$resp" | jsonfilter -e '@.longitude'    2>/dev/null)
			country=$(echo "$resp" | jsonfilter -e '@.country_name' 2>/dev/null)
			city=$(echo    "$resp" | jsonfilter -e '@.city'         2>/dev/null)
			;;
		*) return 1 ;;
	esac
	# Off the network over plain HTTP, and jsonfilter prints strings RAW: an
	# escaped newline in a city name would split a servers.tsv row, and the
	# tail's first column is spliced into `nft -f`. Coordinates must be plain
	# decimals; names lose control characters (tab, newline, \037), the two
	# HTML metacharacters the dashboard would render and the backslash (awk
	# -v reads "\t" in a value as a tab: _pf_prefix_learn).
	_pf_dec_ok "$lat" || lat=""
	_pf_dec_ok "$lon" || lon=""
	# 2 = it answered, but has no location for this address (GeoJS "nil"):
	# the service is up, only this one is unknown to it.
	[ -z "$lat" ] && [ -z "$lon" ] && return 2
	[ -z "$lat" ] && lat=0
	[ -z "$lon" ] && lon=0
	country=$(printf '%s' "$country" | awk '{ gsub(/[[:cntrl:]<>\\]/, ""); printf "%s", $0 }')
	city=$(printf '%s' "$city" | awk '{ gsub(/[[:cntrl:]<>\\]/, ""); printf "%s", $0 }')
	[ -n "$own" ] && _pf_owner_put "$ip" "$own"
	printf '%s\t%s\t%s\t%s\n' "$lat" "$lon" "$country" "$city"
	return 0
}

# Locations for several addresses in as few requests as can be, into the geo
# cache, so the per-address lookups after it are cache hits: GeoJS over HTTPS
# (50 a request) beside the stock endpoint, ip-api's batch (up to 100) with a
# geoip_api of your own. A matchmaking burst is located in one round trip,
# not one paced lookup per server. A failure is silent: the single lookups
# still run (a failed GeoJS rests geo_retry s, as there).
pf_geo_batch() {
	[ "$PF_GEOIP_LOOKUP" = "yes" ] || return 0
	[ $# -ge 2 ] || return 0
	command -v jsonfilter >/dev/null 2>&1 || return 0
	_pf_geo_down && return 0
	local ip q="" n=0 t=""
	if [ "$PF_GEOIP_API" = "$PF_GEOIP_DEFAULT" ]; then
		[ -f "$PF_RUN_DIR/.geo-down-geojs" ] && read -r t < "$PF_RUN_DIR/.geo-down-geojs" 2>/dev/null
		case "$t" in ''|*[!0-9]*) ;; *)
			[ $(( $(date +%s) - t )) -lt "${PF_GEO_RETRY:-60}" ] && return 0 ;;
		esac
		for ip in "$@"; do
			[ -n "$(pf_ip_family "$ip")" ] || continue
			q="$q${q:+,}$ip"; n=$((n + 1))
			[ "$n" -ge 50 ] || continue
			_pf_geo_batch_get geojs "$q" "$n" || return 0
			q=""; n=0
		done
		[ "$n" -gt 0 ] && _pf_geo_batch_get geojs "$q" "$n"
		return 0
	fi
	case "$PF_GEOIP_API" in */json) ;; *) return 0 ;; esac
	for ip in "$@"; do
		[ -n "$(pf_ip_family "$ip")" ] || continue
		[ "$n" -ge 100 ] && break
		q="$q${q:+,}\"$ip\""; n=$((n + 1))
	done
	[ "$n" -ge 2 ] && _pf_geo_batch_get ip-api "[$q]" "$n"
	return 0
}
# _pf_geo_batch_get <geojs|ip-api> <query> <count>: one batch request, each
# answer checked as a single lookup's is, into the geo cache and the owner
# list. 1 = the service did not answer.
_pf_geo_batch_get() {
	local resp i=0 st q lat lon co ci own
	date +%s > "$PF_RUN_DIR/geo-last-call" 2>/dev/null
	if [ "$1" = geojs ]; then
		resp=$(_pf_fetch 8 -T 6 -qO- "https://get.geojs.io/v1/ip/geo.json?ip=$2" 2>/dev/null)
	else
		resp=$(_pf_fetch 8 -T 6 -qO- --post-data="$2" \
			"${PF_GEOIP_API%/json}/batch?fields=status,country,city,lat,lon,query,as" 2>/dev/null)
	fi
	case "$resp" in
		'['*) ;;
		*) [ "$1" = geojs ] && date +%s > "$PF_RUN_DIR/.geo-down-geojs" 2>/dev/null
		   return 1 ;;
	esac
	if [ "$1" = geojs ]; then
		rm -f "$PF_RUN_DIR/.geo-down" "$PF_RUN_DIR/.geo-down-geojs" 2>/dev/null
		_pf_geo_svc_up geojs
	fi
	while [ "$i" -lt "$3" ]; do
		st=""; q=""; lat=""; lon=""; co=""; ci=""; own=""
		if [ "$1" = geojs ]; then
			eval "$(jsonfilter -s "$resp" -e "q=@[$i].ip" -e "lat=@[$i].latitude" -e "lon=@[$i].longitude" \
				-e "co=@[$i].country" -e "ci=@[$i].city" -e "own=@[$i].organization_name" 2>/dev/null)"
			# No city = a country's centre (anycast, CDN): left to the
			# single lookups, which place more of those.
			[ -n "$q" ] && { st=nocity; [ -n "$ci" ] && st=success; }
		else
			eval "$(jsonfilter -s "$resp" -e "st=@[$i].status" -e "q=@[$i].query" -e "lat=@[$i].lat" \
				-e "lon=@[$i].lon" -e "co=@[$i].country" -e "ci=@[$i].city" -e "own=@[$i].as" 2>/dev/null)"
		fi
		i=$((i + 1))
		[ -n "$st" ] || break
		[ "$st" = "success" ] && [ -n "$(pf_ip_family "$q")" ] || continue
		# Off the network: numbers must be numbers, names lose control
		# characters and angle brackets (as _pf_geo_try).
		_pf_dec_ok "$lat" && _pf_dec_ok "$lon" || continue
		_pf_geo_known "$lat" "$lon" || continue
		co=$(printf '%s' "$co" | awk '{ gsub(/[[:cntrl:]<>\\]/, ""); printf "%s", $0 }')
		ci=$(printf '%s' "$ci" | awk '{ gsub(/[[:cntrl:]<>\\]/, ""); printf "%s", $0 }')
		_pf_geo_cache_put "$q" "$lat" "$lon" "$co" "$ci"
		[ -n "$own" ] && _pf_owner_put "$q" "$own"
	done
	return 0
}

# A cached location for $1 still inside its time (a real one 30 days, a failed
# lookup PF_GEO_NEG): 0 with PF_G_* set.
_pf_geo_fresh() {
	local row
	[ -f "$PF_GEO_CACHE" ] || return 1
	row=$(awk -F'\t' -v ip="$1" '$1 == ip { print; exit }' "$PF_GEO_CACHE")
	[ -n "$row" ] || return 1
	_pf_georow "$row"
	case "$PF_G_TS" in ''|*[!0-9]*) return 1 ;; esac
	if _pf_geo_known "$PF_G_LAT" "$PF_G_LON"; then row=2592000; else row=${PF_GEO_NEG:-600}; fi
	[ $(( $(date +%s) - PF_G_TS )) -lt "$row" ]
}
# Location lookups on, and no service answered (geo-svc "down").
_pf_geo_is_down() {
	local st=""
	[ "$PF_GEOIP_LOOKUP" = "yes" ] || return 1
	read -r st _ 2>/dev/null < "$PF_RUN_DIR/geo-svc"
	[ "$st" = "down" ]
}
# Every location service failed within geo_retry seconds: no network lookup
# until then, so an unreachable service costs one try, not one per server.
_pf_geo_down() {
	local t=""
	[ -f "$PF_RUN_DIR/.geo-down" ] && read -r t < "$PF_RUN_DIR/.geo-down" 2>/dev/null
	case "$t" in ''|*[!0-9]*) return 1 ;; esac
	[ $(( $(date +%s) - t )) -lt "${PF_GEO_RETRY:-60}" ]
}

# The services asked, in order. The HTTPS ones first and the stock ip-api
# endpoint (plain HTTP) last; an endpoint of your own is the only one.
_pf_geo_services() {
	if [ "$PF_GEOIP_API" = "$PF_GEOIP_DEFAULT" ]; then
		echo "ipwhois geojs freeipapi ipapico ip-api"
	else
		echo "ip-api"
	fi
}
# $PF_RUN_DIR/geo-svc: "ok <services that answered>" or "down" (none did).
# Written by the start-up test, kept current by the lookups.
_pf_geo_svc_up() {
	local st=""
	read -r st _ 2>/dev/null < "$PF_RUN_DIR/geo-svc"
	[ "$st" = "ok" ] && return 0
	echo "ok $1" > "$PF_RUN_DIR/geo-svc" 2>/dev/null
}
_pf_geo_svc_down() {
	local st="" svc
	read -r st _ 2>/dev/null < "$PF_RUN_DIR/geo-svc"
	[ "$st" = "down" ] && return 0
	# Down only when every service has failed within geo_retry.
	for svc in $(_pf_geo_services); do
		[ -f "$PF_RUN_DIR/.geo-down-$svc" ] || return 0
	done
	echo "down" > "$PF_RUN_DIR/geo-svc" 2>/dev/null
	pf_note "WARN" "ping filter: no location service answers ($(_pf_geo_services)) - servers stay not located; an ad blocker or DNS filter on the router may be blocking them"
}
# Ask every service for one known address (start, geo_check): which answer.
pf_geo_svc_check() {
	[ "$PF_GEOIP_LOOKUP" = "yes" ] || { rm -f "$PF_RUN_DIR/geo-svc" 2>/dev/null; return 0; }
	command -v jsonfilter >/dev/null 2>&1 || return 0
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	local svc ok="" bad=""
	for svc in $(_pf_geo_services); do
		if [ -n "$(_pf_geo_try "$svc" 8.8.8.8)" ]; then
			ok="$ok $svc"; rm -f "$PF_RUN_DIR/.geo-down-$svc" 2>/dev/null
		else
			bad="$bad $svc"; date +%s > "$PF_RUN_DIR/.geo-down-$svc" 2>/dev/null
		fi
	done
	date +%s > "$PF_RUN_DIR/geo-last-call" 2>/dev/null
	if [ -n "$ok" ]; then
		echo "ok$ok" > "$PF_RUN_DIR/geo-svc" 2>/dev/null
		[ -n "$bad" ] && pf_note "INFO" "ping filter: location services not answering:$bad (using:$ok)"
	else
		echo "down" > "$PF_RUN_DIR/geo-svc" 2>/dev/null
		pf_note "WARN" "ping filter: no location service answers ($(_pf_geo_services)) - servers stay not located; an ad blocker or DNS filter on the router may be blocking them"
	fi
	return 0
}

pf_geo_lookup() {
	[ "$PF_GEOIP_LOOKUP" = "yes" ] || { echo "0	0		"; return; }
	local ip="$1"
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	if _pf_geo_fresh "$ip"; then
		printf '%s\t%s\t%s\t%s\n' "$PF_G_LAT" "$PF_G_LON" "$PF_G_CO" "$PF_G_CI"
		return
	fi
	if ! command -v jsonfilter >/dev/null 2>&1 || _pf_geo_down; then
		echo "0	0		"
		return
	fi

	# Pace geo calls inside ip-api's free tier (45 / min) so the WAN IP is
	# never banned. Whole seconds: `date +%s%3N` needs FEATURE_DATE_NANO and
	# fractional sleep FEATURE_FLOAT_DURATION, both off in OpenWrt's default
	# BusyBox. Two seconds between calls fits the budget.
	local stamp_file="$PF_RUN_DIR/geo-last-call"
	if [ -f "$stamp_file" ]; then
		local last_s now_s delta_s
		last_s=$(cat "$stamp_file" 2>/dev/null)
		now_s=$(date +%s 2>/dev/null)
		case "$last_s" in ''|*[!0-9]*) last_s=0 ;; esac
		case "$now_s"  in ''|*[!0-9]*) now_s=0  ;; esac
		if [ "$last_s" -gt 0 ] && [ "$now_s" -gt 0 ] 2>/dev/null; then
			delta_s=$((now_s - last_s))
			[ "$delta_s" -ge 0 ] 2>/dev/null && [ "$delta_s" -lt 2 ] 2>/dev/null && sleep 2
		fi
	fi
	date +%s > "$stamp_file" 2>/dev/null

	# Each service asked once; one that failed rests geo_retry s, so a
	# blocked one (an ad blocker or DNS filter) costs one try, not one per
	# server.
	local result provider t rc ans=0
	for provider in $(_pf_geo_services); do
		t=""
		[ -f "$PF_RUN_DIR/.geo-down-$provider" ] && read -r t < "$PF_RUN_DIR/.geo-down-$provider" 2>/dev/null
		case "$t" in ''|*[!0-9]*) ;; *)
			[ $(( $(date +%s) - t )) -lt "${PF_GEO_RETRY:-60}" ] && continue ;;
		esac
		result=$(_pf_geo_try "$provider" "$ip"); rc=$?
		# Not answering rests the service; answering "unknown" does not.
		[ "$rc" = 2 ] && { ans=1; continue; }
		if [ -z "$result" ]; then
			date +%s > "$PF_RUN_DIR/.geo-down-$provider" 2>/dev/null
			continue
		fi
		if [ -n "$result" ]; then
			rm -f "$PF_RUN_DIR/.geo-down" "$PF_RUN_DIR/.geo-down-$provider" 2>/dev/null
			_pf_geo_svc_up "$provider"
			_pf_geo4 "$result"
			_pf_geo_cache_put "$ip" "$PF_R_LAT" "$PF_R_LON" "$PF_R_CO" "$PF_R_CI"
			printf '%s\t%s\t%s\t%s\n' "$PF_R_LAT" "$PF_R_LON" "$PF_R_CO" "$PF_R_CI"
			return
		fi
	done

	# Negative-cache the failure, so it is retried paced, not every scan; and,
	# when no service answered at all, hold every lookup off for geo_retry s.
	if [ "$ans" = 0 ]; then
		date +%s > "$PF_RUN_DIR/.geo-down" 2>/dev/null
		_pf_geo_svc_down
	fi
	_pf_geo_cache_put "$ip" "0" "0" "" ""
	echo "0	0		"
}

pf_cache_init() {
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	[ -f "$PF_SERVERS_TSV" ] || : > "$PF_SERVERS_TSV"
}

pf_cache_init_once() {
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	rm -f "$PF_SERVERS_TSV.tmp" "$PF_SERVERS_TSV.age" \
		"$PF_SERVERS_TSV.idle" "$PF_SERVERS_TSV.lc" \
		"$PF_SERVERS_TSV.purge" "$PF_SERVERS_TSV.san" \
		"$PF_SERVERS_TSV.up."* "$PF_SERVERS_TSV.rc."* \
		"$PF_SERVERS_TSV.rc.snap."* "$PF_SERVERS_TSV.age."* \
		"$PF_SERVERS_TSV.tr."* "$PF_SERVERS_TSV.del."* \
		"$PF_SERVERS_TSV.ss."* "$PF_SERVERS_TSV.purge."* \
		"$PF_SERVERS_TSV.pin."* \
		"$PF_RUN_DIR/.expired" "$PF_RUN_DIR/.expired."* \
		"$PF_GEO_CACHE.prune" "$PF_GEO_CACHE.purge" 2>/dev/null
	[ -f "$PF_SERVERS_TSV" ] || : > "$PF_SERVERS_TSV"
}

# flock on fd $1 ($2 the file, $3 seconds to wait): the kernel drops the lock
# when its holder dies, so there is no stale break and no lock to steal.
# Closing the fd releases it. Fds: 6 the scan, 7 servers.tsv and its side
# files (9 is the probe FIFO). A child forked while a lock is held inherits
# it: anything long-lived started then closes the fd. Without flock (a
# BusyBox built without it): unserialised.
_pf_flock() {
	local _w=0
	command -v flock >/dev/null 2>&1 || return 0
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	# A failed redirection on exec ends the shell: probe it first.
	( : >> "$2" ) 2>/dev/null || return 1
	eval "exec $1>>\"\$2\""
	until flock -n "$1"; do
		if [ "$_w" -ge "$3" ]; then
			eval "exec $1>&-"
			return 1
		fi
		_w=$((_w + 1))
		sleep 1
	done
	return 0
}
pf_tsv_lock() { _pf_flock 7 "$PF_RUN_DIR/.lock-tsv" 10; }
pf_tsv_unlock() {
	exec 7>&-
	return 0
}
# The side files (geo cache, /24 memory, grade history) share the lock: the
# daemon, its background jobs and CLI verbs all rewrite them. Best effort: on
# timeout the write goes ahead unlocked (a lost grade is worse than the race).
# Callers declare `local _lk`; never call while holding pf_tsv_lock (not
# re-entrant).
_pf_side_lock()   { _lk=0; pf_tsv_lock && _lk=1; return 0; }
_pf_side_unlock() { [ "$_lk" = 1 ] && pf_tsv_unlock; _lk=0; return 0; }

pf_cache_sanitise() {
	[ -f "$PF_SERVERS_TSV" ] || return 0
	[ -s "$PF_SERVERS_TSV" ] || return 0
	local sanitised="$PF_SERVERS_TSV.san"
	awk -F'\t' 'BEGIN { OFS = "\t" }
		{
			# 12 columns (jitter, loss last). Older 10- and 11-column
			# rows are padded, so every surviving row is 12 wide.
			if (NF < 10 || NF > 12) { dropped++; next }
			if (NF < 12) $12 = ""
			# Both families: the sets and the lists are dual-stack.
			if ($1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ \
			    && $1 !~ /^[0-9A-Fa-f:]+$/) { dropped++; next }
			s = $2
			if (s != "allowed" && s != "blocked" \
			    && s != "whitelist" && s != "blacklist") { dropped++; next }
			kept++
			print
		}
		END {
			print "__STATS__\t" kept "\t" dropped > "/dev/stderr"
		}
	' "$PF_SERVERS_TSV" > "$sanitised" 2>"$PF_RUN_DIR/.san.log"
	if [ -f "$sanitised" ]; then
		# Guarded: a failed acquire must not rewrite the TSV or remove a lock
		# it does not own.
		pf_tsv_lock || { rm -f "$sanitised" "$PF_RUN_DIR/.san.log" 2>/dev/null; return 1; }
		pf_tsv_replace "$sanitised" "$PF_SERVERS_TSV" 50
		pf_tsv_unlock
		local n_dropped
		n_dropped=$(awk -F'\t' '/^__STATS__/ { print $3+0 }' "$PF_RUN_DIR/.san.log" 2>/dev/null)
		if [ "${n_dropped:-0}" -gt 0 ] 2>/dev/null; then
			msg "ping filter: TSV migration — dropped $n_dropped old/corrupt row(s)"
		fi
	fi
	rm -f "$PF_RUN_DIR/.san.log" 2>/dev/null
}

################################################################################
### DURABILITY LAYER                                                         ###
###                                                                          ###
###   servers.tsv is rewritten wholesale by five paths (upsert, reclassify,  ###
###   truncate, age-out, sanitise) and lives on tmpfs.                       ###
###   (a) pf_tsv_replace: a guarded mv that refuses an empty or implausibly  ###
###       shrunken rewrite over a healthy file.                              ###
###   (b) servers.tsv, the geo cache and graded history are mirrored to      ###
###       /etc/qos-ex, paced by persist_interval, so they survive reboots.   ###
################################################################################

pf_tsv_replace() {
	local tmp="$1" dst="$2" floor_pct="${3:-50}"
	[ -f "$tmp" ] || return 1
	local new_n old_n
	new_n=$(wc -l < "$tmp" 2>/dev/null); new_n=${new_n:-0}
	if [ -f "$dst" ]; then
		old_n=$(wc -l < "$dst" 2>/dev/null); old_n=${old_n:-0}
	else
		old_n=0
	fi
	# floor_pct=0 callers (age-out, geo heal) may legitimately empty the file;
	# for floor-protected callers (sanitise, truncate) empty means the filter
	# ate everything.
	if [ "$floor_pct" -gt 0 ] 2>/dev/null && \
	   [ "$old_n" -gt 0 ] 2>/dev/null && [ "$new_n" -eq 0 ] 2>/dev/null; then
		err "ping filter: refused TSV replace ($dst) — rewrite was empty, kept $old_n existing row(s)"
		rm -f "$tmp" 2>/dev/null
		return 1
	fi
	if [ "$floor_pct" -gt 0 ] 2>/dev/null && [ "$old_n" -ge 10 ] 2>/dev/null; then
		local floor=$(( old_n * floor_pct / 100 ))
		if [ "$new_n" -lt "$floor" ] 2>/dev/null; then
			err "ping filter: refused TSV replace ($dst) — rewrite shrank $old_n -> $new_n (< ${floor_pct}% floor), kept existing"
			rm -f "$tmp" 2>/dev/null
			return 1
		fi
	fi
	mv "$tmp" "$dst" 2>/dev/null
}

pf_persist_save() {
	local force="${1:-0}"
	mkdir -p "$PF_PERSIST_DIR" 2>/dev/null || return 0
	mkdir -p "$PF_RUN_DIR" 2>/dev/null   # stamp lives here; fresh boot may not have it yet
	local stamp="$PF_RUN_DIR/.persist.stamp" now last
	now=$(date +%s)
	if [ "$force" != "1" ] && [ -f "$stamp" ]; then
		last=$(cat "$stamp" 2>/dev/null); last=${last:-0}
		[ $((now - last)) -lt "${PF_PERSIST_INTERVAL:-3600}" ] 2>/dev/null && return 0
	fi
	_pf_atomic_cp "$PF_SERVERS_TSV" "$PF_PERSIST_DIR/servers.tsv"
	_pf_atomic_cp "$PF_GEO_CACHE"  "$PF_PERSIST_DIR/geo-cache.tsv"
	_pf_atomic_cp "$PF_PREFIX_TSV" "$PF_PERSIST_DIR/prefix.tsv"
	_pf_atomic_cp "$PF_TELE_HIST"  "$PF_PERSIST_DIR/telemetry.tsv"
	_pf_atomic_cp "$PF_SESS_TSV"   "$PF_PERSIST_DIR/sessions.tsv"
	_pf_atomic_cp "$PF_OWNER_TSV"  "$PF_PERSIST_DIR/owner.tsv"
	echo "$now" > "$stamp" 2>/dev/null
}

pf_persist_restore() {
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	if [ ! -s "$PF_SERVERS_TSV" ] && [ -s "$PF_PERSIST_DIR/servers.tsv" ]; then
		cp "$PF_PERSIST_DIR/servers.tsv" "$PF_SERVERS_TSV" 2>/dev/null
	fi
	if [ ! -s "$PF_PREFIX_TSV" ] && [ -s "$PF_PERSIST_DIR/prefix.tsv" ]; then
		cp "$PF_PERSIST_DIR/prefix.tsv" "$PF_PREFIX_TSV" 2>/dev/null
	fi
	if [ ! -s "$PF_GEO_CACHE" ] && [ -s "$PF_PERSIST_DIR/geo-cache.tsv" ]; then
		cp "$PF_PERSIST_DIR/geo-cache.tsv" "$PF_GEO_CACHE" 2>/dev/null
	fi
	if [ ! -s "$PF_TELE_HIST" ] && [ -s "$PF_PERSIST_DIR/telemetry.tsv" ]; then
		cp "$PF_PERSIST_DIR/telemetry.tsv" "$PF_TELE_HIST" 2>/dev/null
	fi
	if [ ! -s "$PF_SESS_TSV" ] && [ -s "$PF_PERSIST_DIR/sessions.tsv" ]; then
		cp "$PF_PERSIST_DIR/sessions.tsv" "$PF_SESS_TSV" 2>/dev/null
	fi
	if [ ! -s "$PF_OWNER_TSV" ] && [ -s "$PF_PERSIST_DIR/owner.tsv" ]; then
		cp "$PF_PERSIST_DIR/owner.tsv" "$PF_OWNER_TSV" 2>/dev/null
	fi
	# Left by the game names of Ping Filter 2.0.8.3 and older.
	rm -f "$PF_PERSIST_DIR/games.tsv" "$PF_RUN_DIR/games.tsv" "$PF_RUN_DIR/game-learn.tsv" \
		"$PF_RUN_DIR/.gamelist" "$PF_RUN_DIR/.dnstap" "$PF_RUN_DIR"/.gdev-* \
		"$PF_RUN_DIR"/.dnsr-* "$PF_RUN_DIR"/.gtag-* 2>/dev/null
	# Left by the saved setups of Ping Filter 2.0.8.6 and older.
	if [ -d /etc/qos-ex/games ]; then
		rm -f /etc/qos-ex/games/*.game 2>/dev/null
		rmdir /etc/qos-ex/games 2>/dev/null
	fi
}

pf_cache_get() {
	local ip="$1"
	# A row still in the scan's journal lands first (see pf_cache_upsert).
	case " $PF_UP_IPS " in *" $ip "*) _pf_up_flush ;; esac
	[ -f "$PF_SERVERS_TSV" ] || return 1
	awk -F'\t' -v ip="$ip" '$1 == ip { print; exit }' "$PF_SERVERS_TSV"
}

pf_cache_upsert() {
	local ip="$1" state="$2" ping="${3:-0}" ping_src="${4:-real}"
	local lat="$5" lon="$6" country="$7" city="$8" lan_src="$9"
	# $10 jitter, $11 the handshake's connects (col 12, once the loss): each
	# empty = keep what the row has. $12 = last seen (epoch): only the flow
	# loop passes it; anything else keeps the row's own, and a new row is
	# stamped now.
	local jitter="${10:-}" loss="${11:-}" seen="${12:-}" now tmp
	# Inside the scan's flow loop (PF_UP_JRN set) the row goes to a journal
	# and lands with the pass's others in one rewrite (_pf_up_flush): one
	# awk, one lock and no date fork a pass instead of each a server.
	# pf_cache_get flushes first for a journaled address: reads stay exact.
	if [ -n "$PF_UP_JRN" ]; then
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ip" "$state" "$ping" "$ping_src" \
			"$lat" "$lon" "$country" "$city" "$seen" "$lan_src" "$jitter" "$loss" >> "$PF_UP_JRN" || return 1
		PF_UP_IPS="$PF_UP_IPS $ip"
		return 0
	fi
	now=$(date +%s)
	pf_cache_init
	pf_tsv_lock || return 1
	tmp="$PF_SERVERS_TSV.up.$$"
	# Country and city through the environment, not -v: awk would read a
	# backslash in a -v value as an escape.
	PF_UP_CO="$country" PF_UP_CI="$city" awk -F'\t' -v OFS='\t' -v ip="$ip" -v st="$state" \
	    -v pg="$ping" -v ps="$ping_src" -v la="$lat" -v lo="$lon" -v lan="$lan_src" \
	    -v jit="$jitter" -v loss="$loss" -v seen="$seen" -v now="$now" '
		$1 == ip { kts = $9; kj = $11; kl = $12; next }
		{ print }
		END {
			if (jit == "") jit = kj
			if (loss == "") loss = kl
			if (seen !~ /^[0-9]+$/) seen = (kts ~ /^[0-9]+$/) ? kts : now
			print ip, st, pg, ps, la, lo, ENVIRON["PF_UP_CO"], ENVIRON["PF_UP_CI"], seen, lan, jit, loss
		}' "$PF_SERVERS_TSV" > "$tmp" 2>/dev/null && mv "$tmp" "$PF_SERVERS_TSV" 2>/dev/null
	rm -f "$tmp" 2>/dev/null
	pf_tsv_unlock
}

# The journal into servers.tsv in one rewrite: a journal row replaces or
# adds its row (later entries for one address win), rows keep their place,
# and the keep rules are pf_cache_upsert's: empty jitter / connects keep the
# row's, a last-seen that is not a number keeps the row's, else now.
_pf_up_flush() {
	local now tmp
	if [ -z "$PF_UP_JRN" ] || [ ! -s "$PF_UP_JRN" ]; then PF_UP_IPS=""; return 0; fi
	now=$(date +%s)
	pf_cache_init
	pf_tsv_lock || return 1
	tmp="$PF_SERVERS_TSV.up.$$"
	awk -F'\t' -v OFS='\t' -v jf="$PF_UP_JRN" -v now="$now" '
		function merge(ip, line,    f, o, i) {
			split(line, f, "\t")
			for (i = 1; i <= 12; i++) o[i] = ""
			if (ip in R) split(R[ip], o, "\t")
			if (f[11] == "") f[11] = o[11]
			if (f[12] == "") f[12] = o[12]
			if (f[9] !~ /^[0-9]+$/) f[9] = (o[9] ~ /^[0-9]+$/) ? o[9] : now
			if (!(ip in R)) N[++nn] = ip
			R[ip] = f[1]
			for (i = 2; i <= 12; i++) R[ip] = R[ip] "\t" f[i]
		}
		{ if (!($1 in R)) O[++no] = $1; R[$1] = $0 }
		END {
			while ((getline l < jf) > 0) { ip = l; sub(/\t.*/, "", ip); if (ip != "") merge(ip, l) }
			close(jf)
			for (i = 1; i <= no; i++) print R[O[i]]
			for (i = 1; i <= nn; i++) print R[N[i]]
		}' "$PF_SERVERS_TSV" > "$tmp" 2>/dev/null && mv "$tmp" "$PF_SERVERS_TSV" 2>/dev/null
	rm -f "$tmp" 2>/dev/null
	pf_tsv_unlock
	: > "$PF_UP_JRN"; PF_UP_IPS=""
	return 0
}

pf_cache_delete() {
	local ip="$1"
	[ -f "$PF_SERVERS_TSV" ] || return 0
	pf_tsv_lock || return 1
	local tmp="$PF_SERVERS_TSV.del.$$"
	awk -F'\t' -v ip="$ip" '$1 != ip { print }' "$PF_SERVERS_TSV" > "$tmp" 2>/dev/null
	pf_tsv_replace "$tmp" "$PF_SERVERS_TSV" 0
	pf_tsv_unlock
}

pf_cache_set_state() {
	local ip="$1" newstate="$2"
	[ -f "$PF_SERVERS_TSV" ] || return 0
	pf_tsv_lock || return 1
	local tmp="$PF_SERVERS_TSV.ss.$$"
	awk -F'\t' -v ip="$ip" -v st="$newstate" 'BEGIN{OFS="\t"}
		$1 == ip { $2 = st } { print }' "$PF_SERVERS_TSV" > "$tmp" 2>/dev/null
	pf_tsv_replace "$tmp" "$PF_SERVERS_TSV" 50
	pf_tsv_unlock
}

pf_cache_truncate() {
	[ -f "$PF_SERVERS_TSV" ] || return 0
	local n tmp expired
	n=$(wc -l < "$PF_SERVERS_TSV" 2>/dev/null)
	[ "${n:-0}" -le "$PF_MAX_SERVERS" ] && return 0
	pf_tsv_lock || return 1
	tmp="$PF_SERVERS_TSV.tr.$$"
	expired="$PF_RUN_DIR/.expired.$$"
	# Whitelist / blacklist rows always stay; the rest by last seen (col 9),
	# newest first, up to max_servers. A live server is the newest.
	awk -F'\t' -v wl=" $PF_WHITELIST " -v bl=" $PF_BLACKLIST " -v cap="$PF_MAX_SERVERS" -v expf="$expired" '
		{ lines[NR] = $0; ips[NR] = $1; tss[NR] = $9 + 0
		  if ($2 == "whitelist" || $2 == "blacklist" || index(wl, " " $1 " ") || index(bl, " " $1 " ")) PIN[NR] = 1 }
		END {
			for (i = 1; i <= NR; i++) if (i in PIN) { print lines[i]; KEEP[i] = 1; count++ }
			while (count < cap) {
				best_ts = -1; best_i = 0
				for (i = 1; i <= NR; i++) if (!(i in KEEP) && tss[i] > best_ts) { best_ts = tss[i]; best_i = i }
				if (best_i == 0) break
				print lines[best_i]; KEEP[best_i] = 1; count++
			}
			for (i = 1; i <= NR; i++) if (!(i in KEEP) && ips[i] != "") print ips[i] > expf
		}
	' "$PF_SERVERS_TSV" > "$tmp" 2>/dev/null && pf_tsv_replace "$tmp" "$PF_SERVERS_TSV" 0
	pf_tsv_unlock
	_pf_evict "$expired"
}

# The addresses in file $1 (one per line) lose their kernel verdict and
# per-server scratch; the file goes. An evicted row leaves nothing behind.
_pf_evict() {
	local _xip
	[ -s "$1" ] && while IFS= read -r _xip; do
		[ -n "$_xip" ] || continue
		_pf_set_put none "$_xip" 0
		_pf_purge_ip_runtime "$_xip"
	done < "$1"
	rm -f "$1" 2>/dev/null
	return 0
}

pf_cache_age_out() {
	[ -f "$PF_SERVERS_TSV" ] || return 0
	[ -s "$PF_SERVERS_TSV" ] || return 0

	# Run dir first: a stale non-directory at the path is cleared so mkdir
	# can succeed.
	[ -e "$PF_RUN_DIR" ] && [ ! -d "$PF_RUN_DIR" ] && rm -f "$PF_RUN_DIR" 2>/dev/null
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	# Once a minute, not every tick: the TTLs are minutes to days and a pass
	# is ~35 processes.
	local _as="$PF_RUN_DIR/.ageout.stamp" _al=0 _an
	_an=$(date +%s)
	[ -f "$_as" ] && read -r _al < "$_as" 2>/dev/null
	case "$_al" in (''|*[!0-9]*) _al=0 ;; esac
	[ $((_an - _al)) -ge 0 ] && [ $((_an - _al)) -lt 60 ] && return 0
	echo "$_an" > "$_as" 2>/dev/null

	local sd="$PF_RUN_DIR/.age"
	[ -e "$sd" ] && [ ! -d "$sd" ] && rm -f "$sd" 2>/dev/null
	mkdir -p "$sd" 2>/dev/null
	[ -d "$sd" ] || return 0   # can't create scratch dir — skip silently
	pf_allow_ips 2>/dev/null | sort -u >  "$sd/members"
	pf_block_ips 2>/dev/null | sort -u >> "$sd/members"
	sort -u "$sd/members" -o "$sd/members" 2>/dev/null
	# Rows survive on their own last-seen stamp (row_ttl), so prune by age
	# even when both kernel sets are empty (between sessions).

	local now; now=$(date +%s)
	local tmp expired
	tmp="$PF_SERVERS_TSV.age.$$"
	expired="$PF_RUN_DIR/.expired.$$"
	: > "$expired" 2>/dev/null
	pf_tsv_lock || { rm -rf "$sd" 2>/dev/null; return 1; }
	# Keep a row if it is a whitelist / blacklist IP, its state is wl / bl, it
	# is in a kernel set, or it was seen within row_ttl. The last lets a server
	# outlive its set entry, so pf_sets_self_heal can re-seed from it.
	awk -F'\t' -v wl=" $PF_WHITELIST " -v bl=" $PF_BLACKLIST " \
	    -v members="$sd/members" -v expf="$expired" \
	    -v now="$now" -v ttl="${PF_ROW_TTL:-14400}" 'BEGIN {
			OFS = "\t"
			while ((getline m < members) > 0) if (m != "") MEM[m] = 1
			close(members)
		}
		{
			ip = $1; state = $2; ts = $9
			if (ip == "") next
			if (index(wl, " " ip " ") > 0 || index(bl, " " ip " ") > 0) { print; next }
			if (state == "whitelist" || state == "blacklist") { print; next }
			if ((ip in MEM) && ts !~ /^[0-9]+$/) { print; next }
			if (ts ~ /^[0-9]+$/ && (now - ts) < ttl) { print; next }
			print ip > expf
		}
	' "$PF_SERVERS_TSV" > "$tmp" 2>/dev/null && pf_tsv_replace "$tmp" "$PF_SERVERS_TSV" 0
	pf_tsv_unlock
	rm -rf "$sd" 2>/dev/null

	# An aged-out row must not leave a live verdict behind. An active server
	# cannot be here (the flow loop refreshes its stamp).
	_pf_evict "$expired"

	pf_geo_cache_prune
	pf_prefix_prune
}

pf_prefix_prune() {
	[ -s "$PF_PREFIX_TSV" ] || return 0
	local tmp="$PF_PREFIX_TSV.prune" _lk
	_pf_side_lock
	# The newest 2000 by a leading age: BusyBox sort on OpenWrt ignores -k
	# and -t and reads only the number a line starts with.
	awk -F'\t' -v now="$(date +%s)" -v ttl="${PF_PREFIX_TTL:-2592000}" \
		'$9 ~ /^[0-9]+$/ && (now - $9) < ttl { a = now - $9; print a "\t" $0 }' "$PF_PREFIX_TSV" 2>/dev/null \
		| sort -n | head -n 2000 | cut -f2- > "$tmp" && mv "$tmp" "$PF_PREFIX_TSV" 2>/dev/null
	rm -f "$tmp" 2>/dev/null
	_pf_side_unlock
}

pf_geo_cache_prune() {
	[ -f "$PF_GEO_CACHE" ] || return 0
	[ -s "$PF_GEO_CACHE" ] || return 0
	local now cutoff tmp _lk
	now=$(date +%s)
	cutoff=$((86400 * 30))
	tmp="$PF_GEO_CACHE.prune"
	_pf_side_lock
	awk -F'\t' -v now="$now" -v cutoff="$cutoff" '
		($6 ~ /^[0-9]+$/) && (now - $6) < cutoff { print }
	' "$PF_GEO_CACHE" > "$tmp" 2>/dev/null && mv "$tmp" "$PF_GEO_CACHE" 2>/dev/null
	_pf_side_unlock
}

# Server discovery (pf_discover_flows): the kernel fills @pf_seen with every
# public UDP destination a gaming device talks to, at packet level. Flow
# offloading must be off: an offloaded flow skips the forward hook, so its
# packets reach neither @pf_seen nor the activity counters (_pf_offload_on).
# lan_src is filled from conntrack when visible (display only).
# Output (TSV): lan_src \t server_ip \t port \t proto \t seen_age_seconds
# seen_age = seconds since the kernel last saw a packet to that server (0 =
# live). The scan refreshes only genuinely live rows.
# ===========================================================================
# LIVE TELEMETRY — passive, no ICMP, no injected packets.
# Only flows the device is actively exchanging UDP with (pf_tele_poll runs for
# rows with packets in the last ~20 s). Two passive signals:
#   * conntrack accounting deltas -> inbound PPS, throughput, stall. Needs
#     flow offload OFF, which the shaper enforces while shaping.
#   * a tcpdump window -> inter-arrival jitter and gaps. Counters only when
#     tcpdump is absent.
# tmpfs only. live.tsv columns (tab):
#   ip  pps_in  bps_in  jitter_ms  gap_max_ms  gaps  stall  ts
# ===========================================================================
# One pass over the conntrack table per tick, shared by everything the tick
# needs from it:
#   $PF_CT_TOT  "udp all" packet totals of the monitored devices, or
#               "-1 -1" when accounting is off (pf_traffic_totals)
#   $PF_CT_DST  per flow of a device: remote<TAB>device<TAB>packets from
#               the remote<TAB>their bytes<TAB>1 = game-port UDP to a
#               public remote (ignore_ports are none), else 0
#               (pf_flow_counters, discovery's LAN source, the session
#               guard). A flow the remote opened (port forward, UPnP, a
#               P2P host) is keyed on the remote too.
# PF_CT_FRESH=1 says the files are this tick's; a CLI verb reads the table
# itself.
_pf_ct_snap() {
	PF_CT_FRESH=0
	[ -r "$PF_CT_PROC" ] || return 0
	[ -n "$GAMING_IP4$GAMING_IP6" ] || return 0
	awk -v gips="$GAMING_IP4 $GAMING_IP6" -v minport=1024 -v tot="$PF_CT_TOT.$$" -v ign="$PF_IGNORE_AWK" '
	BEGIN { n = split(gips, A, /[ \t]+/); for (i = 1; i <= n; i++) if (A[i] != "") G[A[i]] = 1
		ni = split(ign, R, " "); for (i = 1; i <= ni; i++) { split(R[i], q, "-"); IL[i] = q[1] + 0; IH[i] = q[2] + 0 } }
	function game(p, a,    i) {
		if (!is_udp || p < minport) return 0
		for (i = 1; i <= ni; i++) if (p >= IL[i] && p <= IH[i]) return 0
		return a !~ /^(0\.|10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|2(2[4-9]|[3-5][0-9])\.|f[c-f])/
	}
	{
		src = ""; dst = ""; rsrc = ""; dport = -1; np = 0; nb = 0; p1 = 0; p2 = 0; b1 = 0; b2 = 0; is_udp = 0
		for (i = 1; i <= NF; i++) {
			if ($i == "udp") is_udp = 1
			else if (src == "" && substr($i, 1, 4) == "src=") src = substr($i, 5)
			else if (rsrc == "" && substr($i, 1, 4) == "src=") rsrc = substr($i, 5)
			else if (dst == "" && substr($i, 1, 4) == "dst=") dst = substr($i, 5)
			else if (dport < 0 && substr($i, 1, 6) == "dport=") dport = substr($i, 7) + 0
			else if (substr($i, 1, 8) == "packets=") { np++; if (np == 1) p1 = substr($i, 9) + 0; else if (np == 2) p2 = substr($i, 9) + 0 }
			else if (substr($i, 1, 6) == "bytes=") { nb++; if (nb == 1) b1 = substr($i, 7) + 0; else if (nb == 2) b2 = substr($i, 7) + 0 }
		}
		if (np > 0) acct = 1
		if (!(src in G)) {
			if ((rsrc in G) && src != "") printf "%s\t%s\t%.0f\t%.0f\t%d\n", src, rsrc, p1, b1, game(dport, src)
			next
		}
		all += p1 + p2
		if (is_udp && dport >= minport) udp += p1 + p2
		# %.0f: BusyBox awk casts %d to a 32-bit int, so a flow past 2 GiB
		# printed a frozen negative byte count.
		if (dst != "") printf "%s\t%s\t%.0f\t%.0f\t%d\n", dst, src, (np >= 2 ? p2 : p1), b2, game(dport, dst)
	}
	END { if (!acct && NR > 0) print "-1 -1" > tot; else print udp + 0, all + 0 > tot }
	' "$PF_CT_PROC" > "$PF_CT_DST.$$" 2>/dev/null || return 0
	mv "$PF_CT_DST.$$" "$PF_CT_DST" 2>/dev/null && mv "$PF_CT_TOT.$$" "$PF_CT_TOT" 2>/dev/null && PF_CT_FRESH=1
	return 0
}

pf_flow_counters() {
	# "pkts_in<TAB>bytes_in" for the reply (server -> host) direction of the
	# flow whose ORIGINAL destination is $1. Empty = no flow / no accounting.
	local ip="$1"
	[ -z "$ip" ] && return 0
	if [ "${PF_CT_FRESH:-0}" = 1 ]; then
		awk -F'\t' -v ip="$ip" '$1 == ip { p += $3; b += $4 } END { if (p > 0 || b > 0) print p "\t" b }' "$PF_CT_DST" 2>/dev/null
		return 0
	fi
	[ -r "$PF_CT_PROC" ] || return 0
	awk -v ip="$ip" '
		index($0, "dst=" ip " ") {
			np = 0; nb = 0
			for (i = 1; i <= NF; i++) {
				if      (substr($i, 1, 8) == "packets=") { np++; P[np] = substr($i, 9) + 0 }
				else if (substr($i, 1, 6) == "bytes=")   { nb++; B[nb] = substr($i, 7) + 0 }
			}
			# 2nd packets/bytes = reply tuple = inbound (server->host).
			# SUM across every flow to this dst: a game server carries one
			# high-rate session flow plus many one-shot matchmaking probes
			# (dport 22222, packets=1). First-match-wins locked onto a dead
			# probe and reported pps=0 forever; the sum tracks the real flow.
			tp += (np >= 2) ? P[2] : (np >= 1 ? P[1] : 0)
			tb += (nb >= 2) ? B[2] : (nb >= 1 ? B[1] : 0)
		}
		END { if (tp > 0 || tb > 0) print tp "	" tb }
	' "$PF_CT_PROC" 2>/dev/null
}

# Inter-arrival jitter of one inbound game stream, from `tcpdump -tt` lines.
# Nothing is sent to the server. A result is "jitter<TAB>gap_max<TAB>gaps"
# (ms, ms, count); loss is not estimated.
#   win = 0  one window: the whole input, printed at the end
#   win > 0  a window every `win` seconds, each written to the file `out`
# BURST COALESCING: game servers pack several packets per tick, so raw
# inter-arrivals measure the tick interval, not jitter. Nominal tick = p75 of
# the raw deltas; arrivals closer than tick/3 to the last kept arrival merge
# into one tick-arrival; deltas >= 1.5x tick are dropped ticks (counted by
# gaps, never as jitter); consecutive-difference jitter runs on the cleaned
# stream. Non-tick streams (nominal < 5 ms) and short windows (< 6 deltas)
# use the plain consecutive difference. gmax/gaps are raw deltas vs `gap`.
PF_JIT_AWK='
	function flush(    i, j, v, nom, w3, acc, np, cs, cn, cj, cp, fb, res) {
		res = ""; fb = 1
		if (nd >= 6) {
			for (i = 0; i < nd; i++) {
				v = D[i]
				for (j = i; j > 0 && S[j-1] > v; j--) S[j] = S[j-1]
				S[j] = v
			}
			nom = S[int(nd * 0.75)]
			if (nom >= 5) {
				w3 = nom / 3; acc = 0; np = 0; cs = 0; cn = 0
				for (i = 0; i < nd; i++) {
					acc += D[i]
					if (acc > w3) {
						if (acc < nom * 1.5) {
							if (np) { cj = acc - cp; if (cj < 0) cj = -cj; cs += cj; cn++ }
							cp = acc; np = 1
						}
						acc = 0
					}
				}
				if (cn > 0) { res = sprintf("%d\t%d\t%d", (cs / cn) + 0.5, gmax + 0.5, gaps + 0); fb = 0 }
			}
		}
		if (fb && nj > 0) res = sprintf("%d\t%d\t%d", (sj / nj) + 0.5, gmax + 0.5, gaps + 0)
		if (res != "") {
			if (out != "") { print res > out; close(out) }
			else printf "%s", res
		}
		nd = 0; gmax = 0; gaps = 0; sj = 0; nj = 0; hp = 0
		split("", D); split("", S)
	}
	{
		t = $1 + 0
		if (t <= 0) next
		if (win + 0 > 0) {
			if (!ws) ws = t
			else if (t - ws >= win) { flush(); ws = t }
		}
		if (have) {
			d = (t - prev) * 1000
			if (d < 0) d = 0
			if (d > gmax) gmax = d
			if (d > gap)  gaps++
			if (hp) { jd = d - pd; if (jd < 0) jd = -jd; sj += jd; nj++ }
			pd = d; hp = 1
			D[nd++] = d
		}
		prev = t; have = 1
	}
	END { if (win + 0 == 0) flush() }'

pf_udp_sample() {
	# One-shot passive jitter window over $2 seconds (the live-capture
	# report). Echo "jitter<TAB>gap_max<TAB>gaps" (ms, ms, count) or nothing
	# if tcpdump is missing / the stream is silent.
	local ip="$1" secs="${2:-3}"
	[ -z "$ip" ] && return 0
	command -v tcpdump >/dev/null 2>&1 || return 0
	# -p: no promiscuous mode. Only packets to this host's own WAN address
	# are wanted, which it receives anyway.
	_pf_run_with_timeout "$((secs + 1))" tcpdump -i "${PF_WAN:-pppoe-wan}" -p -nn -tt -q -l \
		"udp and src host $ip" 2>/dev/null | \
	awk -v gap="${PF_GAP_MS:-120}" -v win=0 -v out="" "$PF_JIT_AWK"
}

# The live jitter tap: ONE tcpdump per server while it stays game-rate, cut
# into PF_UDP_SAMPLE_SECS windows, each written to stats-<ip> for
# pf_tele_poll.
pf_udp_tap() {
	_pf_exec_as qos-ex-pf-jitter tcpdump -i "${PF_WAN:-pppoe-wan}" -p -nn -tt -q -l "udp and src host $1" 2>/dev/null | \
	awk -v qos_ex_pf=jitter -v gap="${PF_GAP_MS:-120}" -v win="${PF_UDP_SAMPLE_SECS:-2}" \
		-v out="$PF_RUN_DIR/stats-$1" "$PF_JIT_AWK"
}
_pf_tap_stop() {   # $1 = ip
	local f="$PF_RUN_DIR/.tap-$1" p=""
	[ -f "$f" ] || return 0
	read -r p < "$f" 2>/dev/null
	rm -f "$f" 2>/dev/null
	case "$p" in ''|*[!0-9]*) return 0 ;; esac
	# The pipeline's own processes first, then the subshell holding it.
	# shellcheck disable=SC2046
	kill $(_pf_proc_table | _pf_pick kids "$p") "$p" 2>/dev/null
	return 0
}
_pf_tap_stop_all() {
	local f
	for f in "$PF_RUN_DIR"/.tap-*; do
		[ -f "$f" ] && _pf_tap_stop "${f##*/.tap-}"
	done
	return 0
}
# A tap whose server has not been game-rate for 15 s is done.
_pf_tap_sweep() {
	local f ip t now="$1"
	for f in "$PF_RUN_DIR"/.tap-*; do
		[ -f "$f" ] || continue
		ip=${f##*/.tap-}; t=0
		[ -f "$PF_RUN_DIR/.samp-$ip" ] && read -r t < "$PF_RUN_DIR/.samp-$ip" 2>/dev/null
		case "$t" in ''|*[!0-9]*) t=0 ;; esac
		[ $((now - t)) -gt 15 ] && _pf_tap_stop "$ip"
	done
	return 0
}

pf_game_dport() {
	# UDP dport of the busiest flow to $1 (the game session, not matchmaking
	# probes). First dport= on a line is the original port; first packets= is
	# that flow's outbound count.
	local ip="$1"
	[ -z "$ip" ] && return 0
	[ -r "$PF_CT_PROC" ] || return 0
	awk -v ip="$ip" '
		index($0, "dst=" ip " ") {
			dp = ""; pk = 0
			for (i = 1; i <= NF; i++) {
				if      (substr($i,1,6) == "dport="  && dp == "") dp = substr($i,7) + 0
				else if (substr($i,1,8) == "packets=" && pk == 0) pk = substr($i,9) + 0
			}
			if (dp != "" && pk > best) { best = pk; bestdp = dp }
		}
		END { if (bestdp != "") print bestdp }
	' "$PF_CT_PROC" 2>/dev/null
}

pf_mm_json() {
	# The `matchmaking` verb, CLI only (no rpcd method calls it): TCP/443
	# flows from the gaming devices (auth, matchmaking, CDN), total bytes
	# per server, as JSON. No grading, no graph.
	local lan; lan=$(printf '%s' "${GAMING_IP4:-}" | awk '{print $1}')
	if [ ! -r "$PF_CT_PROC" ] || [ -z "${GAMING_IP4:-}" ]; then
		printf '{"gaming_lan":"%s","servers":[]}\n' "$lan"; return 0
	fi
	printf '{"gaming_lan":"%s","servers":[' "$lan"
	awk -v srcs="$GAMING_IP4" '
		BEGIN { n = split(srcs, S, " "); for (k = 1; k <= n; k++) IS[S[k]] = 1 }
		/tcp/ {
			sip = ""; dip = ""; dpt = ""; sumb = 0
			for (i = 1; i <= NF; i++) {
				if      (substr($i,1,4) == "src="   && sip == "") sip = substr($i,5)
				else if (substr($i,1,4) == "dst="   && dip == "") dip = substr($i,5)
				else if (substr($i,1,6) == "dport=" && dpt == "") dpt = substr($i,7) + 0
				else if (substr($i,1,6) == "bytes=") sumb += substr($i,7) + 0
			}
			if (IS[sip] && dpt == 443 && dip != "") T[dip] += sumb
		}
		END { first = 1; for (ip in T) { if (!first) printf ","; first = 0; printf "{\"ip\":\"%s\",\"bytes\":%.0f}", ip, T[ip] } }
	' "$PF_CT_PROC" 2>/dev/null
	printf ']}\n'
}


pf_rtt_probe() {
	# RTT probe for the CONNECTED server $1: "ms<TAB>icmp", or nothing when
	# echo is silent (the estimate stands). pf_tele_poll blends it into the row
	# and graph and, with a limit armed, re-grades the played server
	# PROMOTION ONLY.
	local ip="$1" ms
	[ -z "$ip" ] && return 0

	ms=$(pf_rtt_icmp "$ip")
	case "$ms" in ''|*[!0-9]*) ;; *) printf '%s\ticmp\n' "$ms"; return 0 ;; esac
	return 0
}

pf_tele_poll() {
	# One tick of live telemetry for connected server $1. Called
	# from the scan loop only: the sole writer of live.tsv, the ring and the
	# .ctr- / .samp- markers, so no locking.
	local ip="$1"
	[ -z "$ip" ] && return 0
	[ "${PF_TELEMETRY:-1}" = "1" ] || return 0
	# The pass's clock (pf_scan_once); a fork only when called on its own.
	local now="${PF_NOW:-$(date +%s)}"

	local ctr cur_pkts cur_bytes
	ctr=$(pf_flow_counters "$ip")
	[ -z "$ctr" ] && return 0
	cur_pkts=${ctr%%"	"*}; cur_bytes=${ctr#*"	"}

	# .ctr-<ip>: ts pkts bytes pps ring-lines-since-trim
	local cfile="$PF_RUN_DIR/.ctr-$ip" last_ts=0 last_pkts=0 last_bytes=0 prev_pps=0 rn=0
	[ -f "$cfile" ] && { IFS=' ' read -r last_ts last_pkts last_bytes prev_pps rn < "$cfile"; }
	case "$prev_pps" in (''|*[!0-9]*) prev_pps=0 ;; esac
	case "$rn" in (''|*[!0-9]*) rn=0 ;; esac

	local pps=0 bps=0 stall=0 measured=0 dt=$((now - ${last_ts:-0}))
	if [ "${last_ts:-0}" -gt 0 ] 2>/dev/null && [ "$dt" -ge 1 ] 2>/dev/null; then
		local dp=$((cur_pkts - ${last_pkts:-0})) db=$((cur_bytes - ${last_bytes:-0}))
		[ "$dp" -lt 0 ] 2>/dev/null && dp=0
		[ "$db" -lt 0 ] 2>/dev/null && db=0
		pps=$((dp / dt)); bps=$((db / dt))
		[ "$pps" -eq 0 ] && stall=1
		measured=1
	fi
	# The ring gets one line per call: trimmed every 20, not counted each time.
	local _trim=0
	rn=$((rn + 1)); [ "$rn" -ge 20 ] && { _trim=1; rn=0; }
	printf '%s %s %s %s %s\n' "$now" "$cur_pkts" "$cur_bytes" "$pps" "$rn" > "$cfile" 2>/dev/null
	# steady = this and the previous tick at in-game rate. A window spanning a
	# game start / stop reads silence as gaps: only steady windows count.
	local steady=0
	[ "$pps" -ge "${PF_TELE_JIT_MINPPS:-10}" ] 2>/dev/null && \
		[ "${prev_pps:-0}" -ge "${PF_TELE_JIT_MINPPS:-10}" ] 2>/dev/null && steady=1

	# --- In-play reading (the RTT probe below, landed in trtt-<ip>): folded
	# into the row on the shared path (_pf_reading: only a lower one is taken,
	# a pin keeps its state, a block while the server is played waits for the
	# session's end). Kept raw for the live graph (live.tsv col 10) and for
	# grading by playing (.ipr-<ip>, _pf_play_grade). ---
	local lv=""
	if [ -s "$PF_RUN_DIR/trtt-$ip" ]; then
		local _rms _rsrc
		IFS='	' read -r _rms _rsrc < "$PF_RUN_DIR/trtt-$ip"
		rm -f "$PF_RUN_DIR/trtt-$ip" 2>/dev/null
		if [ "${_rms:-0}" -gt 0 ] 2>/dev/null; then
			lv=$_rms
			printf '%s\n' "$_rms" >> "$PF_RUN_DIR/.ipr-$ip" 2>/dev/null
			if _pf_reading "$ip" "$_rms" "${_rsrc:-icmp}" 0 1; then
				if [ "$_V" = "blocked" ] && [ "$_V_OLD" = "allowed" ]; then
					pf_note "INFO" "ping filter: blocked $ip on its in-play ping (${_rms}ms via ${_rsrc})"
				elif [ "$_V" = "allowed" ] && [ "$_V_OLD" != "allowed" ]; then
					pf_note "INFO" "ping filter: allowed $ip on its in-play ping (${_rms}ms via ${_rsrc})"
				fi
			fi
		fi
	fi

	# Carry the last jitter / gap between tcpdump windows; refresh when a
	# window lands in stats-<ip>. live.tsv col 9 (loss) is inert: written 0;
	# col 10 = the last in-play reading (-1 none).
	local jit=0 gmax=0 gaps=0
	if [ -f "$PF_LIVE_TSV" ]; then
		set -f; set -- $(awk -F'	' -v ip="$ip" '$1 == ip { print $4, $5, $6, $10; exit }' "$PF_LIVE_TSV" 2>/dev/null); set +f
		jit=${1:-0}; gmax=${2:-0}; gaps=${3:-0}
		[ -n "$lv" ] || lv=${4:-}
	fi
	case "$lv" in ''|*[!0-9]*) lv=-1 ;; esac
	local sfile="$PF_RUN_DIR/stats-$ip" got_window=0
	if [ -s "$sfile" ]; then
		if [ "$steady" = "1" ]; then
			local sj sg sc
			IFS='	' read -r sj sg sc < "$sfile"
			[ -n "$sj" ] && jit="$sj"; [ -n "$sg" ] && gmax="$sg"; [ -n "$sc" ] && gaps="$sc"
			got_window=1
		fi
		# Not steady: the window straddled a start / stop, discard it.
		rm -f "$sfile" 2>/dev/null
	fi

	# Rewrite this server's live.tsv row (drop, append, atomic mv: a
	# pf_servers_json read sees a whole file).
	local tmp="$PF_LIVE_TSV.$$"
	{
		[ -f "$PF_LIVE_TSV" ] && awk -F'	' -v ip="$ip" '$1 != ip' "$PF_LIVE_TSV" 2>/dev/null
		printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s
' "$ip" "$pps" "$bps" "$jit" "$gmax" "$gaps" "$stall" "$now" "0" "$lv"
	} > "$tmp" 2>/dev/null && mv "$tmp" "$PF_LIVE_TSV" 2>/dev/null

	# The last in-play reading (else the measured figure), carried into each
	# ring sample so the graph plots the real probe value. 0 = none yet (the
	# UI falls back per sample).
	local _rttv=0 _rx
	if [ "$lv" -gt 0 ]; then
		_rttv=$lv
	else
		_rx=$(pf_cache_get "$ip")
		if [ -n "$_rx" ]; then
			_pf_row "$_rx"
			_pf_src_measured "$PF_C_SRC" && _rttv=${PF_C_PING:-0}
		fi
	fi
	# Sparkline ring: ts pps bps jit rtt, capped at PF_TELE_RING samples. The
	# in-play readings kept for grading: the last 300 (10 min of play), so
	# the median stays quick.
	local rfile="$PF_TELE_PREFIX$ip"
	printf '%s	%s	%s	%s	%s
' "$now" "$pps" "$bps" "$jit" "$_rttv" >> "$rfile" 2>/dev/null
	if [ "$_trim" = 1 ]; then
		tail -n "${PF_TELE_RING:-120}" "$rfile" > "$rfile.t" 2>/dev/null && mv "$rfile.t" "$rfile" 2>/dev/null
		[ -f "$PF_RUN_DIR/.ipr-$ip" ] && tail -n 300 "$PF_RUN_DIR/.ipr-$ip" > "$rfile.t" 2>/dev/null \
			&& mv "$rfile.t" "$PF_RUN_DIR/.ipr-$ip" 2>/dev/null
	fi

	# --- session accumulation (graded / saved only if >= PF_SESSION_MIN) ---
	# One .acc-<ip> per session in progress. A gap over PF_TELE_GAP starts a
	# new session. Jitter counts once per completed tcpdump window. 10 fields;
	# the a_sbps guard absorbs an older 12-field file across a binary swap.
	local afile="$PF_TELE_ACC_PREFIX$ip"
	local a_since=0 a_last=0 a_njit=0 a_sjit=0 a_mjit=0 a_gaps=0 a_ticks=0 a_stall=0 a_spps=0 a_sbps=0
	[ -f "$afile" ] && IFS=' ' read -r a_since a_last a_njit a_sjit a_mjit a_gaps a_ticks a_stall a_spps a_sbps < "$afile"
	case "$a_sbps" in (''|*[!0-9]*) a_sbps=0 ;; esac
	if [ "${a_since:-0}" -le 0 ] 2>/dev/null || [ "$((now - ${a_last:-0}))" -gt "${PF_TELE_GAP:-20}" ] 2>/dev/null; then
		# Gap = session boundary: FINALIZE the old accumulator, never zero it
		# (a resumed flow or a daemon respawn would wipe a gradeable session).
		# pf_tele_finalize applies PF_SESSION_MIN and folds into history.
		[ -f "$afile" ] && pf_tele_finalize "$ip" end
		a_since=$now; a_njit=0; a_sjit=0; a_mjit=0; a_gaps=0; a_ticks=0; a_stall=0; a_spps=0; a_sbps=0
	fi
	a_last=$now
	# Only MEASURED ticks count: an unmeasured tick (first sighting, dt=0
	# duplicate pass) carries pps=0 as an artefact and would dilute pps_avg
	# until the finalize gameplay gate rejects real matches.
	if [ "$measured" = "1" ]; then
		a_ticks=$((${a_ticks:-0} + 1))
		a_spps=$((${a_spps:-0} + pps)); a_sbps=$((${a_sbps:-0} + bps))
		[ "$stall" = "1" ] && a_stall=$((${a_stall:-0} + 1))
	fi
	if [ "$got_window" = "1" ]; then
		a_njit=$((${a_njit:-0} + 1)); a_sjit=$((${a_sjit:-0} + jit))
		[ "$jit" -gt "${a_mjit:-0}" ] 2>/dev/null && a_mjit="$jit"
		a_gaps=$((${a_gaps:-0} + gaps))
	fi
	printf '%s %s %s %s %s %s %s %s %s %s\n' \
		"$a_since" "$a_last" "$a_njit" "$a_sjit" "$a_mjit" "$a_gaps" "$a_ticks" "$a_stall" "$a_spps" "$a_sbps" \
		> "$afile" 2>/dev/null

	# INCREMENTAL GRADING: once the running session reaches PF_TELE_CKPT
	# (90 s), finalize it as a graded SEGMENT now; the next tick opens a fresh
	# one (a_since doubles as the checkpoint stamp). The ladder fills ~90 s into
	# a match and a restart loses at most one segment. Game end finalizes the
	# rest; a sub-minimum tail is discarded.
	# Fires on EVIDENCE (completed jitter windows, which only spawn at
	# game-rate pps) or wall-clock, whichever first. pf_tele_finalize carries
	# the matching duration-gate escape: the two MUST stay in lockstep.
	if [ $((now - a_since)) -ge "${PF_TELE_CKPT:-90}" ] 2>/dev/null \
	   || [ "${a_njit:-0}" -ge "${PF_TELE_CKPT_WIN:-12}" ] 2>/dev/null; then
		pf_tele_finalize "$ip"
	fi

	# The tap runs while this server is game-rate; .samp-<ip> is the last time
	# it was (what _pf_tap_sweep ends it on). The pps gate keeps matchmaking
	# probes from starting one.
	local samp="$PF_RUN_DIR/.samp-$ip" tapf="$PF_RUN_DIR/.tap-$ip" tp=""
	if [ "${pps:-0}" -ge "${PF_TELE_JIT_MINPPS:-10}" ] 2>/dev/null \
	   && command -v tcpdump >/dev/null 2>&1; then
		echo "$now" > "$samp" 2>/dev/null
		[ -f "$tapf" ] && read -r tp < "$tapf" 2>/dev/null
		if [ -z "$tp" ] || ! kill -0 "$tp" 2>/dev/null; then
			# fd 6 closed (as every fork in a pass): the scan lock ends with it.
			# fd 9 too: the pass's probe FIFO is not the tap's to hold open.
			( _pf_title pf-jitter-tap; pf_udp_tap "$ip" ) </dev/null >/dev/null 2>&1 6>&- 9>&- &
			echo $! > "$tapf" 2>/dev/null
		fi
	fi

	# RTT probe (telemetry, same pps gate, every mode). Result lands in
	# trtt-<ip>, consumed next tick (separate from the classifier's rtt-<ip>).
	local rstamp="$PF_RUN_DIR/.trtt-$ip" last_rtt=0
	[ -f "$rstamp" ] && read -r last_rtt < "$rstamp" 2>/dev/null
	case "$last_rtt" in (''|*[!0-9]*) last_rtt=0 ;; esac
	# In-flight marker: the stamp is written before the backgrounded probe
	# runs, so a slow probe would stack with the next. A staleness reaper (as
	# the UDP sampler) stops a killed probe wedging the gate shut.
	local rrun="$PF_RUN_DIR/.trttrun-$ip" _rt=""
	if [ -f "$rrun" ]; then
		read -r _rt < "$rrun" 2>/dev/null
		case "$_rt" in (''|*[!0-9]*) _rt=$now ;; esac
		[ $((now - _rt)) -gt 20 ] 2>/dev/null && rm -f "$rrun" 2>/dev/null
	fi
	# A server that ignores echo: after 3 silent bursts in a row, probed once
	# a minute (.trttsil-<ip> = silent bursts in a row; an answer clears it).
	local rsil="$PF_RUN_DIR/.trttsil-$ip" _sil=0 _ri="${PF_RTT_INTERVAL:-2}"
	[ -f "$rsil" ] && read -r _sil < "$rsil" 2>/dev/null
	case "$_sil" in (''|*[!0-9]*) _sil=0 ;; esac
	[ "$_sil" -ge 3 ] && _ri=60
	if [ ! -f "$rrun" ] \
	   && [ "${pps:-0}" -ge "${PF_TELE_JIT_MINPPS:-10}" ] 2>/dev/null \
	   && [ "$((now - last_rtt))" -ge "$_ri" ] 2>/dev/null; then
		echo "$now" > "$rstamp" 2>/dev/null
		echo "$now" > "$rrun" 2>/dev/null
		( _pf_title pf-rtt-probe
		  pf_rtt_probe "$ip" > "$PF_RUN_DIR/trtt-$ip" 2>/dev/null
		  if [ -s "$PF_RUN_DIR/trtt-$ip" ]; then rm -f "$rsil"; else echo $((_sil + 1)) > "$rsil"; fi
		  rm -f "$rrun" ) 2>/dev/null 6>&- &
	fi
}

pf_tele_clear() {
	# Idle cleanup keeps the ring and open accumulators (the sweep owns
	# them). "all" (New game, Clear cache, disable) finalizes open sessions,
	# then drops both, and the session guard's stamps and dues. Grades are NOT
	# wiped here (pf_clear_cache and pf_session_reset do); they survive
	# reboots.
	if [ "$1" = "all" ]; then
		pf_tele_finalize_all
		# .rtry- is dropped HERE ONLY: an idle gap must not reset the
		# probe-attempt counter.
		rm -f "$PF_LIVE_TSV" "$PF_RUN_DIR"/.ctr-* "$PF_RUN_DIR"/.samp-* \
			"$PF_RUN_DIR"/stats-* "$PF_RUN_DIR"/tele-* "$PF_TELE_ACC_PREFIX"* \
			"$PF_RUN_DIR"/trtt-* "$PF_RUN_DIR"/.trtt-* "$PF_RUN_DIR"/.trttrun-* \
			"$PF_RUN_DIR"/.trttsil-* "$PF_RUN_DIR"/.samprun-* "$PF_RUN_DIR"/.ipr-* \
			"$PF_RUN_DIR"/.play-* "$PF_RUN_DIR/.sess" "$PF_RUN_DIR"/.due-* "$PF_RUN_DIR"/.slow-* \
			"$PF_RUN_DIR"/.rtry-* "$PF_RUN_DIR"/.sus-* "$PF_RUN_DIR"/.fage-* \
			"$PF_RUN_DIR/.fsweep" 2>/dev/null
	else
		rm -f "$PF_LIVE_TSV" "$PF_RUN_DIR"/.ctr-* "$PF_RUN_DIR"/.samp-* "$PF_RUN_DIR"/.samprun-* \
			"$PF_RUN_DIR"/stats-* "$PF_RUN_DIR"/trtt-* "$PF_RUN_DIR"/.trttrun-* \
			"$PF_RUN_DIR"/.trttsil-* 2>/dev/null
	fi
	return 0
}

pf_telemetry_json() {
	# Sparkline + current live snapshot for one server (UI on-demand).
	local ip="$1"
	[ -n "$ip" ] && [ -n "$(pf_ip_family "$ip")" ] || { printf '{"ip":"","pps":0,"bps":0,"jitter":0,"gap_max":0,"gaps":0,"stall":0,"samples":[]}
'; return; }
	local rfile="$PF_TELE_PREFIX$ip"
	local pps=0 bps=0 jit=0 gmax=0 gaps=0 stall=0
	if [ -f "$PF_LIVE_TSV" ]; then
		set -f; set -- $(awk -F'	' -v ip="$ip" '$1 == ip { print $2, $3, $4, $5, $6, $7; exit }' "$PF_LIVE_TSV" 2>/dev/null); set +f
		pps=${1:-0}; bps=${2:-0}; jit=${3:-0}; gmax=${4:-0}; gaps=${5:-0}; stall=${6:-0}
	fi
	printf '{"ip":"%s","pps":%s,"bps":%s,"jitter":%s,"gap_max":%s,"gaps":%s,"stall":%s,"samples":[' \
		"$ip" "$pps" "$bps" "$jit" "$gmax" "$gaps" "$stall"
	[ -f "$rfile" ] && awk -F'	' 'BEGIN { first = 1 }
		NF >= 4 { if (!first) printf ","; first = 0
			printf "{\"ts\":%d,\"pps\":%d,\"bps\":%d,\"jitter\":%d,\"rtt\":%d}", $1, $2, $3, $4, ($5 + 0) }' "$rfile" 2>/dev/null
	printf ']}
'
}

pf_tele_hist_update() {
	# Fold one finalized session into the per-server aggregate (EWMA 0.6 old
	# / 0.4 new). One row per server, capped at PF_MAX_SERVERS.
	# Schema: ip sessions dur_total jit_ewma jit_max loss_ewma gaps_total stalls_total pps_avg last_ts
	# loss_ewma (col 6) stays in the on-disk schema for LuCI; always 0.
	local ip="$1" dur="$2" jit="$3" jmax="$4" gaps="$5" stalls="$6" pps="$7"
	[ -z "$ip" ] && return 0
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	[ -f "$PF_TELE_HIST" ] || : > "$PF_TELE_HIST"
	# Locked: ungrade / forget rewrite this file, and an unlocked fold
	# mid-rewrite would put a removed grade back.
	local now tmp _lk; now=$(date +%s); tmp="$PF_TELE_HIST.$$"
	_pf_side_lock
	awk -F'	' -v ip="$ip" -v dur="$dur" -v jit="$jit" -v jmax="$jmax" \
	    -v gaps="$gaps" -v stalls="$stalls" -v pps="$pps" -v now="$now" \
	    -v ref="${PF_TELE_EWMA_REF:-90}" '
		BEGIN {
			OFS = "	"; found = 0
			# DURATION-WEIGHTED ALPHA: 0.4 x dur / ref holds the time
			# constant at ref / 0.4 (225 s) for any segment length, so
			# checkpoint tuning never retunes grading. Clamped both ends: a
			# floor so a tiny tail still nudges, a ceiling so one long
			# sweep-finalized session cannot overwrite history.
			if (ref + 0 <= 0) ref = 90
			alpha = 0.4 * (dur + 0) / (ref + 0)
			if (alpha > 0.5)  alpha = 0.5
			if (alpha < 0.05) alpha = 0.05
			keep = 1 - alpha
		}
		$1 == ip {
			found = 1
			sess = $2 + 1; dt = $3 + dur
			je = int($4 * keep + jit  * alpha + 0.5)
			jm = ($5 + 0 > jmax) ? $5 + 0 : jmax
			le = 0
			gt = $7 + gaps; st = $8 + stalls
			pa = int($9 * keep + pps  * alpha + 0.5)
			print ip, sess, dt, je, jm, le, gt, st, pa, now
			next
		}
		{ print }
		END { if (!found) print ip, 1, dur, jit, jmax, 0, gaps, stalls, pps, now }
	' "$PF_TELE_HIST" > "$tmp" 2>/dev/null && mv "$tmp" "$PF_TELE_HIST" 2>/dev/null

	local cap="${PF_MAX_SERVERS:-250}" n
	n=$(wc -l < "$PF_TELE_HIST" 2>/dev/null); n=${n:-0}
	if [ "$n" -gt "$((cap + 50))" ] 2>/dev/null; then
		# The cap last played, by a leading age as in pf_prefix_prune; a row
		# with no time is dropped first.
		awk -F'\t' -v now="$now" '{ a = ($10 ~ /^[0-9]+$/) ? now - $10 : 999999999; print a "\t" $0 }' \
			"$PF_TELE_HIST" 2>/dev/null | sort -n | head -n "$cap" | cut -f2- > "$tmp" \
			&& mv "$tmp" "$PF_TELE_HIST" 2>/dev/null
	fi
	_pf_side_unlock
}

# Grade by playing: at the end of a stretch of play on an allowed, unpinned
# server, the median of its in-play readings ($PF_RUN_DIR/.ipr-<ip>):
#   - not carried by its group, and no handshake at or under the limit: it
#     becomes the server's figure (so the figure can rise) and the server is
#     graded again, blocked after the game if over;
#   - carried by its group: over the limit counts a slow session
#     (.slow-<ip>, tmpfs: gone at boot, New game, Clear cache, forget); two
#     make it confirmed over (_pf_classify), blocked after the game. One slow
#     session is not enough.
# Fewer readings than half a session's worth (a lobby burst) grade nothing.
_pf_play_grade() {
	local ip="$1" f="$PF_RUN_DIR/.ipr-$1" m ex s=0 _LIM
	[ -f "$f" ] || return 0
	m=$(awk -v min="$(( ${PF_SESSION_MIN:-60} / (${PF_RTT_INTERVAL:-2} * 2) ))" "$PF_MED_AWK"'{ v[++n] = $1 + 0 } END { if (n && n >= min) print med(v, n) }' "$f" 2>/dev/null)
	rm -f "$f" 2>/dev/null
	[ "${m:-0}" -gt 0 ] 2>/dev/null || return 0
	ex=$(pf_cache_get "$ip")
	[ -n "$ex" ] || return 0
	_pf_row "$ex"
	[ "$PF_C_STATE" = "allowed" ] || return 0
	_pf_lim
	# A handshake at or under the limit stands; with no limit only one on 2+
	# connects does (a one-connect first reply may be server think time --
	# the played median is the better figure).
	[ "$PF_C_SRC" = real ] && [ "${PF_C_PING:-0}" -gt 0 ] 2>/dev/null \
		&& { { [ "$_LIM" -gt 0 ] && [ "$PF_C_PING" -le "$_LIM" ]; } \
		   || { [ "$_LIM" -eq 0 ] && [ "${PF_C_LOSS:-0}" -ge 2 ] 2>/dev/null; }; } && return 0
	# Confirmed over (kept allowed while played): its handshake stands.
	[ "$PF_C_SRC" = real ] && [ "${PF_C_LOSS:-0}" -ge 2 ] 2>/dev/null && return 0
	_pf_classify "$PF_C_PING" "$PF_C_LAT" "$PF_C_LON" "$PF_C_SRC" "$ip" "$PF_C_CO" "$PF_C_LOSS"
	if [ "$_CLG" = 1 ]; then
		[ "$m" -gt "$_LIM" ] || return 0
		[ -f "$PF_RUN_DIR/.slow-$ip" ] && read -r s < "$PF_RUN_DIR/.slow-$ip" 2>/dev/null
		case "$s" in ''|*[!0-9]*) s=0 ;; esac
		s=$((s + 1))
		echo "$s" > "$PF_RUN_DIR/.slow-$ip" 2>/dev/null
		pf_note "INFO" "ping filter: $ip played at ${m}ms, over the limit while its group carries it (slow session $s)"
		[ "$s" -ge 2 ] || return 0
		_pf_verdict "$ip" "$PF_C_PING" "$PF_C_SRC" 1
	else
		_pf_verdict "$ip" "$m" icmp 1
	fi
	pf_note "INFO" "ping filter: $ip graded on its play (${m}ms) -> $_V$([ -f "$PF_RUN_DIR/.due-$ip" ] && echo ", blocked after the game")"
}

pf_tele_finalize() {
	# Close one session (or a checkpoint segment of one): discard if shorter
	# than PF_SESSION_MIN, else fold into history and reflect measured jitter
	# back into the cache row. $2 = end: the stretch of play is over, the
	# server is graded on it (_pf_play_grade).
	local ip="$1"
	[ -z "$ip" ] && return 0
	local afile="$PF_TELE_ACC_PREFIX$ip"
	[ -f "$afile" ] || return 0
	local a_since a_last a_njit a_sjit a_mjit a_gaps a_ticks a_stall a_spps a_sbps
	IFS=' ' read -r a_since a_last a_njit a_sjit a_mjit a_gaps a_ticks a_stall a_spps a_sbps < "$afile"
	case "$a_sbps" in (''|*[!0-9]*) a_sbps=0 ;; esac
	rm -f "$afile" 2>/dev/null
	[ "$2" = end ] && _pf_play_grade "$ip"
	local dur=$(( ${a_last:-0} - ${a_since:-0} ))
	# Duration gate, with an evidence escape: a short segment with a full
	# checkpoint quota of completed jitter windows is still graded. Without
	# it the window checkpoint in pf_tele_poll would consume and discard
	# every segment.
	if [ "$dur" -lt "${PF_SESSION_MIN:-60}" ] 2>/dev/null; then
		[ "${a_njit:-0}" -ge "${PF_TELE_CKPT_WIN:-12}" ] 2>/dev/null || return 0
	fi
	[ "${a_ticks:-0}" -lt 1 ] 2>/dev/null && return 0

	local jit_avg=0 pps_avg=0
	[ "${a_njit:-0}" -gt 0 ] 2>/dev/null && jit_avg=$(( a_sjit / a_njit ))
	pps_avg=$(( a_spps / a_ticks ))
	# GAMEPLAY GATE: only game-rate sessions are graded (presence, idle chat
	# and launcher flows last hours at low rate). Threshold as the UI: half
	# active_pps, floor 5. Completed jitter windows prove game-rate play
	# (>= 10 pps on consecutive ticks), so a session with windows always
	# grades. Rejections are logged (explains an empty ladder).
	local _minpps=$(( ${PF_ACTIVE_PPS:-20} / 2 ))
	[ "$_minpps" -lt 5 ] 2>/dev/null && _minpps=5
	if [ "$pps_avg" -lt "$_minpps" ] 2>/dev/null && [ "${a_njit:-0}" -eq 0 ] 2>/dev/null; then
		msg "ping filter session skipped (not gameplay): $ip dur=${dur}s pps_avg=${pps_avg} (< ${_minpps}) windows=0"
		return 0
	fi
	pf_tele_hist_update "$ip" "$dur" "$jit_avg" "${a_mjit:-0}" "${a_gaps:-0}" "${a_stall:-0}" "$pps_avg"
	msg "ping filter session graded: $ip dur=${dur}s jitter=${jit_avg}ms (n=${a_njit})"
	pf_sess_log "$ip" "${a_since:-0}" "${a_last:-0}" "$dur" "$jit_avg" "${a_gaps:-0}" "$pps_avg"

	# Measured jitter into the cache row (col 11): the display score uses real
	# UDP data. Col 12 (the handshake's connects) is kept.
	local ex
	ex=$(pf_cache_get "$ip")
	if [ -n "$ex" ]; then
		local c_st c_pg c_sr c_la c_lo c_co c_ci c_ls
		_pf_row "$ex"
		c_st=$PF_C_STATE; c_pg=$PF_C_PING; c_sr=$PF_C_SRC; c_la=$PF_C_LAT
		c_lo=$PF_C_LON; c_co=$PF_C_CO; c_ci=$PF_C_CI; c_ls=$PF_C_LAN
		# State passed through unchanged: a manual verdict is never disturbed,
		# but a pinned server still records its jitter.
		pf_cache_upsert "$ip" "$c_st" "$c_pg" "$c_sr" \
			"$c_la" "$c_lo" "$c_co" "$c_ci" "$c_ls" "$jit_avg" ""
		# The /24 memory learns the figure the segment was played on.
		_pf_src_measured "$c_sr" && [ "${c_pg:-0}" -gt 0 ] 2>/dev/null \
			&& _pf_prefix_learn "$ip" "$c_pg" "$c_la" "$c_lo" "$c_co" "$c_ci"
	fi
}

# Add a graded segment to the play history. A segment that starts within 45 s
# of the last line's end on the same server extends that line (a match is
# graded in segments), so one line is one stretch of play. The line carries
# the server's name (owner.tsv).
pf_sess_log() {   # ip start end dur jitter gaps pps
	local ex tmp="$PF_SESS_TSV.$$" _lk gn=""
	ex=$(pf_cache_get "$1")
	[ -s "$PF_OWNER_TSV" ] && gn=$(awk -F'\t' -v ip="$1" '$1 == ip { print $2; exit }' "$PF_OWNER_TSV" 2>/dev/null)
	PF_C_PING=0; PF_C_CO=""; PF_C_CI=""
	[ -n "$ex" ] && _pf_row "$ex"
	[ -f "$PF_SESS_TSV" ] || : > "$PF_SESS_TSV"
	_pf_side_lock
	PF_UP_CO="$PF_C_CO" PF_UP_CI="$PF_C_CI" PF_UP_GN="$gn" awk -F'\t' -v OFS='\t' -v ip="$1" -v st="$2" -v en="$3" \
	    -v dur="$4" -v jit="$5" -v gaps="$6" -v pps="$7" -v ping="${PF_C_PING:-0}" '
		{ L[NR] = $0 }
		END {
			n = NR; m = 0
			if (n > 0) {
				split(L[n], f, "\t")
				if (f[2] == ip && st - f[1] <= 45) {
					d = f[3] + dur
					j = (d > 0) ? int((f[5] * f[3] + jit * dur) / d + 0.5) : jit
					L[n] = en OFS ip OFS d OFS (ping + 0) OFS j OFS (f[6] + gaps) OFS pps OFS f[8] OFS f[9] OFS (f[10] != "" ? f[10] : ENVIRON["PF_UP_GN"])
					m = 1
				}
			}
			if (!m) L[++n] = en OFS ip OFS dur OFS (ping + 0) OFS jit OFS gaps OFS pps OFS ENVIRON["PF_UP_CO"] OFS ENVIRON["PF_UP_CI"] OFS ENVIRON["PF_UP_GN"]
			for (i = (n > 200 ? n - 199 : 1); i <= n; i++) print L[i]
		}' "$PF_SESS_TSV" > "$tmp" 2>/dev/null && mv "$tmp" "$PF_SESS_TSV" 2>/dev/null
	rm -f "$tmp" 2>/dev/null
	_pf_side_unlock
}

# The play history as JSON, newest first.
pf_sessions_json() {
	printf '{"sessions":['
	[ -s "$PF_SESS_TSV" ] && awk -F'\t' '
		function jesc(s,    o, i, c) {
			gsub(/[\001-\037]/, " ", s); o = ""
			while ((i = match(s, /[\\"]/)) > 0) {
				c = substr(s, i, 1); o = o substr(s, 1, i - 1) "\\" c; s = substr(s, i + 1)
			}
			return o s
		}
		NF >= 7 && $2 ~ /^[0-9A-Fa-f.:]+$/ { L[++n] = $0 }
		END {
			for (i = n; i >= 1; i--) {
				split(L[i], f, "\t")
				printf "%s{\"ts\":%d,\"ip\":\"%s\",\"dur\":%d,\"ping\":%d,\"jitter\":%d,\"gaps\":%d,\"pps\":%d,\"country\":\"%s\",\"city\":\"%s\",\"gname\":\"%s\"}",
					(i < n ? "," : ""), f[1], f[2], f[3], f[4], f[5], f[6], f[7], jesc(f[8]), jesc(f[9]), jesc(f[10])
			}
		}' "$PF_SESS_TSV" 2>/dev/null
	printf ']}\n'
}

pf_tele_sweep() {
	# Finalize sessions whose flow has been idle >= PF_TELE_FINALIZE. Runs
	# every scan tick (active and idle) so a quit game is graded promptly.
	[ "${PF_TELEMETRY:-1}" = "1" ] || return 0
	local f ip last now; now=$(date +%s)
	_pf_tap_sweep "$now"
	for f in "$PF_TELE_ACC_PREFIX"*; do
		[ -f "$f" ] || continue
		last=$(awk '{print $2; exit}' "$f" 2>/dev/null)
		if [ "$((now - ${last:-0}))" -ge "${PF_TELE_FINALIZE:-45}" ] 2>/dev/null; then
			ip=${f##*/}; ip=${ip#.acc-}
			pf_tele_finalize "$ip" end
		fi
	done
}

pf_tele_finalize_all() {
	# Force-close every in-progress session (PF stop / disable) so nothing is
	# lost; pf_tele_finalize still discards sub-PF_SESSION_MIN flows. A
	# server still in session (a restart mid-match) is not graded: its
	# readings carry into the resumed stretch.
	local f ip
	for f in "$PF_TELE_ACC_PREFIX"*; do
		[ -f "$f" ] || continue
		ip=${f##*/}; ip=${ip#.acc-}
		if _pf_in_session "$ip"; then pf_tele_finalize "$ip"; else pf_tele_finalize "$ip" end; fi
	done
}

pf_discover_flows() {
	[ -z "$GAMING_IP4" ] && [ -z "$GAMING_IP6" ] && return 0

	if nft list set $PF_FW_TABLE $PF_SEEN_SET_NAME >/dev/null 2>&1; then
		local seen_f="$PF_RUN_DIR/.seen.dump.$$"
		local enrich_f="$PF_RUN_DIR/.seen.lansrc.$$"
		pf_seen_dump > "$seen_f" 2>/dev/null
		if [ ! -s "$seen_f" ]; then
			rm -f "$seen_f" 2>/dev/null
			return 0
		fi
		# dst -> lan_src enrichment map (best effort; offloaded or expired
		# conntrack entries simply yield an empty lan_src).
		if [ "${PF_CT_FRESH:-0}" = 1 ]; then
			cut -f1,2 "$PF_CT_DST" 2>/dev/null | sort -u > "$enrich_f"
		else
			awk -v gips="$GAMING_IP4" '
			BEGIN { n = split(gips, A, /[ \t]+/); for (i = 1; i <= n; i++) if (A[i] != "") G[A[i]] = 1 }
			{
				src = ""; dst = ""
				for (i = 1; i <= NF; i++) {
					if      (src == "" && substr($i, 1, 4) == "src=") src = substr($i, 5)
					else if (dst == "" && substr($i, 1, 4) == "dst=") dst = substr($i, 5)
				}
				if (src in G && dst != "") print dst "\t" src
			}' "$PF_CT_PROC" 2>/dev/null | sort -u > "$enrich_f"
		fi
		awk -F'\t' -v OFS='\t' -v ef="$enrich_f" '
			# Enrichment is loaded in BEGIN via getline: the usual NR==FNR
			# two-file idiom silently eats EVERY record of the second file
			# when the first one is empty (NR==FNR stays true), and an empty
			# map is the COMMON case here (offloaded/expired conntrack).
			BEGIN {
				while ((getline l < ef) > 0) {
					n = split(l, a, "\t")
					if (n >= 2 && a[1] != "") L[a[1]] = a[2]
				}
				close(ef)
			}
			# col1 must NEVER be empty: tab is IFS whitespace, so a leading
			# empty field would be silently dropped by the consumer read and
			# shift every column left. "-" = lan device unknown.
			{ print ($1 in L && L[$1] != "" ? L[$1] : "-"), $1, 0, "udp", $2 }
		' "$seen_f"
		rm -f "$seen_f" "$enrich_f" 2>/dev/null
		# IPv6 discovered servers (no conntrack enrichment — lan_src shown as "-").
		if nft list set $PF_FW_TABLE $PF_SEEN_SET_NAME6 >/dev/null 2>&1; then
			_pf_set_dump "$PF_SEEN_SET_NAME6" age "${PF_SEEN_TIMEOUT:-600}" \
				| awk -F'\t' '$1 != "" { print "-\t" $1 "\t0\tudp\t" $2 }'
		fi
		return 0
	fi

	return 0
}

# Great-circle km, the one copy every awk program here splices in.
PF_HAV_AWK='
	function hav(a1, o1, a2, o2,    r, x) {
		r = 3.14159265358979 / 180
		x = sin((a2 - a1) * r / 2) ^ 2 + cos(a1 * r) * cos(a2 * r) * sin((o2 - o1) * r / 2) ^ 2
		if (x < 0) x = 0
		if (x > 1) x = 1
		return 2 * 6371 * atan2(sqrt(x), sqrt(1 - x))
	}'

# Known = both set and not both zero (0/0 marks a failed lookup). Fork-free
# (several times per flow per tick); values are plain decimals (_pf_dec_ok at
# write), so "has a non-zero digit" is awk's `$1 + 0 != 0`.
_pf_geo_known() {
	[ -n "$1" ] && [ -n "$2" ] || return 1
	case "$1$2" in *[1-9]*) return 0 ;; esac
	return 1
}

# The distance model (_pf_geo_est): great-circle km -> a ROUGH RTT.
#   ms = dist_base_ms + km * dist_slope_us / 1000
# Past a few thousand km distance stops predicting RTT: paths differ in
# stretch (routed via another coast, or a direct cable), so no straight line
# fits every route. The slope (18 us/km) centres the error on long-haul paths
# and is UCI-tunable; it overshoots short and direct routes. Only ever the
# fallback behind a measurement.

# Heal cached rows whose geo never resolved (0/0) or that lack both country
# and city: the flow loop only retries live servers, and in distance mode
# unresolved means blocked. At most $1 lookups per call (default 2), from the
# IDLE scan only. Rows with a fresh negative-cache entry are skipped, so one
# unresolvable IP cannot starve the rest. A healed row is re-graded and
# seeded. Pinned IPs (whitelist / blacklist) go FIRST, so they can be mapped
# (pf_servers_json joins them against $PF_GEO_CACHE); skipped once located,
# never graded (the pin is the verdict).
pf_geo_backfill() {
	local max="${1:-${PF_GEO_PER_PASS:-2}}"
	[ "${PF_GEOIP_LOOKUP:-yes}" = "yes" ] || return 0
	# Pinned IPs alone are a valid backlog (a manual list, empty servers.tsv).
	local pinned
	pinned=$(printf '%s %s' "$PF_WHITELIST" "$PF_BLACKLIST")
	[ -s "$PF_SERVERS_TSV" ] || [ -n "${pinned# }" ] || return 0
	[ -f "$PF_SERVERS_TSV" ] || : > "$PF_SERVERS_TSV"
	[ -f "$PF_GEO_CACHE" ] || : > "$PF_GEO_CACHE"
	local todo
	todo=$(awk -F'\t' -v now="$(date +%s)" -v pin="$pinned" \
	    -v gf="$PF_GEO_CACHE" '
		# NOT NR == FNR: when the geo cache is EMPTY (fresh install, or
		# right after Clear cache) it yields zero records, NR and FNR stay
		# equal for the whole of servers.tsv, and the entire backlog is
		# silently swallowed by this branch -- pf_geo_backfill then does
		# nothing on exactly the boot where it is needed most. Test the
		# filename instead; it does not depend on record counts.
		FILENAME == gf {
			if (($2 == "0" || $2 == "") && ($3 == "0" || $3 == "") \
			    && (now - $6) < 600) NEG[$1] = 1
			if ($2 != "" && $2 != "0" && $3 != "" && $3 != "0") GOOD[$1] = 1
			next
		}
		($5 == "" || $5 == "0" || $6 == "" || $6 == "0") || ($7 == "" && $8 == "") {
			if (!($1 in NEG) && !($1 in TQS)) { TQS[$1] = 1; TQ[++tn] = $1 }
		}
		END {
			np = split(pin, PA, /[ \t\n]+/)
			for (i = 1; i <= np; i++) {
				ip = PA[i]
				if (ip == "" || ip in NEG || ip in GOOD || ip in OUT) continue
				OUT[ip] = 1; print ip
			}
			for (i = 1; i <= tn; i++) {
				ip = TQ[i]
				if (ip in OUT) continue
				OUT[ip] = 1; print ip
			}
		}
	' "$PF_GEO_CACHE" "$PF_SERVERS_TSV" 2>/dev/null | head -"$max")
	[ -z "$todo" ] && return 0
	local ip
	for ip in $todo; do _pf_geo_heal "$ip"; done
}

# Apply one server's location (the geo cache, else a network lookup paced at
# 2 s: the scan calls it once the worker has cached it, the idle backfill
# looks up itself). An unmeasured row takes its estimate; the row is graded
# again on the shared path (a pin keeps its state, a measured allow is not
# cut, an estimate allow in a match is blocked after it).
_pf_geo_heal() {
	local ip="$1" geo lat lon country city row ping src
	geo=$(pf_geo_lookup "$ip")
	[ -z "$geo" ] && return 0
	_pf_geo4 "$geo"
	lat=$PF_R_LAT; lon=$PF_R_LON; country=$PF_R_CO; city=$PF_R_CI
	_pf_geo_known "$lat" "$lon" || return 0
	_pf_prefix_geo "$ip" "$lat" "$lon" "$country" "$city"
	row=$(pf_cache_get "$ip")
	if [ -z "$row" ]; then
		# Pinned IP with no row: the geo cache now holds it, so the map can
		# plot it. Nothing to grade.
		msg "ping filter: geo resolved pinned $ip (${country:-?}${city:+/$city})"
		return 0
	fi
	_pf_row "$row"
	ping=$PF_C_PING; src=$PF_C_SRC
	# Coordinates without locality: keep what the row had.
	[ -z "$country" ] && country=$PF_C_CO
	[ -z "$city" ]    && city=$PF_C_CI
	if ! _pf_src_measured "$src" || ! [ "$ping" -gt 0 ] 2>/dev/null; then
		_pf_estimate "$ip" "$lat" "$lon"
		[ "$PF_E_MS" -gt 0 ] 2>/dev/null && { ping=$PF_E_MS; src=$PF_E_SRC; }
	fi
	_pf_verdict "$ip" "$ping" "$src" 1 "$lat" "$lon" "$country" "$city"
	[ "$2" = "quiet" ] || msg "ping filter: geo backfilled $ip -> $_V (${country:-?}${city:+/$city})"
}

# Network lookups off the scan: one worker at a time (flock fd 5) takes the
# IPs it is handed, rows with no figure yet first, asks one batch request
# where the service has one, then each in turn (paced in pf_geo_lookup), and
# fills the geo cache. A later pass reads the locations from there.
_pf_geo_worker() {
	[ "$PF_GEOIP_LOOKUP" = "yes" ] || return 0
	# shellcheck disable=SC2086
	set -- $1
	[ $# -gt 0 ] || return 0
	_pf_geo_down && return 0
	# shellcheck disable=SC2046
	[ -s "$PF_SERVERS_TSV" ] && set -- $(awk -F'\t' -v q="$*" '
		BEGIN { n = split(q, Q, " ") }
		{ S[$1] = $4 }
		END { for (i = 1; i <= n; i++) if (S[Q[i]] == "pending") printf "%s ", Q[i]
		      for (i = 1; i <= n; i++) if (S[Q[i]] != "pending") printf "%s ", Q[i] }' \
		"$PF_SERVERS_TSV" 2>/dev/null)
	( _pf_title pf-geo
	  _pf_flock 5 "$PF_RUN_DIR/.lock-geo" 0 || exit 0
	  pf_geo_batch "$@"
	  for _ip in "$@"; do pf_geo_lookup "$_ip" >/dev/null; done
	) </dev/null >/dev/null 2>&1 6>&- 7>&- 9>&- &
}
# No location can come for $1: lookups off or down, or its lookup failed
# within geo_retry.
_pf_geo_nofix() {
	[ "$PF_GEOIP_LOOKUP" = "yes" ] || return 0
	_pf_geo_down && return 0
	_pf_geo_fresh "$1" && ! _pf_geo_known "$PF_G_LAT" "$PF_G_LON"
}

# Inside the radius? 0 = inside, 1 = outside, 2 = not known. Inside: the
# /24's physics bound (its lowest measured RTT x 100 km, fibre both ways)
# within the radius, whatever the location says (mislocated cloud and anycast
# addresses), or located within it. A bound outside proves nothing. One awk
# the first time per server and location; the answers are kept in _PF_IRM
# (" ip|lat|lon|r") until the home, the radius or the /24 memory change
# (pf_load_config, which the daemon runs at least once a minute, and
# _pf_prefix_learn / _forget).
_PF_IRM=""
_pf_in_radius() {   # ip lat lon
	local la="$2" lo="$3" k r
	[ -n "$PF_HOME_LAT" ] && [ -n "$PF_HOME_LON" ] && _pf_geo_known "$la" "$lo" || { la=""; lo=""; }
	k=" $1|$la|$lo|"
	case "$_PF_IRM" in *"$k"*) ;; *) _pf_ir_fill "" "$1|$la|$lo" ;; esac
	case "$_PF_IRM" in *"$k"*) r=${_PF_IRM#*"$k"}; return "${r%% *}" ;; esac
	return 2
}
# _pf_ir_fill <servers file> [ip|lat|lon]: the answers for every row of the
# file and the one asked, into _PF_IRM, in one awk.
_pf_ir_fill() {
	local f=/dev/null
	[ "${PF_PREFIX_TTL:-0}" -gt 0 ] 2>/dev/null && [ -s "$PF_PREFIX_TSV" ] && f=$PF_PREFIX_TSV
	_PF_IRM=$_PF_IRM$(awk -F'\t' -v pf="$f" -v q="$2" -v hla="$PF_HOME_LAT" -v hlo="$PF_HOME_LON" \
	    -v rad="${PF_HOME_RADIUS_KM:-1000}" -v now="${PF_NOW:-$(date +%s)}" -v ttl="${PF_PREFIX_TTL:-0}" "$PF_HAV_AWK"'
		function ir(ip, la, lo,    p) {
			if (hla == "" || hlo == "" || la == "" || lo == "" || (la lo) !~ /[1-9]/) { la = ""; lo = "" }
			p = ip; sub(/\.[0-9]+$/, "", p)
			printf " %s|%s|%s|%d", ip, la, lo, (ip !~ /:/ && (p in B)) ? 0 : (la == "" ? 2 : (int(hav(hla, hlo, la, lo) + 0.5) <= rad + 0 ? 0 : 1))
		}
		FILENAME == pf { if ((now - $9) < ttl + 0 && $4 + 0 > 0 && $4 + 0 <= rad + 0) B[$1] = 1; next }
		$1 != "" { ir($1, $5, $6) }
		END { if (q != "") { split(q, a, "|"); ir(a[1], a[2], a[3]) } }' "$f" ${1:+"$1"} 2>/dev/null)
}

# _pf_classify <rtt> <lat> <lon> <src> <ip> <country> <connects>: the verdict
# into _CL, in this shell (no fork per server in ping mode). rtt = the row's
# figure: its own reading (src icmp|real), else its estimate, else -1 (none);
# connects = its handshake's (servers.tsv col 12). Confirmed over = a
# handshake over the limit on 2+ connects. _CLG = 1: its group allowed it.
#   - every mode: a known country not on allow_country is blocked;
#   - ping: limit 0 (watch only) allows; confirmed over blocks; a figure at
#     or under the limit allows, over it blocks; no figure: allowed until
#     graded;
#   - distance (the radius): inside allowed, located outside blocked; not
#     located: held until it is, or, when no location can come
#     (_pf_geo_nofix), its own reading against the radius in ms (the link's
#     km -> ms model, _pf_geo_est);
#   - distance + Ping Catch (the radius lets servers in, the catch adds
#     those outside it that measure at or under it): inside allowed; own
#     reading at or under the catch allowed; confirmed over blocked, as is
#     one over the catch on 2 stretches of play while its group carried it
#     (.slow-<ip>); then its group (_pf_area_verdict) allows or blocks; not
#     located with a lookup still to come: allowed until it is; then its
#     figure decides; no figure: allowed until graded.
# "Allowed until graded" with no figure waits under the hold (_pf_put).
_pf_classify() {
	_CL=""; _CLG=0
	local rtt="$1" lat="$2" lon="$3" src="$4" ip="$5" n="${7:-0}" own=0 cov=0 ir s=""
	case "$rtt" in (''|*[!0-9-]*) rtt="-1" ;; esac
	case "$n" in (''|*[!0-9]*) n=0 ;; esac

	# REGION LOCK ($6 = country): a known country not on allow_country is out,
	# whatever its ping. An unknown one is graded below and judged again when
	# located.
	if [ -n "$PF_COUNTRIES" ] && [ -n "$6" ]; then
		case "|$PF_COUNTRIES|" in *"|$6|"*) ;; *) _CL=blocked; return ;; esac
	fi
	_pf_src_measured "$src" && [ "$rtt" -gt 0 ] 2>/dev/null && own=1
	_pf_lim
	[ "$own" = 1 ] && [ "$src" = real ] && [ "$n" -ge 2 ] && [ "$rtt" -gt "$_LIM" ] && cov=1

	if [ "${PF_BLOCK_MODE:-ping}" = "distance" ]; then
		# Inside the radius and an own reading at or under the catch both
		# allow: the test that costs nothing goes first.
		[ "$_LIM" -gt 0 ] && [ "$own" = 1 ] && [ "$rtt" -le "$_LIM" ] && { _CL=allowed; return; }
		_pf_in_radius "$ip" "$lat" "$lon"; ir=$?
		[ "$ir" = 0 ] && { _CL=allowed; return; }
		if [ "$_LIM" -eq 0 ]; then
			# The radius alone. No location can come: its own reading,
			# within the radius in ms.
			if [ "$ir" = 2 ] && [ "$own" = 1 ] && [ -n "$ip" ] && _pf_geo_nofix "$ip"; then
				s=$(_pf_geo_est "$PF_HOME_LAT" "$PF_HOME_LON" "${PF_HOME_RADIUS_KM:-1000}")
				[ "$rtt" -le "${s%% *}" ] 2>/dev/null && { _CL=allowed; return; }
			fi
			_CL=blocked; return
		fi
		[ -n "$ip" ] && [ -f "$PF_RUN_DIR/.slow-$ip" ] && read -r s < "$PF_RUN_DIR/.slow-$ip" 2>/dev/null
		{ [ "$cov" = 1 ] || [ "${s:-0}" -ge 2 ] 2>/dev/null; } && { _CL=blocked; return; }
		if [ -n "$ip" ]; then
			_pf_area_verdict "$ip" "$lat" "$lon"
			[ "$_AV" = allowed ] && _CLG=1
			[ -n "$_AV" ] && { _CL=$_AV; return; }
		fi
		[ "$ir" = 2 ] && [ -n "$ip" ] && ! _pf_geo_nofix "$ip" && { _CL=allowed; return; }
	else
		[ "$_LIM" -gt 0 ] || { _CL=allowed; return; }
		[ "$cov" = 1 ] && { _CL=blocked; return; }
	fi
	# Its figure, own else estimate; none: allowed until graded.
	if [ "$rtt" -gt 0 ] 2>/dev/null && [ "$rtt" -gt "$_LIM" ]; then
		_CL=blocked
	else
		_CL=allowed
	fi
}

# --- one verdict path ---------------------------------------------------------
# Every figure that arrives for a server -- the scan's, an ICMP reading, a
# handshake RTT, a location, the ping during play -- and the end of a match
# are decided here, so the rules are written once:
#   - a pin keeps its list state (its figure is still recorded);
#   - with keep = 1 an allow the figure would block stays allowed while the
#     server is in session, and is blocked after it (_pf_defer); so does a
#     new row in session (a handoff) where its mode lets a server with no
#     figure in; a change the user makes from the live controls
#     (PF_USER_NOW=1) is not kept;
#   - otherwise the figure decides.
# _pf_decide <ip> <old state> <ping> <src> <lat> <lon> <country> <connects>
# <keep>: the state into _V. No I/O but the due stamp.
_pf_decide() {
	case "$2" in whitelist|blacklist) _V=$2; return 0 ;; esac
	_pf_classify "$3" "$5" "$6" "$4" "$1" "$7" "$8"; _V=$_CL
	[ "$_V" = blocked ] && [ "$9" = 1 ] && [ "${PF_USER_NOW:-0}" != 1 ] || return 0
	if [ -z "$2" ]; then
		_pf_in_session "$1" || return 0
		_pf_classify -1 "$5" "$6" pending "$1" "$7" 0
		[ "$_CL" = allowed ] || return 0
	elif [ "$2" != allowed ]; then return 0; fi
	_pf_defer "$1" && _V=allowed
	return 0
}
# An allow with no figure yet waits in neither set (_pf_put, reclassify)
# while a hold rule is in and something can still grade it: its first
# packets pass (first), or a location may come (full, lookups on).
_pf_hold_nofig() {
	_pf_hold_on && { [ "$_HOLD" = first ] || [ "$PF_GEOIP_LOOKUP" = yes ]; }
}
# _pf_keep_in <ip>: 0 = such an allow that is in @ping_allowed and being
# played stays there (a hold that comes in is not a cut; the user's own
# change is). One nft call per server until this process has put it held or
# kept (PF_PUTS is emptied when another process changes the sets).
_pf_keep_in() {
	case " $PF_PUTS " in
		*" $1=h@"*) return 1 ;;
		*" $1=a0@"*) [ "${PF_USER_NOW:-0}" != 1 ] && _pf_in_session "$1"; return ;;
	esac
	# shellcheck disable=SC2086 # PF_FW_TABLE is "family table"
	[ "${PF_USER_NOW:-0}" != 1 ] && _pf_in_session "$1" \
		&& nft get element $PF_FW_TABLE $PF_ALLOWED_SET_NAME "{ $1 }" >/dev/null 2>&1
}
# _pf_put <ip> <state> <src> <ping>: the kernel verdict, when it changed or is
# a minute old (_pf_put_due). A measured allow gets the long timeout. Pins
# are put by the list code. An allow with no figure yet is in neither set
# while it is held (_pf_hold_nofig): its first packets pass, the rest wait
# to be graded.
_pf_put() {
	case "$2" in
		allowed) if _pf_src_measured "$3"; then _pf_put_due "$1" a2 && pf_allow_add "$1" 2
		         elif ! [ "${4:-0}" -gt 0 ] 2>/dev/null && _pf_hold_nofig && ! _pf_keep_in "$1"; then
		             _pf_put_due "$1" h && { pf_allow_del "$1"; _pf_put_mark "$1" h; }
		         else _pf_put_due "$1" a0 && pf_allow_add "$1"; fi ;;
		blocked) _pf_put_due "$1" b0 && pf_block_add "$1" ;;
	esac
	return 0
}
# _pf_verdict <ip> <ping> <src> <keep> [lat lon country city]: a figure (and,
# given, a location) for a server that has a row: decided, written, put.
# _V_OLD = the state before, _V the state now; 1 = no row. A handshake figure
# keeps the row's connects (col 12; _pf_reading passes new ones in PF_HSN);
# any other figure has none.
_pf_verdict() {
	local ip="$1" pg="$2" sr="$3" ex st0 lan la lo co ci n
	_V=""; _V_OLD=""
	ex=$(pf_cache_get "$ip")
	[ -n "$ex" ] || return 1
	_pf_row "$ex"
	st0=$PF_C_STATE; lan=$PF_C_LAN; n=${PF_HSN:-$PF_C_LOSS}
	[ "$sr" = real ] || n=0
	if [ $# -ge 8 ]; then
		la=$5; lo=$6; co=$7; ci=$8
	else
		la=$PF_C_LAT; lo=$PF_C_LON; co=$PF_C_CO; ci=$PF_C_CI
	fi
	_V_OLD=$st0
	_pf_decide "$ip" "$st0" "$pg" "$sr" "$la" "$lo" "$co" "$n" "$4"
	pf_cache_upsert "$ip" "$_V" "$pg" "$sr" "$la" "$lo" "$co" "$ci" "$lan" "" "$n"
	_pf_put "$ip" "$_V" "$sr" "$pg"
	return 0
}

# Apply every finished probe (rtt-<ip>) to its row and the kernel sets. Runs
# from pf_scan_once (reads its $now) at the top of a pass AND as each probe
# of the batch lands, so a first-sight reading decides in the SAME pass. A
# Re-check cache reading (5th field "fresh") is the user's: it may raise an
# ICMP figure and lands at once.
_pf_rtt_ingest() {
	local rtt_file ip rtt rsrc ex keep PF_SUS=1
	for rtt_file in "$PF_RUN_DIR"/rtt-*; do
		[ -f "$rtt_file" ] || continue
		ip=${rtt_file##*/rtt-}; rtt=""
		read -r rtt < "$rtt_file" 2>/dev/null
		rm -f "$rtt_file" 2>/dev/null
		[ -n "$ip" ] && [ -n "$rtt" ] || continue
		# "avg jitter loss icmp [fresh]": only the RTT is used. ICMP loss at
		# small counts quantises to 0/33/67% and ICMP jitter measures the
		# probe path, not the game stream; col 11 comes from the tcpdump tap.
		# No 4th field (an older file) reads as real: measured, not demoted.
		# shellcheck disable=SC2086
		set -- $rtt
		rtt=$1; rsrc=${4:-real}; keep=1
		case "$rsrc" in icmp|real) ;; *) rsrc=real ;; esac
		# fresh = a Re-check: the user's own change lands at once (keep 0).
		# "fresh age" = the idle age refresh: replaces the same way, but an
		# automatic re-measure keeps the session guard.
		[ "${5:-}" = fresh ] && [ "${6:-}" != age ] && keep=0
		if [ "$rtt" -gt 0 ] 2>/dev/null; then
			_pf_reading "$ip" "$rtt" "$rsrc" 0 "$keep" "${5:-}"
			continue
		fi
		# No echo: every unmeasured row, estimates included, is estimated
		# again.
		ex=$(pf_cache_get "$ip")
		[ -n "$ex" ] || continue
		_pf_row "$ex"
		_pf_src_measured "$PF_C_SRC" && continue
		_pf_estimate "$ip" "$PF_C_LAT" "$PF_C_LON"
		# As the scan: an estimate that has gone keeps the last one.
		[ "$PF_E_MS" -gt 0 ] 2>/dev/null || ! [ "$PF_C_PING" -gt 0 ] 2>/dev/null || continue
		_pf_verdict "$ip" "$PF_E_MS" "$PF_E_SRC" 1
	done
}

# " a.b.c d.e.f" -- the IPv4 /24s holding >= $2 entries of list $1.
_pf_pin_areas() {
	[ "${2:-0}" -gt 0 ] 2>/dev/null || return 0
	# shellcheck disable=SC2086
	printf '%s\n' $1 | awk -F. -v m="$2" '
		NF == 4 && $0 !~ /:/ { c[$1 "." $2 "." $3]++ }
		END { for (k in c) if (c[k] >= m) printf " %s", k }'
}

# Ping Catch /24s, kernel only, on the group's counts (_pf_area_verdict) per
# /24: under the catch outnumbering confirmed over (or outside the allowed
# countries) lets its next servers' first packets through (@auto_ok);
# auto_pin or more over and none under, they are dropped (@auto_bad).
# Estimates and pins never count. Worked out again every pass from the
# rows, so a catch change, an age-out or Clear cache moves them; the sets
# are rewritten only when the result changed ($PF_RUN_DIR/.auto24 = what is
# in the kernel).
_pf_auto_nets() {
	local f="$PF_RUN_DIR/.auto24" new="" old="" ok="" bad="" n _LIM
	if [ "${PF_PING_CATCH:-0}" -gt 0 ] 2>/dev/null && [ "${PF_AUTO_PIN:-0}" -gt 0 ] 2>/dev/null \
	   && [ -s "$PF_SERVERS_TSV" ]; then
		_pf_lim
		# "o:a.b.c.0/24 b:d.e.f.0/24 ...", sorted: the same /24s always read
		# the same, whatever order the rows are in.
		new=$(awk -F'\t' -v m="$PF_AUTO_PIN" -v cl="|$PF_COUNTRIES|" -v lim="$_LIM" '
			($2 == "allowed" || $2 == "blocked") && ($4 == "icmp" || $4 == "real") && $3 + 0 > 0 \
			    && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
				p = $1; sub(/\.[0-9]+$/, "", p)
				if (cl != "||" && $7 != "" && !index(cl, "|" $7 "|")) O[p]++
				else if ($3 + 0 <= lim + 0) U[p]++
				else if ($4 == "real" && $12 + 0 >= 2) O[p]++
			}
			END {
				for (p in U) if (!(p in O) || U[p] > O[p]) print "o:" p ".0/24"
				for (p in O) if (O[p] >= m && !(p in U)) print "b:" p ".0/24"
			}' "$PF_SERVERS_TSV" 2>/dev/null | sort | tr '\n' ' ')
		new=${new% }
	fi
	[ -f "$f" ] && read -r old < "$f" 2>/dev/null
	[ "$new" = "$old" ] && return 0
	pf_table_present || return 0
	for n in $new; do
		case "$n" in
			o:*) ok="${ok:+$ok, }${n#o:}" ;;
			b:*) bad="${bad:+$bad, }${n#b:}" ;;
		esac
	done
	n="flush set $PF_FW_TABLE auto_ok; flush set $PF_FW_TABLE auto_bad"
	[ -n "$ok" ] && n="$n; add element $PF_FW_TABLE auto_ok { $ok }"
	[ -n "$bad" ] && n="$n; add element $PF_FW_TABLE auto_bad { $bad }"
	nft "$n" 2>/dev/null || return 0
	if [ -n "$new" ]; then printf '%s\n' "$new" > "$f" 2>/dev/null; else rm -f "$f" 2>/dev/null; fi
	pf_note "INFO" "ping filter: Ping Catch /24s - allowed: ${ok:-none}; blocked: ${bad:-none}"
}

# One background ICMP reading into rtt-<ip>, folded in by _pf_rtt_ingest.
# Counts against the CALLER's _inflight / _n_probe / _pp (ash locals are
# dynamically scoped) and drains at parallel_cap. Drains wait on $_pp only: a
# bare `wait` also waits for every jitter tap and in-play probe.
_pf_probe_async() {
	# pf_scan_once sets _pfd=0: the first launch opens a FIFO on fd 9 and each
	# probe reports its IP when done, so every reading applies as it lands (an
	# echo-silent server does not hold the fast ones). Callers without _pfd
	# never touch fd 9.
	if [ "${_pfd:-}" = 0 ]; then
		_pfd=-
		rm -f "$PF_RUN_DIR/.probe.fifo.$$" 2>/dev/null
		mkfifo "$PF_RUN_DIR/.probe.fifo.$$" 2>/dev/null \
			&& exec 9<>"$PF_RUN_DIR/.probe.fifo.$$" && _pfd=1
		rm -f "$PF_RUN_DIR/.probe.fifo.$$" 2>/dev/null
	fi
	# Staged + renamed: _pf_rtt_ingest may read while probes still write.
	# $2 = age: the age refresh's reading replaces like a Re-check (an ICMP
	# figure may rise or fall) but keeps the session guard (not the user's).
	( _pf_title pf-ping
	  _r=$(pf_ping_stats "$1")
	  case "$2$_r" in age*icmp) _r="$_r fresh age" ;; esac
	  printf '%s\n' "$_r" > "$PF_RUN_DIR/.rtt-$1" 2>/dev/null \
		&& mv -f "$PF_RUN_DIR/.rtt-$1" "$PF_RUN_DIR/rtt-$1" 2>/dev/null
	  [ "$_pfd" = 1 ] && echo "$1" >&9 ) 6>&- &
	_pp="$_pp $!"
	_inflight=$((_inflight + 1)); _n_probe=$((_n_probe + 1))
	if [ "$_inflight" -ge "${PF_PARALLEL_CAP:-20}" ] 2>/dev/null; then
		wait $_pp 2>/dev/null
		_inflight=0; _pp=""
	fi
}

pf_scan_once() {
	[ "$PF_ENABLED" = "1" ] || return 0

	# One timestamp for the pass: the rtt-ingest check runs before the flow
	# loop and must not rely on a caller's $now.
	local now; now=$(date +%s)

	local miss
	miss=$(pf_check_prereqs)
	if [ -n "$miss" ]; then
		local warn_file="$PF_RUN_DIR/.prereq.warned"
		local last_warn=0
		[ -f "$warn_file" ] && last_warn=$(cat "$warn_file" 2>/dev/null)
		if [ "$((now - last_warn))" -ge 60 ] 2>/dev/null; then
			err "ping filter: scan skipped — missing $miss"
			echo "$now" > "$warn_file" 2>/dev/null
		fi
		return 1
	fi

	# One pass at a time: another one running = nothing to do.
	_pf_flock 6 "$PF_RUN_DIR/.lock-scan" 0 || return 0
	# Held by this pass (dynamic scope: pf_reclassify reads it). PF_NOW is
	# the pass's clock for the estimate and session helpers.
	local _PF_SCAN_HELD=1 PF_NOW=$now

	pf_cache_init
	# Another process changed the verdict sets: what this one last put is no
	# longer known to be there.
	if [ -n "$PF_MAIN" ]; then
		local _g=""
		[ -f "$PF_RUN_DIR/.setgen" ] && read -r _g < "$PF_RUN_DIR/.setgen" 2>/dev/null
		# Its change was graded on the config it committed first: read it now,
		# or this pass puts the old config's verdicts back.
		[ "$_g" = "${PF_SETGEN_SEEN:-}" ] || { PF_PUTS=""; PF_SETGEN_SEEN=$_g; pf_load_config 2>/dev/null; }
	fi

	# Kernel upkeep: table present, source set holding the devices, verdict
	# sets not empty while rows exist. A dozen nft calls: the daemon runs it
	# every PF_UPKEEP s and after a config change; a CLI scan always does.
	if [ "${PF_SKIP_UPKEEP:-0}" != 1 ]; then
		pf_table_present || pf_install_fw_rules >/dev/null 2>&1
		pf_seed_gaming_set 2>/dev/null
		pf_sets_self_heal
	fi
	[ "${PF_TELEMETRY:-1}" = "1" ] && pf_tele_sweep

	_pf_rtt_ingest
	_pf_hs_ingest

	local flows
	flows=$(pf_discover_flows)
	if [ -z "$flows" ]; then
		# Idle tick: drain the geo backlog (2 lookups max). Age-refresh
		# probes run without the FIFO; the next pass's ingest takes them.
		local _inflight=0 _n_probe=0 _pp="" _pfd=-
		_pf_fresh_sweep
		pf_geo_backfill "$PF_GEO_PER_PASS"
		pf_cache_age_out
		pf_cache_truncate
		_pf_auto_nets
		pf_tele_clear
		exec 6>&-
		return 0
	fi

	# Only new servers (first, so their probes start first) and known ones
	# with a packet in the last 20 s go to the loop: a row seen earlier in
	# @pf_seen's 10 minutes costs nothing here.
	local flow_data="$PF_RUN_DIR/flows.tmp"
	printf '%s\n' "$flows" | awk -F'\t' -v sf="$PF_SERVERS_TSV" '
		BEGIN { while ((getline l < sf) > 0) { sub(/\t.*/, "", l); K[l] = 1 }; close(sf) }
		$2 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { next }
		!($2 in K) { print; next }
		$5 + 0 <= 20 { L[++n] = $0 }
		END { for (i = 1; i <= n; i++) print L[i] }' > "$flow_data" 2>/dev/null

	now=$(date +%s); PF_NOW=$now
	local n_new=0 n_refresh=0
	# Bound the ICMP fan-out by counting launches: `jobs -p` in a command
	# substitution sees an empty job table under BusyBox ash.
	local _inflight=0 _n_probe=0 _pp="" _pfd=0 _gq=""
	# Live servers: a failed location lookup is tried again after geo_retry
	# seconds, not the idle backlog's 10 minutes (pf_geo_lookup).
	local PF_GEO_NEG="${PF_GEO_RETRY:-60}"
	# Area pinning, computed once per pass from the lists as they stand.
	local _apw _apb _apk _apl _n_pin=0
	_apw=$(_pf_pin_areas "$PF_WHITELIST" "${PF_AUTO_PIN:-0}")
	_apb=$(_pf_pin_areas "$PF_BLACKLIST" "${PF_AUTO_PIN:-0}")

	# The rows this loop writes go to a journal and land in one rewrite after
	# it (pf_cache_upsert, _pf_up_flush); the readings folded after the loop
	# then see them.
	PF_UP_JRN="$PF_RUN_DIR/.upj"; : > "$PF_UP_JRN"; PF_UP_IPS=""
	# f_port/f_proto are positional placeholders: pf_discover_flows emits a
	# fixed 5-column row and read must consume all of it.
	# shellcheck disable=SC2034
	local f_src f_dst f_port f_proto f_bytes
	# shellcheck disable=SC2034
	while IFS='	' read -r f_src f_dst f_port f_proto f_bytes; do
		[ "$f_src" = "-" ] && f_src=""
		pf_valid_ip4 "$f_dst" || continue
		pf_is_private_ip "$f_dst" && continue
		# f_bytes is the @pf_seen age: seconds since the last packet.
		local f_seen
		case "$f_bytes" in (''|*[!0-9]*) f_seen=$now ;; (*) f_seen=$((now - f_bytes)) ;; esac

		# Live telemetry (passive, both modes): sample ANY server exchanging
		# packets now, whatever its grade or listing, before the skips below,
		# so a connected server's sparkline keeps filling. f_bytes is the
		# @pf_seen age (s since the last packet).
		if [ "${PF_TELEMETRY:-1}" = "1" ] && [ "${f_bytes:-999}" -le 20 ] 2>/dev/null; then
			pf_tele_poll "$f_dst"
		fi

		local existing state="" lat="" lon="" country="" city="" prev_ping="0" prev_ping_src="" prev_n=""
		existing=$(pf_cache_get "$f_dst")
		if [ -n "$existing" ]; then
			# Fork-free split (as pf_reclassify): tab is IFS whitespace and
			# collapses, \037 keeps empty fields.
			_pf_row "$existing"
			state=$PF_C_STATE; prev_ping=${PF_C_PING:-0}; prev_ping_src=$PF_C_SRC; prev_n=$PF_C_LOSS
			lat=$PF_C_LAT; lon=$PF_C_LON; country=$PF_C_CO; city=$PF_C_CI
		fi

		# Freshness gate: @pf_seen keeps a server for PF_SEEN_TIMEOUT after its
		# last packet. Only a live sighting refreshes an EXISTING row, or every
		# idle server looks connected. NEW servers are always processed.
		if [ -n "$existing" ] && [ "${f_bytes:-0}" -gt 20 ] 2>/dev/null; then
			continue
		fi

		# Geo UNKNOWN (empty or the stored 0/0): retry (cache-first,
		# negative-cached). Same-/24 location first: no lookup, no pacing, no
		# pending window.
		if ! _pf_geo_known "$lat" "$lon" && _pf_prefix_get "$f_dst" \
		   && _pf_geo_known "$PF_P_LAT" "$PF_P_LON"; then
			lat=$PF_P_LAT; lon=$PF_P_LON
			[ -z "$country" ] && country=$PF_P_CO
			[ -z "$city" ]    && city=$PF_P_CI
		fi
		# Geo cache next; a NETWORK lookup (2 s paced) is queued for after the
		# probes land, so a burst of new servers does not hold every verdict.
		if ! _pf_geo_known "$lat" "$lon"; then
			local geo
			geo=$(pf_geo_cache_get "$f_dst")
			if [ -n "$geo" ]; then
				_pf_geo4 "$geo"
				if _pf_geo_known "$PF_R_LAT" "$PF_R_LON"; then
					lat=$PF_R_LAT; lon=$PF_R_LON
					[ -n "$PF_R_CO" ] && country=$PF_R_CO
					[ -n "$PF_R_CI" ] && city=$PF_R_CI
					_pf_prefix_geo "$f_dst" "$lat" "$lon" "$country" "$city"
				fi
			fi
			if ! _pf_geo_known "$lat" "$lon"; then
				case " $_gq " in *" $f_dst "*) ;; *) _gq="$_gq $f_dst" ;; esac
			fi
		fi

		local is_wl=0 is_bl=0
		_pf_list_state "$f_dst"
		case "$_LS" in whitelist) is_wl=1 ;; blacklist) is_bl=1 ;; esac
		# AREA PIN: an unlisted server in a /24 that already holds auto_pin+
		# hosts of one list puts the /24 on the list (matchmaking endpoints come
		# in blocks). One prefix entry: later servers are covered by
		# _pf_list_state and @wl_net / @bl_net from the first packet. Both lists
		# = ambiguous, graded normally. A real pin: shown and removed as one.
		if [ "$is_wl$is_bl" = "00" ] && [ -n "$_apw$_apb" ]; then
			_apk=${f_dst%.*}
			case "$_apw " in *" $_apk "*) is_wl=1 ;; esac
			case "$_apb " in *" $_apk "*) is_bl=1 ;; esac
			_apl=""
			if [ "$is_wl$is_bl" = "11" ]; then
				is_wl=0; is_bl=0
			elif [ "$is_wl" = "1" ]; then
				_apl=whitelist; PF_WL_NETS="${PF_WL_NETS:+$PF_WL_NETS }$_apk.0/24"
				nft add element $PF_FW_TABLE wl_net "{ $_apk.0/24 }" 2>/dev/null
			elif [ "$is_bl" = "1" ]; then
				_apl=blacklist; PF_BL_NETS="${PF_BL_NETS:+$PF_BL_NETS }$_apk.0/24"
				nft add element $PF_FW_TABLE bl_net "{ $_apk.0/24 }" 2>/dev/null
			fi
			if [ -n "$_apl" ]; then
				uci -q add_list "$UCI_CFG.pingfilter.$_apl=$_apk.0/24"
				_n_pin=$((_n_pin + 1))
				pf_note "INFO" "ping filter: auto-$_apl $_apk.0/24 (${PF_AUTO_PIN}+ of its servers are on the $_apl)"
			fi
		fi

		# A pin fixes the verdict, not the ping: the same value rule as any
		# server (measured > same-/24 > distance > -1 pending) and the same
		# first-sight probe.
		if [ "$is_wl$is_bl" != "00" ]; then
			if ! _pf_src_measured "$prev_ping_src" || ! [ "$prev_ping" -gt 0 ] 2>/dev/null; then
				_pf_estimate "$f_dst" "$lat" "$lon"
				if [ "$PF_E_MS" -gt 0 ] 2>/dev/null || ! [ "$prev_ping" -gt 0 ] 2>/dev/null; then
					prev_ping=$PF_E_MS; prev_ping_src=$PF_E_SRC
				fi
			fi
			if [ "$is_wl" = "1" ]; then
				_apl=whitelist; _pf_put_due "$f_dst" a1 && pf_allow_add "$f_dst" 1
			else
				_apl=blacklist; _pf_put_due "$f_dst" b1 && pf_block_add "$f_dst" 1
			fi
			pf_cache_upsert "$f_dst" "$_apl" "$prev_ping" "${prev_ping_src:-pending}" \
				"$lat" "$lon" "$country" "$city" "$f_src" "" "" "$f_seen"
			[ -z "$existing" ] \
				&& ! _pf_src_measured "$prev_ping_src" && _pf_probe_async "$f_dst"
			n_refresh=$((n_refresh + 1))
			continue
		fi

		local current_ping="$prev_ping" current_src="$prev_ping_src" current_n=""
		local need_icmp=0
		if [ -z "$existing" ]; then
			n_new=$((n_new + 1))
			current_ping=-1; current_src=pending
			need_icmp=1
		else
			# Graded servers are not re-pinged here: each is ICMP-graded at first
			# sight, and the one being played keeps a live RTT via the pps-gated
			# telemetry probe (pf_tele_poll -> trtt).
			:
		fi

		# PING VALUE GUARANTEE: every graded row carries a NUMERIC ping: a real
		# ICMP value when one exists (never overwritten here), else the best
		# estimate, else -1 pending. An unmeasured row is re-estimated on every
		# live sighting.
		if ! _pf_src_measured "$current_src" || ! [ "$current_ping" -gt 0 ] 2>/dev/null; then
			_pf_estimate "$f_dst" "$lat" "$lon"
			if [ "$PF_E_MS" -gt 0 ] 2>/dev/null || ! [ "$current_ping" -gt 0 ] 2>/dev/null; then
				current_ping=$PF_E_MS; current_src=$PF_E_SRC
			fi
		fi
		# A handshake timed before the row existed (the hold let the first
		# exchange through) is folded in before its first verdict.
		if [ -z "$existing" ] && [ -f "$PF_RUN_DIR/hs-$f_dst" ]; then
			local _hm="" _hn=""
			read -r _hm _hn < "$PF_RUN_DIR/hs-$f_dst" 2>/dev/null
			rm -f "$PF_RUN_DIR/hs-$f_dst" 2>/dev/null
			if _pf_fold "$current_ping" "$current_src" 0 "$_hm" real "${_hn:-1}"; then
				current_ping=$_F_MS; current_src=$_F_SRC; current_n=$_F_N
				_pf_prefix_learn "$f_dst" "$_hm" "$lat" "$lon" "$country" "$city"
			fi
		fi

		# RETRY: a row with no measurement (the first-sight probe misses when
		# a block already tore the flow down), or blocked on its own ICMP (an
		# echo the provider slows; a lower one is taken). Paced by
		# recheck_interval, capped by probe_retries, while it is sighted.
		if [ "$need_icmp" = "0" ] && { ! _pf_src_measured "$current_src" \
		   || { [ "$state" = "blocked" ] && [ "$current_src" = "icmp" ]; }; }; then
			local _rf="$PF_RUN_DIR/.rtry-$f_dst" _rts=0 _rn=0
			[ -f "$_rf" ] && read -r _rts _rn < "$_rf" 2>/dev/null
			case "$_rts" in (''|*[!0-9]*) _rts=0 ;; esac
			case "$_rn"  in (''|*[!0-9]*) _rn=0  ;; esac
			if [ "$_rn" -lt "${PF_PROBE_RETRIES:-5}" ] 2>/dev/null \
			   && [ "$((now - _rts))" -ge "${PF_RECHECK_INTERVAL:-30}" ] 2>/dev/null; then
				need_icmp=1
				printf '%s %s\n' "$now" "$((_rn + 1))" > "$_rf" 2>/dev/null
			fi
		fi

		# The shared rules (_pf_decide): an allow is not cut while the server
		# is in session (blocked after it).
		_pf_decide "$f_dst" "$state" "$current_ping" "$current_src" \
			"$lat" "$lon" "$country" "${current_n:-$prev_n}" 1
		state=$_V
		_pf_put "$f_dst" "$state" "$current_src" "$current_ping"
		pf_cache_upsert "$f_dst" "$state" "$current_ping" "$current_src" \
			"$lat" "$lon" "$country" "$city" "$f_src" "" "$current_n" "$f_seen"

		[ "$need_icmp" = "1" ] && _pf_probe_async "$f_dst"

	done < "$flow_data"
	_pf_up_flush; PF_UP_JRN=""
	[ "$_n_pin" -gt 0 ] && uci -q commit "$UCI_CFG"

	# Idle age refresh: its readings land through the same ingest below.
	_pf_fresh_sweep

	# Apply each reading as its probe finishes (FIFO notice), a handshake
	# that landed meanwhile first (a lower one outweighs the echo). read -t
	# bounds a lost notice; the wait reaps the rest (also the no-FIFO path).
	if [ "$_n_probe" -gt 0 ]; then
		if [ "$_pfd" = 1 ]; then
			local _k=0 _ip
			while [ "$_k" -lt "$_n_probe" ] && read -r -t 20 _ip <&9; do
				_k=$((_k + 1))
				_pf_hs_ingest
				_pf_rtt_ingest
			done
		fi
		[ -n "$_pp" ] && wait $_pp 2>/dev/null
		_pf_hs_ingest
		_pf_rtt_ingest
	fi
	[ "$_pfd" = 1 ] && exec 9>&-
	# Handshake readings for rows this pass created.
	_pf_hs_ingest
	# Queued locations: one the cache holds by now is applied (graded on the
	# radius or the estimate, /24 memory located); the rest go to the
	# background worker and are read from the cache on a later pass. The
	# pass never waits on the network.
	local _gi _gw=""
	for _gi in $_gq; do
		if _pf_geo_fresh "$_gi"; then _pf_geo_heal "$_gi" quiet; else _gw="$_gw $_gi"; fi
	done
	_pf_geo_worker "$_gw"

	rm -f "$flow_data" 2>/dev/null
	pf_cache_age_out
	pf_cache_truncate
	_pf_auto_nets

	[ "$n_new$n_refresh" != "00" ] && \
		msg "ping filter scan: new=$n_new refresh=$n_refresh"

	pf_persist_save 0

	exec 6>&-
}

# Is $1 the first column of a line of file $2? (A grep pattern would read
# the dots of an address as "any character".)
_pf_has_ip() {
	awk -F'\t' -v ip="$1" '$1 == ip { f = 1; exit } END { exit !f }' "$2" 2>/dev/null
}

# The scan lock, waited for (a pass is seconds): a reclassify beside a live
# scan dropped the verdicts the scan had just put. Bounded; past the bound
# the caller goes ahead. Never taken by the scan itself
# (pf_sets_self_heal reclassifies from inside one).
_pf_scan_lock_wait() { _pf_flock 6 "$PF_RUN_DIR/.lock-scan" 40; }

pf_reclassify() {
	[ -f "$PF_SERVERS_TSV" ] || return 0
	[ -s "$PF_SERVERS_TSV" ] || return 0
	local _sl=0
	if [ "${_PF_SCAN_HELD:-0}" != 1 ]; then _pf_scan_lock_wait && _sl=1; fi
	pf_reclassify_locked
	[ "$_sl" = 1 ] && exec 6>&-
	return 0
}

pf_reclassify_locked() {
	# One clock for the pass: the estimate and session helpers read it
	# instead of forking date per row.
	local PF_NOW; PF_NOW=$(date +%s)
	pf_tsv_lock || return 1
	local snap="$PF_SERVERS_TSV.rc.snap.$$"
	local tmp="$PF_SERVERS_TSV.rc.$$"
	cp "$PF_SERVERS_TSV" "$snap" 2>/dev/null || { pf_tsv_unlock; return 1; }
	: > "$tmp"
	# Distance: every row's radius test in one awk (_pf_in_radius).
	[ "${PF_BLOCK_MODE:-ping}" = distance ] && _pf_ir_fill "$snap"
	# Verdicts collected per row, applied to BOTH kernel sets in one atomic
	# transaction at the end (no churn, no flush window).
	local want_allow="$PF_RUN_DIR/.rc.want_allow.$$" want_block="$PF_RUN_DIR/.rc.want_block.$$"
	: > "$want_allow"; : > "$want_block"
	# Split on \037 (_pf_row): `IFS=<tab> read` collapses empty fields and
	# shifts columns.
	local _line
	local ip state ping src lat lon country city ts lan_src jit loss new_state
	while IFS= read -r _line; do
		_pf_row "$_line"
		ip=$PF_C_IP; state=$PF_C_STATE; ping=$PF_C_PING; src=$PF_C_SRC; lat=$PF_C_LAT
		lon=$PF_C_LON; country=$PF_C_CO; city=$PF_C_CI; ts=$PF_C_TS; lan_src=$PF_C_LAN
		jit=$PF_C_JIT; loss=$PF_C_LOSS
		[ -z "$ip" ] && continue
		new_state="$state"
		# Every row gets its geo healed and a ping, pins too; only a pin's
		# verdict is left alone.
		{
			# Heal unresolved geo from the cache (cache only: fast, offline). The
			# map already falls back to it, so classification uses the same data.
			if ! _pf_geo_known "$lat" "$lon" || { [ -z "$country" ] && [ -z "$city" ]; }; then
				local g_row g_lat g_lon
				g_row=$(pf_geo_cache_get "$ip")
				if [ -n "$g_row" ]; then
					_pf_geo4 "$g_row"; g_lat=$PF_R_LAT; g_lon=$PF_R_LON
					if _pf_geo_known "$g_lat" "$g_lon"; then
						_pf_geo_known "$lat" "$lon" || { lat="$g_lat"; lon="$g_lon"; }
						[ -z "$country" ] && country=$PF_R_CO
						[ -z "$city" ]    && city=$PF_R_CI
					fi
				fi
			fi
			# Distance mode: a row with no measurement shows the distance
			# ESTIMATE. A measured value is NEVER overwritten by arithmetic, in
			# any mode. The radius verdict reads lat / lon, not the ping column,
			# so this changes what is shown and stored, not what is enforced.
			if [ "${PF_BLOCK_MODE:-ping}" = "distance" ] \
			   && [ -n "$PF_HOME_LAT" ] && [ -n "$PF_HOME_LON" ] && _pf_geo_known "$lat" "$lon"; then
				if _pf_src_measured "$src" && [ "$ping" -gt 0 ] 2>/dev/null; then
					: # real measurement — hands off
				else
					_pf_estimate "$ip" "$lat" "$lon"
					[ "$PF_E_MS" -gt 0 ] 2>/dev/null && { ping=$PF_E_MS; src=$PF_E_SRC; }
				fi
			fi
			# PING VALUE GUARANTEE: a blank, zero or garbage ping becomes the
			# estimate (geo known) or -1 pending. A real value (>0) is untouched.
			if ! [ "$ping" -gt 0 ] 2>/dev/null; then
				_pf_estimate "$ip" "$lat" "$lon"
				ping=$PF_E_MS; src=$PF_E_SRC
			fi
			# Listed (as a host or inside a listed prefix) = that list's
			# state; a row whose listing has gone is graded like any other.
			_pf_list_state "$ip"
			if [ -n "$_LS" ]; then
				new_state=$_LS
			else
				# The shared rules: a server in session is not cut by a
				# re-grade (start, reload, self-heal), only by the user's own
				# change (PF_USER_NOW).
				case "$state" in whitelist|blacklist) state="" ;; esac
				_pf_decide "$ip" "$state" "$ping" "$src" "$lat" "$lon" "$country" "$loss" 1
				new_state=$_V
			fi
		}
		# An allow with no figure waits under the hold: in neither set.
		case "$new_state" in
			whitelist) printf '%s\t1\n' "$ip" >> "$want_allow" ;;
			blacklist) printf '%s\t1\n' "$ip" >> "$want_block" ;;
			allowed)   if _pf_src_measured "$src"; then printf '%s\t2\n' "$ip" >> "$want_allow"
			           elif [ "$ping" -gt 0 ] 2>/dev/null || ! _pf_hold_nofig || _pf_keep_in "$ip"; then printf '%s\t0\n' "$ip" >> "$want_allow"; fi ;;
			blocked)   printf '%s\t0\n' "$ip" >> "$want_block" ;;
		esac
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$ip" "$new_state" "$ping" "$src" \
			"$lat" "$lon" "$country" "$city" "$ts" "$lan_src" "$jit" "$loss" >> "$tmp"
	done < "$snap"
	pf_tsv_replace "$tmp" "$PF_SERVERS_TSV" 50
	rm -f "$snap" 2>/dev/null
	pf_tsv_unlock

	# UCI lists are authoritative even when their rows fell out of the TSV.
	local lip
	for lip in $PF_WHITELIST; do
		[ -z "$lip" ] && continue
		_pf_has_ip "$lip" "$want_allow" || printf '%s\t1\n' "$lip" >> "$want_allow"
	done
	for lip in $PF_BLACKLIST; do
		[ -z "$lip" ] && continue
		_pf_has_ip "$lip" "$want_block" || printf '%s\t1\n' "$lip" >> "$want_block"
	done

	# pf_apply_sets_atomic cuts the conntrack state of every newly blocked IP
	# itself (both directions, per family).
	pf_apply_sets_atomic "$want_allow" "$want_block"
	rm -f "$want_allow" "$want_block" 2>/dev/null
	# A catch or mode change moves the Ping Catch /24s at once.
	_pf_auto_nets
}

# Re-ping every cached IPv4 row (Re-check cache, phase 2). Results land in
# rtt-<ip>, marked fresh: the next scan folds them in (an ICMP figure may
# rise, and it lands at once). Pins are probed too (the verdict is manual,
# the ping is still wanted). Launches counted against parallel_cap.
_pf_reping_cached() {
	local rip rstate _inflight=0
	while IFS="	" read -r rip rstate _; do
		[ -z "$rip" ] && continue
		[ -z "$rstate" ] && continue
		[ "$(pf_ip_family "$rip")" = "v4" ] || continue
		# Staged + renamed (as _pf_probe_async).
		( _pf_title pf-ping; _r=$(pf_ping_stats "$rip")
		  case "$_r" in *icmp) _r="$_r fresh" ;; esac
		  printf '%s\n' "$_r" > "$PF_RUN_DIR/.rtt-$rip.r" 2>/dev/null \
			&& mv -f "$PF_RUN_DIR/.rtt-$rip.r" "$PF_RUN_DIR/rtt-$rip" 2>/dev/null ) &
		_inflight=$((_inflight + 1))
		if [ "$_inflight" -ge "${PF_PARALLEL_CAP:-20}" ] 2>/dev/null; then
			wait
			_inflight=0
		fi
	done < "$PF_SERVERS_TSV"
	wait
}

# Idle age refresh: a measured figure only ever comes DOWN, and a measured
# row is not re-probed -- a route that got worse would read 14 ms forever.
# While nothing is played (a quiet line gives honest echoes) ICMP-measured
# rows whose figure is older than refresh_age get one age-marked probe
# (it may raise or lower the figure; a handshake figure is never touched),
# refresh_per per sweep, the sweep at most once per sus_ttl. .fage-<ip> =
# last probe launch; tmpfs, so the first sweep after a boot only stamps
# (no probe storm) and the first refresh comes refresh_age later. Launch
# counts ride the caller's probe bookkeeping (the pass ingests them).
_pf_fresh_sweep() {
	local g="$PF_RUN_DIR/.fsweep" _n="${PF_NOW:-$(date +%s)}" t="" n=0 ip st pg src rest f ts a=""
	[ "${PF_REFRESH_AGE:-0}" -gt 0 ] 2>/dev/null || return 0
	[ -s "$PF_SERVERS_TSV" ] || return 0
	[ -f "$PF_RUN_DIR/.activity" ] && read -r a _ < "$PF_RUN_DIR/.activity" 2>/dev/null
	[ "$a" = idle ] || return 0
	[ -f "$g" ] && read -r t < "$g" 2>/dev/null
	[ $((_n - ${t:-0})) -lt "${PF_SUS_TTL:-600}" ] 2>/dev/null && return 0
	printf '%s\n' "$_n" > "$g" 2>/dev/null
	while IFS='	' read -r ip st pg src rest; do
		[ "$src" = icmp ] || continue
		pf_valid_ip4 "$ip" || continue
		f="$PF_RUN_DIR/.fage-$ip"
		if [ ! -f "$f" ]; then
			printf '%s\n' "$_n" > "$f" 2>/dev/null
			continue
		fi
		ts=""
		read -r ts < "$f" 2>/dev/null
		[ $((_n - ${ts:-0})) -ge "${PF_REFRESH_AGE:-259200}" ] 2>/dev/null || continue
		printf '%s\n' "$_n" > "$f" 2>/dev/null
		_pf_probe_async "$ip" age
		n=$((n + 1))
		[ "$n" -ge "${PF_REFRESH_PER:-2}" ] && break
	done < "$PF_SERVERS_TSV"
	return 0
}

# Operator wrapper around pf_reclassify: re-grade every cached server against
# the CURRENT limit / mode without live traffic, reconcile the kernel sets (a
# tightened limit cuts live flows), then re-ping to refine. Prints a summary
# for LuCI. The user's own action: no session guard (PF_USER_NOW).
pf_reclassify_now() {
	local PF_USER_NOW=1
	pf_load_config
	if [ "$PF_ENABLED" != "1" ]; then
		echo "Ping filter is disabled — nothing to re-check."
		return 0
	fi
	if [ ! -s "$PF_SERVERS_TSV" ]; then
		echo "No cached servers yet. Play a session so servers get discovered, then re-check."
		return 0
	fi

	local mode="${PF_BLOCK_MODE:-ping}"
	local before="$PF_RUN_DIR/.rc.before.$$"
	local after="$PF_RUN_DIR/.rc.after.$$"

	# Snapshot ip + state, to count what moved.
	awk -F'\t' 'NF>=2 {print $1 "\t" $2}' "$PF_SERVERS_TSV" 2>/dev/null > "$before"

	# Snapshot the enforced set members, to report how many saved servers the
	# rebuild put back (entries expired over an idle gap while rows survived).
	local enf_before="$PF_RUN_DIR/.rc.enf.before.$$"
	local enf_after="$PF_RUN_DIR/.rc.enf.after.$$"
	{ pf_allow_ips; pf_block_ips; } 2>/dev/null | sort -u > "$enf_before"

	# Phase 1: re-grade cached rows, rewrite the TSV, rebuild both sets in one
	# transaction (pins re-seeded in the same commit).
	pf_reclassify

	{ pf_allow_ips; pf_block_ips; } 2>/dev/null | sort -u > "$enf_after"
	local seeded enforced_allow enforced_block
	# awk set-difference: comm is not a default BusyBox applet.
	seeded=$(awk -v f="$enf_before" 'BEGIN { while ((getline l < f) > 0) B[l] = 1; close(f) }
		!($0 in B)' "$enf_after" 2>/dev/null | grep -c .)
	enforced_allow=$(pf_allow_ips 2>/dev/null | grep -c .)
	enforced_block=$(pf_block_ips 2>/dev/null | grep -c .)
	rm -f "$enf_before" "$enf_after" 2>/dev/null

	awk -F'\t' 'NF>=2 {print $1 "\t" $2}' "$PF_SERVERS_TSV" 2>/dev/null > "$after"

	local counts to_allowed to_blocked changed n_total
	n_total=$(wc -l < "$after" 2>/dev/null)
	counts=$(awk -F'\t' '
		NR==FNR { b[$1]=$2; next }
		($1 in b) && b[$1] != $2 {
			if ($2 == "allowed") a++
			else if ($2 == "blocked") k++
		}
		END { printf "%d %d", a+0, k+0 }
	' "$before" "$after")
	to_allowed=${counts% *}
	to_blocked=${counts#* }
	changed=$((to_allowed + to_blocked))
	rm -f "$before" "$after" 2>/dev/null

	# Phase 2: re-ping the cached IPs now (their addresses are known, no live
	# traffic needed). Results land in rtt-<ip>; the next scan folds them in
	# over the estimate, as live discovery does.
	local n_probed _bg=0
	[ -t 1 ] || _bg=1
	n_probed=$(awk -F'\t' '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $2 != "" { c++ } END { print c + 0 }' "$PF_SERVERS_TSV" 2>/dev/null)
	if [ "$_bg" = "1" ]; then
		( _pf_title pf-reping; exec </dev/null >/dev/null 2>&1; _pf_reping_cached ) &
	else
		_pf_reping_cached
	fi

	echo "Re-checked ${n_total:-0} cached servers against current settings."
	echo ""
	echo "  Mode:       $mode"
	if [ "$mode" = "distance" ]; then
		echo "  Radius:     ${PF_HOME_RADIUS_KM:-1000} km"
	else
		echo "  Ping limit: ${PF_THRESHOLD_MS:-?} ms"
	fi
	echo "  Changed:    ${changed} (${to_allowed} now allowed, ${to_blocked} now blocked)"
	echo "  Enforced:   ${enforced_allow:-0} in allowed set, ${enforced_block:-0} in blocked set (live kernel ipsets)."
	if [ "${seeded:-0}" -gt 0 ] 2>/dev/null; then
		echo "  Re-seeded:  ${seeded} saved server(s) restored to the ipsets from the cache."
	fi
	if [ "$_bg" = "1" ]; then
		echo "  Re-pinging: ${n_probed} servers in the background — results fold in over the next scans."
	else
		echo "  Re-pinged:  ${n_probed} servers — fresh ICMP refines on the next scan."
	fi
	if [ "${changed:-0}" -gt 0 ] 2>/dev/null || [ "${seeded:-0}" -gt 0 ] 2>/dev/null; then
		echo ""
		echo "Firewall sets updated from the cache. Any newly-blocked live connections were cut via conntrack."
	fi
}


pf_is_running() {
	[ -f "$PF_PID_FILE" ] || return 1
	# A parked supervised instance is alive but does nothing.
	[ -f "$PF_RUN_DIR/.idle_parked" ] && return 1
	local p
	p=$(cat "$PF_PID_FILE" 2>/dev/null)
	[ -z "$p" ] && return 1
	case "$p" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ -d "/proc/$p" ] || return 1
	local exe
	exe=$(readlink "/proc/$p/exe" 2>/dev/null)
	case "$exe" in
		*busybox*|*/sh|*/ash|*/bash|"") return 0 ;;
		*) return 1 ;;
	esac
}


pf_has_active_traffic() {
	[ -z "$GAMING_IP4" ] && [ -z "$GAMING_IP6" ] && return 1
	[ -r "$PF_CT_PROC" ] || return 1
	# "Active" = a gaming device doing UDP to a destination port >= the floor:
	# the gameplay signature. Background chatter (DNS 53, NTP 123, HTTPS /
	# QUIC 443) does not count. Only the original tuple is read: device as
	# src, the server's game port as dport. To also demand a sustained flow,
	# add `&& assured` (see the commented var).
	awk -v gips="$GAMING_IP4 $GAMING_IP6" -v minport=1024 '
	BEGIN {
		n = split(gips, A, /[ \t]+/)
		for (i = 1; i <= n; i++) if (A[i] != "") G[A[i]] = 1
		found = 0
	}
	{
		is_udp = 0
		for (i = 1; i <= NF; i++) if ($i == "udp") { is_udp = 1; break }
		if (!is_udp) next
		# assured = index($0, "[ASSURED]")   # uncomment + AND below to tighten
		srcip = ""; dport = -1
		for (i = 1; i <= NF; i++) {
			if (srcip == "" && substr($i, 1, 4) == "src=")     srcip = substr($i, 5)
			else if (dport < 0 && substr($i, 1, 6) == "dport=") dport = substr($i, 7) + 0
		}
		if ((srcip in G) && dport >= minport) { found = 1; exit }
	}
	END { exit (found ? 0 : 1) }
	' "$PF_CT_PROC" 2>/dev/null
}

# "Present" = a game is being looked for: a gaming device has a UDP flow to
# a game port (udp_port_min and up). A store download,
# web or video (TCP, or UDP to low ports) is not. Arms the fast cadence so
# the first game packets are graded within seconds.
pf_gaming_presence() {
	[ -z "$GAMING_IP4" ] && [ -z "$GAMING_IP6" ] && return 1
	[ -r "$PF_CT_PROC" ] || return 1
	awk -v gips="$GAMING_IP4 $GAMING_IP6" -v minport="${PF_UDP_PORT_MIN:-1024}" '
	BEGIN {
		n = split(gips, A, /[ \t]+/)
		for (i = 1; i <= n; i++) if (A[i] != "") G[A[i]] = 1
		found = 0
	}
	$0 ~ /(^| )udp / {
		for (i = 1; i <= NF; i++) {
			if (substr($i, 1, 4) == "src=") { if (!(substr($i, 5) in G)) next }
			else if (substr($i, 1, 6) == "dport=") {
				if (substr($i, 7) + 0 >= minport) { found = 1; exit }
				next
			}
		}
	}
	END { exit (found ? 0 : 1) }
	' "$PF_CT_PROC" 2>/dev/null
}

# Sum conntrack packet counters for flows a gaming device opened:
#   field 1 = UDP gameplay-signature flows only (dport >= 1024)
#   field 2 = all protocols (presence)
# Both directions. "-1 -1" when conntrack accounting is off.
# _pf_nft_totals: the same two totals from the table's counters, "udp all",
# or nothing when the table is not there.
_pf_nft_totals() {
	nft list counters table $PF_FW_TABLE 2>/dev/null | awk '
		$1 == "counter" { c = $2 }
		$1 == "packets" { P[c] = $2 }
		END { if (("pf_udp" in P) && ("pf_all" in P)) print P["pf_udp"] + 0, P["pf_all"] + 0 }'
}
pf_traffic_totals() {
	[ -z "$GAMING_IP4" ] && [ -z "$GAMING_IP6" ] && { echo "0 0"; return; }
	local _t
	_t=$(_pf_nft_totals)
	[ -n "$_t" ] && { echo "$_t"; return; }
	[ "${PF_CT_FRESH:-0}" = 1 ] && { cat "$PF_CT_TOT" 2>/dev/null; return; }
	[ -r "$PF_CT_PROC" ] || { echo "-1 -1"; return; }
	awk -v gips="$GAMING_IP4 $GAMING_IP6" -v minport=1024 '
	BEGIN {
		n = split(gips, A, /[ \t]+/)
		for (i = 1; i <= n; i++) if (A[i] != "") G[A[i]] = 1
		udp = 0; all = 0; seen_acct = 0
	}
	{
		srcip = ""; dport = -1; np = 0; p1 = 0; p2 = 0; is_udp = 0
		for (i = 1; i <= NF; i++) {
			if ($i == "udp") is_udp = 1
			else if (srcip == "" && substr($i, 1, 4) == "src=") srcip = substr($i, 5)
			else if (dport < 0 && substr($i, 1, 6) == "dport=") dport = substr($i, 7) + 0
			else if (substr($i, 1, 8) == "packets=") {
				np++
				if (np == 1) p1 = substr($i, 9) + 0
				else if (np == 2) p2 = substr($i, 9) + 0
			}
		}
		if (np > 0) seen_acct = 1
		if (!(srcip in G)) next
		all += p1 + p2
		if (is_udp && dport >= minport) udp += p1 + p2
	}
	END { if (!seen_acct && NR > 0) print "-1 -1"; else print udp, all }
	' "$PF_CT_PROC" 2>/dev/null
}

# Three-state activity by RATE: active (sustained UDP gameplay) > matchmaking
# (measured presence) > idle; a parked conntrack entry is not activity. The
# single writer of the rate window ($PF_RUN_DIR/.act: "ts udp_total
# all_total state") and the verdict ($PF_RUN_DIR/.activity: "state ts"). The
# window is the gap since the last call (the daemon's sleep).
pf_activity_tick() {
	local now cur udp all pts pudp pall pstate dt upps st exit_pps
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	now=$(date +%s)
	cur=$(pf_traffic_totals)
	udp=${cur%% *}; all=${cur##* }
	pts=0; pudp=-1; pall=-1; pstate=idle
	[ -f "$PF_RUN_DIR/.act" ] && read -r pts pudp pall pstate < "$PF_RUN_DIR/.act" 2>/dev/null
	case "$pts"  in (''|*[!0-9]*) pts=0 ;; esac
	case "$pudp" in (''|*[!0-9-]*) pudp=-1 ;; esac
	case "$pall" in (''|*[!0-9-]*) pall=-1 ;; esac
	dt=$((now - pts))
	if [ "$udp" -lt 0 ] 2>/dev/null; then
		# Accounting off, rate unknowable: existence tests (rare, the daemon
		# enables accounting at start).
		if pf_has_active_traffic 2>/dev/null; then st=active
		elif pf_gaming_presence 2>/dev/null; then st=matchmaking
		else st=idle; fi
	elif [ "$pudp" -lt 0 ] 2>/dev/null || [ "$dt" -le 0 ] 2>/dev/null || \
		[ "$udp" -lt "$pudp" ] 2>/dev/null || [ "$all" -lt "$pall" ] 2>/dev/null; then
		# First window, or counters went backwards (conntrack flush): no rate
		# yet. Presence may arm the fast cadence, but NEVER "active" without
		# a measured rate.
		if pf_gaming_presence 2>/dev/null; then st=matchmaking; else st=idle; fi
	else
		upps=$(((udp - pudp) / dt))
		exit_pps=$((PF_ACTIVE_PPS / 2))
		if [ "$upps" -ge "$PF_ACTIVE_PPS" ]; then st=active
		elif [ "$pstate" = "active" ] && [ "$upps" -ge "$exit_pps" ]; then st=active
		elif [ "$upps" -ge "$PF_PRESENCE_PPS" ]; then st=matchmaking
		else st=idle; fi
	fi
	printf '%s %s %s %s\n' "$now" "$udp" "$all" "$st" > "$PF_RUN_DIR/.act" 2>/dev/null
	printf '%s %s\n' "$st" "$now" > "$PF_RUN_DIR/.activity" 2>/dev/null
	# Play window (.playwin: "start last_busy"): any non-idle tick extends
	# it; one after more than map_keep idle opens a new one.
	if [ "$st" != "idle" ]; then
		local ws=0 wl=0
		[ -f "$PF_RUN_DIR/.playwin" ] && read -r ws wl < "$PF_RUN_DIR/.playwin" 2>/dev/null
		case "$ws" in (''|*[!0-9]*) ws=0 ;; esac
		case "$wl" in (''|*[!0-9]*) wl=0 ;; esac
		[ $((now - wl)) -gt "${PF_MAP_KEEP:-3600}" ] && ws=$now
		printf '%s %s\n' "$ws" "$now" > "$PF_RUN_DIR/.playwin" 2>/dev/null
	fi
	echo "$st"
}

# Read side: the daemon's fresh verdict, without touching the rate window.
# Stale / missing (daemon down or starting): derive one via the tick.
pf_activity_state() {
	local f="$PF_RUN_DIR/.activity" st ts now age
	now=$(date +%s)
	if [ -f "$f" ]; then
		read -r st ts < "$f" 2>/dev/null
		case "$ts" in (''|*[!0-9]*) ts=0 ;; esac
		age=$((now - ts))
		case "$st" in
			active|matchmaking|idle)
				[ "$age" -le $((PF_IDLE_INTERVAL * 2 + 5)) ] 2>/dev/null && { echo "$st"; return; } ;;
		esac
	fi
	# No fresh daemon verdict: READ-ONLY existence fallback, capped at
	# matchmaking. The daemon is the SOLE writer of .act / .activity.
	if pf_gaming_presence 2>/dev/null; then echo "matchmaking"; else echo "idle"; fi
}

# TERM / INT / HUP handler for both daemon entry points. Workers forked with
# ( ... ) & do not get the trap (a subshell resets caught signals): take them
# and their ping / tcpdump children down first, or they orphan.
_pf_kill_kids() {
	local k
	k=$(_pf_proc_table | _pf_pick kids "$$")
	[ -n "$k" ] && kill -TERM $k 2>/dev/null
	return 0
}

_pf_trap_cleanup() {
	_pf_kill_kids
	rm -f "$PF_JSON" "$PF_RUN_DIR/status" "$PF_RUN_DIR/.viewer" "$PF_RUN_DIR"/.tap-* "$PF_RUN_DIR/.stuck" "$PF_RUN_DIR/.mmsince" 2>/dev/null
	rm -f "$PF_RUN_DIR"/hs-* 2>/dev/null
	rm -f "$PF_PID_FILE" 2>/dev/null
	rm -f "$PF_RUN_DIR"/rtt-* "$PF_RUN_DIR"/.rtt-* "$PF_RUN_DIR"/stats-* "$PF_RUN_DIR"/.ctr-* "$PF_RUN_DIR"/.samp-* "$PF_RUN_DIR"/.samprun-* "$PF_RUN_DIR"/.trttrun-* "$PF_RUN_DIR"/.trttsil-* "$PF_RUN_DIR"/tele-* "$PF_LIVE_TSV" 2>/dev/null
	exit 0
}

# Matchmaking going nowhere: searching for 45 s and, in the last minute,
# servers blocked and none allowed (a held one, with no figure yet, counts
# on neither side). Noted in .stuck ("blocked-count since-epoch"); the
# dashboard offers a looser limit. Only while blocking.
_pf_stuck_tick() {   # $1 = activity state, $2 = now
	local f="$PF_RUN_DIR/.stuck" s="$PF_RUN_DIR/.mmsince" t=0 n h=""
	if [ "$1" != "matchmaking" ] \
	   || { [ "$PF_BLOCK_MODE" != "distance" ] && [ "${PF_THRESHOLD_MS:-0}" = "0" ] && [ -z "$PF_COUNTRIES" ]; }; then
		[ -f "$s" ] && rm -f "$s" "$f" 2>/dev/null
		return 0
	fi
	[ -f "$s" ] || { echo "$2" > "$s" 2>/dev/null; return 0; }
	read -r t < "$s" 2>/dev/null
	case "$t" in ''|*[!0-9]*) t=$2 ;; esac
	[ $(($2 - t)) -ge 45 ] && [ $(( ($2 - t) % 10 )) -lt 2 ] || return 0
	_pf_hold_nofig && h=1
	n=$(awk -F'\t' -v now="$2" -v h="$h" '
		now - $9 < 60 { if ($2 == "blocked") b++; else if ($2 == "whitelist" || ($2 == "allowed" && ($3 + 0 > 0 || h == ""))) a++ }
		END { print (a + 0 == 0) ? b + 0 : 0 }' "$PF_SERVERS_TSV" 2>/dev/null)
	if [ "${n:-0}" -ge 3 ] 2>/dev/null; then
		echo "$n $t" > "$f" 2>/dev/null
	else
		rm -f "$f" 2>/dev/null
	fi
	return 0
}

pf_daemon_loop() {
	trap '_pf_trap_cleanup' TERM INT HUP
	# ct bytes / packets are zero without conntrack accounting.
	sysctl -w net.netfilter.nf_conntrack_acct=1 >/dev/null 2>&1
	local _cfg="/etc/config/$UCI_CFG" _cs="$PF_RUN_DIR/.cfg.stamp"
	local _last_cfg=0 _last_up=0 _tb="" _t _view=0 now state _slept
	PF_HS_PID=""; PF_HS_SRC=""
	while :; do
		now=$(date +%s)
		# Config: re-read when the file changed, and on a timer (a change in
		# the same second is invisible to mtime, and a MAC can take a new
		# address with no config change).
		if [ ! -f "$_cs" ] || [ "$_cfg" -nt "$_cs" ] || [ $((now - _last_cfg)) -ge 60 ] \
		   || { [ -n "$GAMING_MAC" ] && [ $((now - _last_cfg)) -ge "${PF_MAC_REFRESH:-30}" ]; }; then
			touch "$_cs" 2>/dev/null
			pf_load_config 2>/dev/null
			_last_cfg=$now; _last_up=0
			# BOTH switches: master off means the shaper is down.
			if [ "$PF_ENABLED" != "1" ] || [ "$ENABLED" != "1" ]; then
				pf_note "INFO" "ping filter: disabled - daemon exiting"
				_pf_tap_stop_all
				# As pf_stop: with no daemon to grade, a table left here holds
				# every new server. Open sessions are closed, the session
				# stamps go.
				pf_tele_clear all
				pf_persist_save 1
				pf_uninstall_fw_rules
				_pf_trap_cleanup
			fi
			# The table is built from the hold rule, the ignore ports, the
			# listed prefixes and the v6 devices: when any of them moved (a hand
			# edit, an auto-pin), put it right.
			_t=0; _pf_hold_on && _t="$_HOLD$PF_FIRST_PKTS"
			_t="$_t|$PF_IGNORE_NFT|$PF_WL_NETS|$PF_BL_NETS|${GAMING_IP6:+6}"
			[ -n "$_tb" ] && [ "$_t" != "$_tb" ] && pf_table_install >/dev/null 2>&1
			_tb=$_t
			# Flow offloading hides established flows: said once in the log.
			if _pf_offload_on; then
				_pf_warn_once offload "ping filter: flow offloading is on - established game flows bypass discovery, the activity gate and blocks; turn it off (System -> Maintenance)"
			else
				_pf_warn_clear offload
			fi
		fi
		# Kernel upkeep on a timer (see pf_scan_once).
		PF_SKIP_UPKEEP=1
		if [ $((now - _last_up)) -ge "${PF_UPKEEP:-30}" ]; then
			PF_SKIP_UPKEEP=0; _last_up=$now
		fi
		_pf_hs_tick
		_pf_ct_snap
		_pf_sess_tick "$now"
		state=$(pf_activity_tick)
		_pf_stuck_tick "$state" "$now"
		pf_scan_once
		# Blocks put off while a server was played land once its session is
		# over (_pf_defer); only on this tick's snapshot, which the stamps
		# come from.
		[ "${PF_CT_FRESH:-0}" = 1 ] && pf_due_apply "$now"
		# While a page asks for the servers JSON (the rpcd shim leaves
		# .viewer), build it once per scan; the shim hands out the file.
		[ -f "$PF_RUN_DIR/.viewer" ] && { rm -f "$PF_RUN_DIR/.viewer" 2>/dev/null; _view=$now; }
		if [ $((now - _view)) -lt 20 ]; then
			pf_servers_json 2>/dev/null | grep '^{' | tail -n 1 > "$PF_JSON.$$" \
				&& mv "$PF_JSON.$$" "$PF_JSON" 2>/dev/null
		elif [ -f "$PF_JSON" ]; then
			rm -f "$PF_JSON" 2>/dev/null
		fi
		_pf_status_file "$now" "$_view"
		PF_CT_FRESH=0
		case "$state" in
			active) sleep "$PF_ACTIVE_INTERVAL" ;;
			matchmaking) sleep "${PF_ARMED_INTERVAL:-1}" ;;
			*)
				# Idle: short naps, re-checking activity each, so a game start
				# is noticed in seconds and an ended session finalized.
				_slept=0
				while [ "$_slept" -lt "$PF_IDLE_INTERVAL" ]; do
					sleep "${PF_IDLE_POLL:-2}"
					_slept=$((_slept + ${PF_IDLE_POLL:-2}))
					[ "${PF_TELEMETRY:-1}" = "1" ] && pf_tele_sweep
					# Table counters; the conntrack table only when missing.
					state=$(pf_activity_tick)
					PF_CT_FRESH=0
					# A page polling while idle: the status file every poll.
					now=$((now + ${PF_IDLE_POLL:-2}))
					[ -f "$PF_RUN_DIR/.viewer" ] && { rm -f "$PF_RUN_DIR/.viewer" 2>/dev/null; _view=$now; }
					_pf_status_file "$now" "$_view"
					[ "$state" != "idle" ] && break
					[ "$_cfg" -nt "$_cs" ] && break
				done
				;;
		esac
	done
}

# While a page shows the Ping Filter (the rpcd shim leaves .viewer, as for
# the servers JSON) the status report is written here once a loop and the
# shim hands the file out: no script parse per poll. Gone 20 s after the
# last view, and the shim falls back to the verb when it is stale. None
# while the config is newer than this daemon's read of it (.cfg.stamp):
# the report would show the old settings, stamped after the save, and the
# shim would take it as fresh.
_pf_status_file() {   # $1 = now, $2 = last view
	local f="$PF_RUN_DIR/status"
	if [ $(($1 - $2)) -lt 20 ] && ! [ "/etc/config/$UCI_CFG" -nt "$PF_RUN_DIR/.cfg.stamp" ]; then
		if pf_status > "$f.$$" 2>/dev/null && mv "$f.$$" "$f" 2>/dev/null; then :; else rm -f "$f.$$" 2>/dev/null; fi
	elif [ -f "$f" ]; then
		rm -f "$f" 2>/dev/null
	fi
	return 0
}

# TRUE only when $1 is a live PID whose argv marks it as ours: after a kill
# -9 the pidfile's PID can be recycled, and the kill and nudge paths signal
# as root.
_pf_pid_is_ours() {
	local p="$1" cl
	case "$p" in ''|*[!0-9]*) return 1 ;; esac
	[ -r "/proc/$p/cmdline" ] || return 1
	cl=$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline")
	case "$cl" in *qos-ex-pf*|*QoS-Ex-PF*|*pingfilter*) return 0 ;; esac
	return 1
}

# --- daemon process discovery / dedup -------------------------------------
# The pidfile records ONE daemon, so these read the process table.
# argv marks the daemon: "qos-ex-pf.sh _daemon_supervised" (procd). Forked
# workers are subshells with the SAME argv.
# One pass over /proc: "pid ppid tag", tag S (supervised), V, H or -. stat
# and comm by builtin reads; tr forks only for shell processes (comm sh /
# ash, the script name, or a pf-* title).
# V and H are what a dead parent leaves, so both need ppid 1:
#   V  this script under any other verb: a background job whose CLI or rpcd
#      caller exited. One with a live parent is a foreground call, left be.
#   H  a tcpdump tap, conntrack listener or their awk, whose subshell died
#      first (a conntrack -E | awk pair keeps itself alive). Known by the
#      argv this script starts them with: the qos-ex-pf-* name from
#      _pf_exec_as, or the plain command (NULs dropped, words joined).
_pf_proc_table() {
	local d pid st pp cm cl t a b
	for d in /proc/[0-9]*; do
		pid=${d#/proc/}
		read -r st 2>/dev/null < "$d/stat" || continue
		cm=${st#*\(}; cm=${cm%\)*}
		pp=${st##*\) }; pp=${pp#* }; pp=${pp%% *}
		t=-
		case "$cm" in
		sh|ash|qos-ex-pf.sh|QoS-Ex-PF.sh|pf-*)
			cl=$(tr '\0' ' ' 2>/dev/null < "$d/cmdline")
			case "$cl" in
			*qos-ex-pf*|*QoS-Ex-PF*|*pingfilter*)
				case "$cl" in
				*" _daemon_supervised"*) t=S ;;
				*)
					if [ "$pp" = 1 ]; then
						a=${cl%% *}; b=${cl#* }; b=${b%% *}
						case "${a##*/} ${b##*/}" in
						qos-ex-pf.sh\ *|*\ qos-ex-pf.sh|QoS-Ex-PF.sh\ *|*\ QoS-Ex-PF.sh) t=V ;;
						esac
					fi ;;
				esac ;;
			esac ;;
		*)
			if [ "$pp" = 1 ]; then
				cl=""; read -r cl 2>/dev/null < "$d/cmdline"
				case "$cl" in
				*tcpdump-i*-p-nn-tt-q-ludp\ and\ src\ host*|*conntrack-E-pudp-eNEW,UPDATES,DESTROY-otimestamp*) t=H ;;
				# DNS taps (dst port 53, qos-ex-pf-dns) of 2.0.8.3 and older too.
				*tcpdump-i*-p-nn-tt-ludp\ dst\ port\ 53\ *) t=H ;;
				qos-ex-pf-jitter-i*|qos-ex-pf-handshake-E*|qos-ex-pf-dns-i*) t=H ;;
				*awk-v*"$PF_RUN_DIR"*) t=H ;;
				esac
			fi ;;
		esac
		echo "$pid $pp $t"
	done
}

# Select from a _pf_proc_table on stdin. $1 mode, $2 the caller's PID:
#   strays  orphaned helpers (H) and their trees
#   all     every tagged process (S V H) + every descendant - the stop set
#   kids    every descendant of $2
# The caller, its ancestors and (except for kids) its descendants are never
# listed, so no path signals itself or its parent.
_pf_pick() {
	awk -v mode="$1" -v me="$2" '
	{ n++; id[n] = $1; pp[$1] = $2; tg[$1] = $3 }
	END {
		for (x = me; (x in pp) && !(x in skip); x = pp[x]) skip[x] = 1
		if (mode != "kids") {
			sub_[me] = 1
			do { ch = 0
				for (i = 1; i <= n; i++) { x = id[i]
					if (!(x in sub_) && (pp[x] in sub_)) { sub_[x] = 1; ch = 1 } }
			} while (ch)
		}
		for (i = 1; i <= n; i++) { x = id[i]
			if (mode == "kids") { if (pp[x] == me) sel[x] = 1; continue }
			if (tg[x] == "-") continue
			if (mode == "all" || (mode == "strays" && tg[x] == "H")) sel[x] = 1
		}
		if (mode == "all" || mode == "strays" || mode == "kids")
			do { ch = 0
				for (i = 1; i <= n; i++) { x = id[i]
					if (!(x in sel) && (pp[x] in sel)) { sel[x] = 1; ch = 1 } }
			} while (ch)
		for (i = 1; i <= n; i++) { x = id[i]
			if ((x in sel) && !(x in skip) && !(x in sub_)) print x }
	}'
}

# $1 = a _pf_pick mode.
_pf_daemon_pids() {
	_pf_proc_table | _pf_pick "$1" "$$" | sort -n
}


# TERM the PIDs, wait up to ~3 s (the trap removes the pidfile),
# then KILL what is left. Whole-second sleeps.
_pf_term_then_kill() {
	local pids="$1" p i alive
	[ -z "$pids" ] && return 0
	for p in $pids; do kill -TERM "$p" 2>/dev/null; done
	i=0
	while [ "$i" -lt 3 ]; do
		alive=""
		for p in $pids; do [ -d "/proc/$p" ] && alive="$alive $p"; done
		[ -z "$alive" ] && return 0
		i=$((i + 1)); sleep 1
	done
	for p in $alive; do kill -KILL "$p" 2>/dev/null; done
}



# Terminate daemons. scope ($1):
#   all|<empty>  every daemon, worker, child and orphan of ours: stop, and
#                the first thing start does
#   strays       orphaned helpers; the procd instance is left alone so its
#                respawn is not fought
pf_kill_all_daemons() {
	local scope="${1:-all}" kind pids p
	case "$scope" in strays) kind=strays ;; *) kind=all ;; esac
	if [ "$scope" != "strays" ]; then
		# The daemon first, on its own: its trap takes its workers down once
		# the command it runs ends. TERM to both at once made ash log
		# "Terminated" (daemon.err in syslog) on every stop and restart.
		p=$(cat "$PF_PID_FILE" 2>/dev/null)
		[ "$p" != "$$" ] && _pf_pid_is_ours "$p" && _pf_term_then_kill "$p"
	fi
	pids=$(_pf_daemon_pids "$kind")
	if [ "$scope" != "strays" ]; then
		# The pidfile PID too (a daemon whose argv lost the marker), only once
		# argv confirms it is ours: a recycled PID would be killed as root.
		p=$(cat "$PF_PID_FILE" 2>/dev/null)
		if _pf_pid_is_ours "$p"; then
			pids="$pids
$p"
		fi
	fi
	pids=$(printf '%s\n' $pids | grep -E '^[0-9]+$' | sort -un)
	_pf_term_then_kill "$pids"
	# A worker mid-fork can leave a child the snapshot missed: one more
	# sweep, KILL.
	pids=$(_pf_daemon_pids "$kind")
	[ -n "$pids" ] && kill -KILL $pids 2>/dev/null
	if [ "$scope" != "strays" ]; then
		rm -f "$PF_PID_FILE" 2>/dev/null
		rm -f "$PF_RUN_DIR"/rtt-* "$PF_RUN_DIR"/.rtt-* "$PF_RUN_DIR"/stats-* "$PF_RUN_DIR"/.ctr-* "$PF_RUN_DIR"/.samp-* "$PF_RUN_DIR"/.samprun-* "$PF_RUN_DIR"/.trttrun-* "$PF_RUN_DIR"/.trttsil-* "$PF_RUN_DIR"/tele-* "$PF_LIVE_TSV" 2>/dev/null
	fi
}

# procd owns the daemon: this call comes from the init script, or the
# service is up (start_service leaves .procd, stop_service removes it first).
_pf_supervised() {
	[ "${QOS_EX_SUPERVISED:-0}" = "1" ] || [ -f "$PF_RUN_DIR/.procd" ]
}

pf_start_daemon() {
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	# The daemon is a procd instance of the QoS-Ex service: procd starts,
	# restarts and stops it. Here: wake it when parked.
	if ! _pf_supervised; then
		err "ping filter: the daemon runs under the QoS-Ex service — start it with: /etc/init.d/QoS-Ex start"
		return 1
	fi
	pf_kill_all_daemons strays
	if [ -f "$PF_RUN_DIR/.idle_parked" ]; then
		rm -f "$PF_RUN_DIR/.idle_parked" 2>/dev/null
		pf_nudge_supervised
	fi
	return 0
}

pf_stop_daemon() {
	pf_kill_all_daemons all
}

pf_daemon_supervised() {
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	echo $$ > "$PF_PID_FILE"
	_pf_title pf-daemon
	PF_MAIN=1
	trap '_pf_trap_cleanup' TERM INT HUP
	# stop_service removes .procd FIRST, then tears down, then rc.common
	# deletes the instance; a respawn (5 s) mid-teardown would put the rules
	# back. No marker = going down: park, and let procd kill us.
	# Parked naps run as `sleep & wait`: a foreground sleep holds the TERM trap
	# off for up to 30 s, so every stop ended in procd's KILL.
	if [ ! -f "$PF_RUN_DIR/.procd" ]; then
		while :; do sleep 30 & wait $!; done
	fi
	# Orphaned helpers of an earlier instance go before parking or running.
	pf_kill_all_daemons strays
	if [ "$PF_ENABLED" != "1" ] || [ "$ENABLED" != "1" ] || [ -f "$PF_RUN_DIR/.stopped" ] \
	   || ! pf_check_prereqs >/dev/null 2>&1; then
		# Parked means nothing grades: a table left in place would hold every
		# new server. A stop has already removed it.
		[ -f "$PF_RUN_DIR/.stopped" ] || pf_uninstall_fw_rules
		# Park with a marker: this loop never re-reads config, so the next
		# healthy reload nudges it back through the entry gates (procd
		# respawn).
		touch "$PF_RUN_DIR/.idle_parked" 2>/dev/null
		pf_note "INFO" "ping filter: supervised daemon parked (disabled, master off, stopped, nothing ticked, or no home)"
		while :; do sleep 30 & wait $!; done
	fi
	rm -f "$PF_RUN_DIR/.idle_parked" 2>/dev/null
	pf_install_fw_rules >/dev/null 2>&1
	pf_cache_init
	pf_persist_restore
	pf_cache_sanitise
	pf_seed_lists
	pf_note "INFO" "ping filter: supervised daemon active (pid $$)"
	pf_daemon_loop
}

pf_nudge_supervised() {
	[ -f "$PF_RUN_DIR/.procd" ] || return 1
	local p
	p=$(cat "$PF_PID_FILE" 2>/dev/null)
	_pf_pid_is_ours "$p" && kill "$p" 2>/dev/null
	return 0
}

pf_check_prereqs() {
	local missing=""
	# A ticked MAC counts with no address yet -- see PF_MAC_SEL.
	if [ -z "$GAMING_IP4$GAMING_IP6$PF_MAC_SEL" ]; then
		missing="gaming_ip"
	fi
	if [ -z "$PF_HOME_LAT" ] || [ -z "$PF_HOME_LON" ]; then
		[ -n "$missing" ] && missing="$missing,home_location" || missing="home_location"
	fi
	if [ -n "$missing" ]; then
		echo "$missing"
		return 1
	fi
	return 0
}

# Old runtime file locations. Only called with every PF process down (start,
# uninstall).
_pf_old_tmp_cleanup() {
	rm -rf /tmp/qos-ex-pingfilter 2>/dev/null
	rm -f /tmp/qos-ex-pf-daemon.log /tmp/qos-ex-pingfilter-nft.err /tmp/qos-ex-pingfilter-nft.err.* 2>/dev/null
	return 0
}

pf_start() {
	rm -f "$PF_RUN_DIR/.stopped" 2>/dev/null
	# Start from nothing: every PF process is killed first (a daemon running
	# old code after an install, anything a stop missed). procd brings the
	# supervised daemon back on the code and config now in place.
	pf_kill_all_daemons all
	_pf_old_tmp_cleanup
	[ "$ENABLED" = "1" ] || { msg "ping filter not starting (QoS-Ex master switch is off)"; return 0; }
	[ "$PF_ENABLED" = "1" ] || { msg "ping filter disabled (pingfilter.enabled=0)"; return 0; }
	local miss
	miss=$(pf_check_prereqs) || {
		case "$miss" in
			*gaming_ip*)      err "ping filter: cannot start — no monitored gaming device (set one to Gaming on Setup → Devices & Ports, then tick it in Ping Filter → Settings → Devices)" ;;
		esac
		case "$miss" in
			*home_location*)  err "ping filter: cannot start — home_lat/home_lon not set (Ping Filter → Settings → Home)" ;;
		esac
		err "ping filter: missing prerequisites: $miss"
		return 1
	}
	pf_install_fw_rules || return 1
	pf_cache_init_once
	pf_persist_restore
	pf_cache_sanitise
	pf_seed_lists
	# Re-grade the restored cache against CURRENT settings into the kernel
	# sets in one transaction.
	pf_seed_gaming_set
	pf_reclassify
	pf_start_daemon || return 1
	# Can the router reach the location services? In the background: a
	# blocked one may take its timeout.
	( _pf_title pf-geo-test; exec </dev/null >/dev/null 2>&1; pf_geo_svc_check ) 6>&- 7>&- &
	return 0
}

pf_stop() {
	pf_tele_finalize_all
	pf_persist_save 1
	pf_stop_daemon
	pf_uninstall_fw_rules
}

pf_reload() {
	# Each mode keeps its own number in UCI (the ping limit, the Ping Catch):
	# pf_load_config zeroes the other mode's in memory.
	pf_load_config
	if [ "$ENABLED" != "1" ] || [ "$PF_ENABLED" != "1" ]; then
		pf_stop
		pf_tele_clear all
		msg "ping filter reload: disabled (master=$ENABLED pf=$PF_ENABLED) — daemon stopped"
		return 0
	fi
	# Runtime gate: a reload whose prerequisites fail (no device ticked, or no
	# home location) sets pingfilter.enabled=0, so every reader shows
	# OFF. Fix and re-enable to bring it back.
	local miss
	if ! miss=$(pf_check_prereqs); then
		case "$miss" in
			*gaming_ip*)
				if [ -n "$GAMING_IP4_ALL$GAMING_IP6_ALL$PF_DEVICES" ]; then
					err "ping filter: no monitored device ticked (Ping Filter → Settings → Devices) — PF DISABLED"
				else
					err "ping filter: no gaming device configured (Setup → Devices & Ports) — PF DISABLED"
				fi ;;
		esac
		case "$miss" in
			*home_location*) err "ping filter: home location not set (Map tab → set home) — PF DISABLED" ;;
		esac
		if [ "$PF_ENABLED" = "1" ]; then
			uci -q set "$UCI_CFG.pingfilter.enabled=0"
			uci -q commit "$UCI_CFG"
			PF_ENABLED=0
		fi
		pf_stop
		pf_tele_clear all
		return 0
	fi
	# Stopped at runtime: the config is committed and applies on start.
	if [ -f "$PF_RUN_DIR/.stopped" ]; then
		msg "ping filter reload: stopped — settings saved, applied on next start"
		return 0
	fi
	pf_install_fw_rules || return 1
	# A router that booted with the Ping Filter off has an empty live list:
	# the flash copy comes back before the re-grade (a no-op when the live
	# list has rows), or the next persist_save would write the empty list
	# over it.
	pf_persist_restore
	pf_cache_sanitise
	pf_reclassify
	# Settings are applied above; the daemon picks the config up itself. Wake
	# it if parked.
	pf_start_daemon
	msg "ping filter reloaded (threshold=${PF_THRESHOLD_MS}ms)"
}

pf_set_enabled() {
	local on="$1"
	case "$on" in
		1|yes|on|enable)
			local miss
			miss=$(pf_check_prereqs) || {
				err "ping filter: cannot enable — missing prerequisites: $miss"
				err "ping filter: tick a device (Ping Filter → Settings → Devices) + set a Home location (Map or Settings → Home) first"
				return 1
			}
			rm -f "$PF_RUN_DIR/.stopped" 2>/dev/null
			uci -q set "$UCI_CFG.pingfilter.enabled=1"
			uci -q commit "$UCI_CFG"
			;;
		0|no|off|disable)
			uci -q set "$UCI_CFG.pingfilter.enabled=0"
			uci -q commit "$UCI_CFG"
			;;
		*) err "usage: pf enable|disable"; return 1 ;;
	esac
	pf_reload
}

# The live-control setters below (limit, radius, mode; the Ping Catch verb
# and pf_profile alike) are the user's own change: their re-grade lands at
# once, also on a server being played (PF_USER_NOW).
pf_set_threshold() {
	local ms="$1" PF_USER_NOW=1
	[ -z "$ms" ] && { err "usage: pf threshold <ms>"; return 1; }
	# 0 = ping-based blocking off (visibility only); the map slider reaches 0.
	# Negatives / non-digits are rejected.
	case "$ms" in (*[!0-9]*) err "invalid threshold (digits only)"; return 1 ;; esac
	[ "$ms" -le 5000 ] 2>/dev/null || { err "threshold out of range (0-5000)"; return 1; }
	# Flash wear: no commit when the value is unchanged.
	[ "$(uci -q get $UCI_CFG.pingfilter.threshold_ms)" = "$ms" ] && { pf_reload; return 0; }
	uci set $UCI_CFG.pingfilter.threshold_ms="$ms"
	uci commit $UCI_CFG
	pf_reload
}

# Live home-radius setter (the map Radius slider): writes home_radius_km and
# reloads; pf_reload re-grades every cached server. In ping mode the radius
# is only the ring on the map.
pf_set_radius() {
	local km="$1" PF_USER_NOW=1
	[ -z "$km" ] && { err "usage: pf radius <km>"; return 1; }
	case "$km" in (*[!0-9]*) err "invalid radius (digits only)"; return 1 ;; esac
	if ! { [ "$km" -ge 50 ] 2>/dev/null && [ "$km" -le 20000 ] 2>/dev/null; }; then
		err "radius out of range (50-20000 km)"; return 1
	fi
	[ "$(uci -q get $UCI_CFG.pingfilter.home_radius_km)" = "$km" ] && { pf_reload; return 0; }
	uci set $UCI_CFG.pingfilter.home_radius_km="$km"
	uci commit $UCI_CFG
	pf_reload
}

# Live block-mode setter (the map toggle): writes block_mode and reloads, so
# the cache is re-graded at once. Self-committing like the slider and
# Re-check cache, so they never act on a mode still staged in the Settings
# form. The other mode's number stays as it is (unused while this one runs).
pf_set_mode() {
	local mode="$1" PF_USER_NOW=1
	case "$mode" in
		ping|distance) ;;
		*) err "usage: pf mode <ping|distance>"; return 1 ;;
	esac
	[ "$(uci -q get $UCI_CFG.pingfilter.block_mode)" = "$mode" ] && { pf_reload; return 0; }
	uci set $UCI_CFG.pingfilter.block_mode="$mode"
	uci commit $UCI_CFG
	pf_reload
}

# Cut servers.tsv down to its pin rows (New game, Clear cache). A pin's row is
# the evidence it was seen, and pf_servers_json hides a pin without one.
# Mirrored to flash at once: persist_restore only refills an EMPTY live file.
_pf_keep_pinned_rows() {
	[ -f "$PF_SERVERS_TSV" ] || return 0
	pf_tsv_lock || return 1
	local tmp="$PF_SERVERS_TSV.pin.$$"
	awk -F'\t' -v wl=" $PF_WHITELIST " -v bl=" $PF_BLACKLIST " \
		'$1 != "" && (index(wl, " " $1 " ") > 0 || index(bl, " " $1 " ") > 0)' \
		"$PF_SERVERS_TSV" > "$tmp" 2>/dev/null && pf_tsv_replace "$tmp" "$PF_SERVERS_TSV" 0
	rm -f "$tmp" 2>/dev/null
	pf_tsv_unlock
	mkdir -p "$PF_PERSIST_DIR" 2>/dev/null
	if [ -s "$PF_SERVERS_TSV" ]; then
		_pf_atomic_cp "$PF_SERVERS_TSV" "$PF_PERSIST_DIR/servers.tsv"
	else
		rm -f "$PF_PERSIST_DIR/servers.tsv" 2>/dev/null
	fi
}

# Fresh start: rows, grades, readings in flight, both kernel sets, the seen
# set, locations and /24 memory go, live and on flash. Only the pins survive,
# with their locations. New game (pf_session_reset) is the partial one.
pf_clear_cache() {
	local tmp="$PF_GEO_CACHE.purge" _lk
	_pf_keep_pinned_rows
	rm -f "${PF_SERVERS_TSV}.bps" 2>/dev/null
	pf_tele_clear all
	rm -f "$PF_RUN_DIR"/rtt-* "$PF_RUN_DIR"/.rtt-* "$PF_RUN_DIR"/hs-* 2>/dev/null
	_pf_side_lock
	if [ -f "$PF_GEO_CACHE" ]; then
		awk -F'\t' -v pin=" $PF_WHITELIST $PF_BLACKLIST " \
			'$1 != "" && index(pin, " " $1 " ") > 0' "$PF_GEO_CACHE" > "$tmp" 2>/dev/null \
			&& mv "$tmp" "$PF_GEO_CACHE" 2>/dev/null
		rm -f "$tmp" 2>/dev/null
	fi
	rm -f "$PF_PREFIX_TSV" 2>/dev/null
	_pf_side_unlock
	rm -f "$PF_PERSIST_DIR/ping-cache.tsv" "$PF_PERSIST_DIR/prefix.tsv" \
		"$PF_PERSIST_DIR/telemetry.tsv" "$PF_TELE_HIST" \
		"$PF_PERSIST_DIR/sessions.tsv" "$PF_SESS_TSV" \
		"$PF_PERSIST_DIR/owner.tsv" "$PF_OWNER_TSV" \
		"$PF_RUN_DIR/.persist.stamp" 2>/dev/null
	_pf_atomic_cp "$PF_GEO_CACHE" "$PF_PERSIST_DIR/geo-cache.tsv"
	pf_runtime_flush
	nft flush set $PF_FW_TABLE $PF_SEEN_SET_NAME 2>/dev/null
	pf_seed_lists
	msg "ping filter cache cleared (servers, pings, grades, server names, locations, /24 memory, seen set, both ipsets; WL/BL and their rows kept), WL/BL re-seeded"
}

pf_session_reset() {
	local before=0 after=0
	if [ -f "$PF_SERVERS_TSV" ]; then
		before=$(wc -l < "$PF_SERVERS_TSV" 2>/dev/null)
		_pf_keep_pinned_rows
		after=$(wc -l < "$PF_SERVERS_TSV" 2>/dev/null)
	fi
	rm -f "${PF_SERVERS_TSV}.bps" 2>/dev/null
	pf_tele_clear all
	# The ladder belongs to ONE game session: wipe graded history AND its
	# persisted copy (pf_persist_load restores into an empty live file).
	rm -f "$PF_TELE_HIST" "$PF_PERSIST_DIR/telemetry.tsv" 2>/dev/null
	pf_cache_init_once
	pf_runtime_flush
	nft flush set $PF_FW_TABLE $PF_SEEN_SET_NAME 2>/dev/null
	pf_seed_lists
	msg "ping filter session reset: dropped $((${before:-0} - ${after:-0})) rows (${after:-0} WL/BL kept), ipsets flushed, WL/BL re-seeded"
	_pf_scan_now 2>/dev/null
}

pf_geo_check() {
	local ip="$1"
	[ -z "$ip" ] && { echo "Usage: $SCRIPT_NAME pingfilter geo_check <ip>"; return 1; }
	[ -n "$(pf_ip_family "$ip")" ] || { echo "geo_check: invalid IP address: $ip"; return 1; }
	echo "=== geo_check: $ip ==="
	echo "GeoIP enabled:    ${PF_GEOIP_LOOKUP:-(unset)}"
	echo "GeoIP API:        ${PF_GEOIP_API:-(unset)}"
	echo "jsonfilter:       $(command -v jsonfilter || echo MISSING)"
	echo "wget:             $(command -v wget       || echo MISSING)"
	echo "timeout (extern): $(command -v timeout    || echo 'MISSING (degraded: relying on wget -T / ping -W)')"
	echo ""
	echo "--- Reachability tests (real GET, head -c 100) ---"
	_pf_reach_test() {
		local url="$1"
		local out
		out=$(_pf_run_with_timeout 5 wget -4 -T 5 -qO- "$url" 2>/dev/null | head -c 100)
		[ -z "$out" ] && out=$(_pf_run_with_timeout 5 wget -T 5 -qO- "$url" 2>/dev/null | head -c 100)
		if [ -n "$out" ]; then echo "OK"; else echo "FAIL"; fi
	}
	printf '%s' "ip-api.com:           "; _pf_reach_test "http://ip-api.com/json/8.8.8.8?fields=status"
	printf '%s' "ipwho.is:             "; _pf_reach_test "https://ipwho.is/8.8.8.8?fields=success"
	printf '%s' "get.geojs.io:         "; _pf_reach_test "https://get.geojs.io/v1/ip/geo/8.8.8.8.json"
	printf '%s' "freeipapi.com:        "; _pf_reach_test "https://freeipapi.com/api/json/8.8.8.8"
	printf '%s' "ipapi.co:             "; _pf_reach_test "https://ipapi.co/8.8.8.8/json/"
	printf '%s' "google.com:           "; _pf_reach_test "http://www.google.com/generate_204"
	echo ""
	echo "--- Cached entry ---"
	if [ -f "$PF_GEO_CACHE" ]; then
		local row
		row=$(awk -F'\t' -v ip="$ip" '$1 == ip { print; exit }' "$PF_GEO_CACHE")
		[ -n "$row" ] && echo "$row" || echo "(no cache entry)"
	else
		echo "(no cache file)"
	fi
	echo ""
	echo "--- ip-api.com raw response ---"
	local r1
	r1=$(_pf_run_with_timeout 6 wget -4 -T 5 -qO- "${PF_GEOIP_API}/$ip?fields=status,country,city,lat,lon" 2>/dev/null)
	[ -z "$r1" ] && r1=$(_pf_run_with_timeout 6 wget -T 5 -qO- "${PF_GEOIP_API}/$ip?fields=status,country,city,lat,lon" 2>/dev/null)
	if [ -z "$r1" ]; then
		echo "(empty / timeout / banned)"
	else
		echo "$r1"
	fi
	echo ""
	echo "--- ipwho.is raw response ---"
	local r2
	r2=$(_pf_run_with_timeout 6 wget -4 -T 5 -qO- "https://ipwho.is/$ip?fields=success,latitude,longitude,country,city" 2>/dev/null)
	[ -z "$r2" ] && r2=$(_pf_run_with_timeout 6 wget -T 5 -qO- "https://ipwho.is/$ip?fields=success,latitude,longitude,country,city" 2>/dev/null)
	if [ -z "$r2" ]; then
		echo "(empty / timeout / banned)"
	else
		echo "$r2"
	fi
	echo ""
	echo "--- Final pf_geo_lookup result (with provider fallback) ---"
	# A check asks the services now, whatever the last failure said.
	rm -f "$PF_RUN_DIR/.geo-down" 2>/dev/null
	local got
	got=$(pf_geo_lookup "$ip")
	echo "lat lon country city: $got"
}


pf_refresh_lists() {
	# "quiet" drops the routine "refreshed N" line (the daemon's periodic
	# re-ping passes it).
	local quiet="${1:-}" only=""
	# Further args: refresh only these list IPs (a list add). None = all.
	[ $# -gt 1 ] && { shift; only="$*"; }
	pf_load_config
	local n=0
	local ip
	for ip in ${only:-$PF_WHITELIST $PF_BLACKLIST}; do
		[ -z "$ip" ] && continue
		[ "$(pf_ip_family "$ip")" = "v4" ] || continue
		pf_is_private_ip "$ip" && continue

		# The existing row is the fallback for everything below: a failed
		# lookup (0,0) or silent echo must not overwrite a known location or a
		# MEASURED ping.
		local row r_lat="" r_lon="" r_co="" r_ci="" r_ping="" r_src="" r_lan=""
		row=$(pf_cache_get "$ip")
		if [ -n "$row" ]; then
			_pf_row "$row"
			r_lat=$PF_C_LAT; r_lon=$PF_C_LON; r_co=$PF_C_CO; r_ci=$PF_C_CI
			r_ping=$PF_C_PING; r_src=$PF_C_SRC; r_lan=$PF_C_LAN
		fi
		local geo lat="" lon="" cy="" ct=""
		geo=$(pf_geo_lookup "$ip")
		if [ -n "$geo" ]; then
			_pf_geo4 "$geo"; lat=$PF_R_LAT; lon=$PF_R_LON; cy=$PF_R_CO; ct=$PF_R_CI
		fi
		if ! _pf_geo_known "$lat" "$lon" && _pf_geo_known "$r_lat" "$r_lon"; then
			lat=$r_lat; lon=$r_lon
		fi
		[ -z "$cy" ] && cy=$r_co
		[ -z "$ct" ] && ct=$r_ci

		local rtt="" ping_src=""
		# Empty when nothing answers. Every mode probes.
		rtt=$(pf_rtt_icmp "$ip")
		[ "${rtt:--1}" -ge 0 ] 2>/dev/null && ping_src="icmp"
		if [ -z "$ping_src" ]; then
			if _pf_src_measured "$r_src" && [ "$r_ping" -gt 0 ] 2>/dev/null; then
				rtt=$r_ping; ping_src=$r_src
			else
				_pf_estimate "$ip" "$lat" "$lon"
				rtt=$PF_E_MS; ping_src=$PF_E_SRC
			fi
		fi

		local listed_state
		case " $PF_WHITELIST " in
			*" $ip "*) listed_state="whitelist"; pf_allow_add "$ip" 1 ;;
			*)         listed_state="blacklist"; pf_block_add "$ip" 1 ;;
		esac
		# Same evidence rule: update a row that exists; create one only from a
		# real reading, never from an estimate.
		if [ -n "$row" ] || _pf_src_measured "$ping_src"; then
			pf_cache_upsert "$ip" "$listed_state" "$rtt" "$ping_src" \
				"$lat" "$lon" "$cy" "$ct" "$r_lan"
		fi
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] && [ "$quiet" != "quiet" ] && msg "ping filter: refreshed $n list IP(s)"
}



pf_uci_list_add() {
	local list_name="$1" ip="$2" cur existing
	[ -z "$ip" ] && return 1
	cur=$(uci -q get "$UCI_CFG.pingfilter.$list_name" 2>/dev/null)
	for existing in $cur; do
		[ "$existing" = "$ip" ] && return 0
	done
	uci add_list "$UCI_CFG.pingfilter.$list_name=$ip" 2>/dev/null
	uci commit "$UCI_CFG" 2>/dev/null
	pf_load_config
	case "$list_name" in
		whitelist) pf_allow_add "$ip" 1 ;;
		blacklist) pf_block_add "$ip" 1 ;;
	esac
	# The new pin only: refreshing the whole list costs an ICMP burst per pin
	# and runs past LuCI's RPC timeout. Off a terminal it runs detached (rpcd
	# reads to EOF), as pf_profile.
	if [ -t 1 ]; then
		pf_refresh_lists quiet "$ip" >/dev/null 2>&1
	else
		( _pf_title pf-lists; exec </dev/null >/dev/null 2>&1; pf_refresh_lists quiet "$ip" ) &
	fi
}

pf_uci_list_del() {
	local list_name="$1" ip="$2"
	[ -z "$ip" ] && return 1
	uci -q del_list "$UCI_CFG.pingfilter.$list_name=$ip" 2>/dev/null
	uci commit "$UCI_CFG" 2>/dev/null
	pf_load_config
	case "$list_name" in
		whitelist) pf_allow_del "$ip" ;;
		blacklist) pf_block_del "$ip" ;;
	esac
	# The row is NOT dropped here: every caller re-labels it (mark) or deletes
	# it (forget, list_clear). Dropping it lost ping, geo and jitter.
}

pf_list_clear() {
	local list_name="$1"
	case "$list_name" in
		whitelist|blacklist) ;;
		*) err "usage: pf list_clear {whitelist|blacklist}"; return 1 ;;
	esac
	pf_load_config

	local cur ip count=0
	cur=$(uci -q get "$UCI_CFG.pingfilter.$list_name" 2>/dev/null)
	for ip in $cur; do count=$((count + 1)); done

	uci -q delete "$UCI_CFG.pingfilter.$list_name" 2>/dev/null
	uci -q add_list "$UCI_CFG.pingfilter.$list_name=" 2>/dev/null
	uci -q del_list "$UCI_CFG.pingfilter.$list_name=" 2>/dev/null
	uci commit "$UCI_CFG" 2>/dev/null

	for ip in $cur; do
		[ -z "$ip" ] && continue
		case "$list_name" in
			whitelist) pf_allow_del "$ip" ;;
			blacklist) pf_block_del "$ip" ;;
		esac
		pf_cache_delete "$ip"
	done

	# A prefix went with it: empty its set and re-grade what it covered.
	case "$cur" in */*)
		pf_load_config
		pf_table_present && { pf_table_install >/dev/null 2>&1; pf_reclassify; } ;;
	esac
	msg "ping filter $list_name cleared ($count entries removed)"
}

# A list entry written as a prefix: on or off a list, then the table's
# prefix sets and every cached server inside it follow.
#   $1 = a.b.c.d/8../31   $2 = whitelist | blacklist | forget
_pf_net_mark() {
	local n="$1" b="${1#*/}"
	if ! pf_valid_ip4 "$n" || ! [ "$b" -ge 8 ] 2>/dev/null || ! [ "$b" -le 31 ] 2>/dev/null; then
		err "invalid prefix: $n (IPv4, /8 to /31)"; return 1
	fi
	pf_load_config
	uci -q del_list "$UCI_CFG.pingfilter.whitelist=$n" 2>/dev/null
	uci -q del_list "$UCI_CFG.pingfilter.blacklist=$n" 2>/dev/null
	case "$2" in
		whitelist|blacklist) uci -q add_list "$UCI_CFG.pingfilter.$2=$n" ;;
		forget) ;;
		*) err "a prefix can be whitelisted, blacklisted or forgotten"; return 1 ;;
	esac
	uci commit "$UCI_CFG" 2>/dev/null
	pf_load_config
	if pf_table_present; then
		pf_table_install >/dev/null 2>&1
		pf_reclassify
	fi
	case "$2" in
		forget) msg "ping filter: $n taken off the lists" ;;
		*)      msg "ping filter: $n added to the $2" ;;
	esac
}

pf_mark_state() {
	local ip="$1" state="$2"
	if [ -z "$ip" ] || [ -z "$state" ]; then err "usage: pf mark <ip> <state>"; return 1; fi
	case "$ip" in */*) _pf_net_mark "$ip" "$state"; return ;; esac
	[ "$(pf_ip_family "$ip")" = "v4" ] || { err "invalid IPv4 address: $ip"; return 1; }
	pf_load_config
	pf_cache_init

	local ping=0 ping_src="distance" lat="" lon="" country="" city="" lan_src=""
	local existing
	existing=$(pf_cache_get "$ip")
	if [ -n "$existing" ]; then
		_pf_row "$existing"
		ping=$PF_C_PING; ping_src=$PF_C_SRC; lat=$PF_C_LAT; lon=$PF_C_LON
		country=$PF_C_CO; city=$PF_C_CI; lan_src=$PF_C_LAN
	fi

	case "$state" in
		whitelist)
			pf_uci_list_del blacklist "$ip"
			pf_uci_list_add whitelist "$ip"   # this seeds allow-set + calls refresh
			;;
		blacklist)
			pf_uci_list_del whitelist "$ip"
			pf_uci_list_add blacklist "$ip"   # this seeds block-set + calls refresh
			;;
		allowed)
			pf_uci_list_del whitelist "$ip"
			pf_uci_list_del blacklist "$ip"
			pf_allow_add "$ip"
			pf_cache_upsert "$ip" "allowed" "$ping" "$ping_src" \
				"$lat" "$lon" "$country" "$city" "$lan_src"
			;;
		blocked)
			pf_uci_list_del whitelist "$ip"
			pf_uci_list_del blacklist "$ip"
			pf_block_add "$ip"
			pf_cache_upsert "$ip" "blocked" "$ping" "$ping_src" \
				"$lat" "$lon" "$country" "$city" "$lan_src"
			;;
		*)
			err "unknown state: $state (allowed/blocked/whitelist/blacklist)"
			return 1
			;;
	esac
	msg "ping filter: marked $ip as $state"
}

# `forget` means forget: pf_servers_json also seeds canon from the telemetry
# history (tag H), persisted, so a row dropped from servers.tsv alone comes
# back. This clears the rest. Geo is kept (stable
# and costly to re-fetch); geo_purge is the verb for that.
pf_forget_caches() {
	local ip="$1"
	[ -z "$ip" ] && return 0
	_pf_drop_grade "$ip" || return 1
	# Per-IP scratch: ring buffer, counters, sample markers, accumulator.
	_pf_purge_ip_runtime "$ip"
	rm -f "$PF_RUN_DIR/trtt-$ip" "$PF_RUN_DIR/.trtt-$ip" \
	      "$PF_RUN_DIR/.trttrun-$ip" "$PF_RUN_DIR/.samprun-$ip" 2>/dev/null
	return 0
}

# Graded history + live overlay rows and the per-IP telemetry scratch --
# everything the quality ladder shows, nothing that decides a verdict.
_pf_drop_grade() {
	local ip="$1" f tmp
	pf_tsv_lock || return 1
	for f in "$PF_TELE_HIST" "$PF_LIVE_TSV"; do
		[ -f "$f" ] || continue
		tmp="$f.del.$$"
		awk -F'\t' -v ip="$ip" '$1 != ip { print }' "$f" > "$tmp" 2>/dev/null
		# floor_pct 0: forgetting the only known server may legitimately
		# empty the file, so the shrink guard must not veto the rewrite.
		pf_tsv_replace "$tmp" "$f" 0
	done
	pf_tsv_unlock
	rm -f "$PF_TELE_PREFIX$ip" "$PF_TELE_ACC_PREFIX$ip" "$PF_RUN_DIR/.ctr-$ip" \
	      "$PF_RUN_DIR/.samp-$ip" "$PF_RUN_DIR/stats-$ip" 2>/dev/null
	return 0
}

# Quality-ladder remove: drops the grade only. Verdict, whitelist/blacklist,
# the servers.tsv row, geo and the in-play RTT are kept. A server still
# being played comes back as a live row and is graded again when that
# session finalizes.
pf_ungrade_ip() {
	local ip="$1"
	[ -n "$(pf_ip_family "$ip")" ] || { err "ungrade: invalid IP address: $ip"; return 1; }
	pf_load_config
	_pf_drop_grade "$ip" || return 1
	pf_persist_save 1
	msg "ping filter: removed $ip from the quality ladder"
}

pf_forget_ip() {
	local ip="$1"
	[ -z "$ip" ] && { err "usage: pf forget <ip>"; return 1; }
	case "$ip" in */*) _pf_net_mark "$ip" forget; return ;; esac
	[ -n "$(pf_ip_family "$ip")" ] || { err "forget: invalid IP address: $ip"; return 1; }
	pf_load_config
	# Under the scan lock: a pass already running would write the row back.
	local _sl=0
	_pf_scan_lock_wait && _sl=1
	pf_uci_list_del whitelist "$ip"
	pf_uci_list_del blacklist "$ip"
	pf_allow_del "$ip"
	pf_block_del "$ip"
	# Out of discovery too, or the next pass adds it again as a new server.
	# Traffic still flowing to it finds it again, as it should.
	nft delete element $PF_FW_TABLE $PF_SEEN_SET_NAME "{ $ip }" 2>/dev/null
	nft delete element $PF_FW_TABLE $PF_SEEN_SET_NAME6 "{ $ip }" 2>/dev/null
	pf_cache_delete "$ip"
	_pf_prefix_forget "$ip"
	pf_forget_caches "$ip"
	rm -f "$PF_RUN_DIR/rtt-$ip" "$PF_RUN_DIR/.rtt-$ip" "$PF_RUN_DIR/hs-$ip" \
	      "$PF_RUN_DIR/.due-$ip" 2>/dev/null
	pf_persist_save 1
	[ "$_sl" = 1 ] && exec 6>&-
	msg "ping filter: forgot $ip"
}

pf_scan() {
	pf_load_config
	_pf_scan_now
}
# A pass on demand. Off a terminal (an rpcd call) detached: probes and
# location lookups can outlast the call's timeout.
_pf_scan_now() {
	if [ -t 1 ]; then
		pf_scan_once
		return
	fi
	( _pf_title pf-scan; exec </dev/null >/dev/null 2>&1; pf_scan_once ) &
	echo "ping filter: scan started in the background - results show on the next refresh"
}


pf_status() {
	local st_run=0 st_set=0 st_aset=0 set_n=0 aset_n=0
	pf_is_running && st_run=1
	if nft list set $PF_FW_TABLE $PF_SET_NAME >/dev/null 2>&1; then
		st_set=1
		set_n=$(pf_block_ips | wc -l)
	fi
	if nft list set $PF_FW_TABLE $PF_ALLOWED_SET_NAME >/dev/null 2>&1; then
		st_aset=1
		aset_n=$(pf_allow_ips | wc -l)
	fi
	local total=0 blocked=0 allowed=0 wl=0 bl=0
	local real_count=0 distance_count=0
	if [ -f "$PF_SERVERS_TSV" ]; then
		# One awk for the seven counts: the daemon writes this report every
		# loop while a page shows it (_pf_status_file).
		# shellcheck disable=SC2046 # seven numbers, split on purpose
		set -- $(awk -F'\t' '
			{ t++
			  if ($2 == "blocked") b++; else if ($2 == "allowed") a++
			  else if ($2 == "whitelist") w++; else if ($2 == "blacklist") k++
			  if ($4 == "real" || $4 == "icmp") r++; else if ($4 == "distance") d++ }
			END { print t+0, b+0, a+0, w+0, k+0, r+0, d+0 }' "$PF_SERVERS_TSV" 2>/dev/null)
		total=${1:-0}; blocked=${2:-0}; allowed=${3:-0}; wl=${4:-0}; bl=${5:-0}
		real_count=${6:-0}; distance_count=${7:-0}
	fi
	echo "@@STATE@@"
	echo "version=$VERSION"
	set -- $GAMING_IP4 $GAMING_IP6
	echo "monitored=$*"
	echo "home_set=$([ -n "$PF_HOME_LAT" ] && [ -n "$PF_HOME_LON" ] && echo 1 || echo 0)"
	echo "geo_down=$(_pf_geo_is_down && echo 1 || echo 0)"
	echo "enabled=$PF_ENABLED"
	echo "master_enabled=$ENABLED"
	echo "running=$st_run"
	echo "fw_set_loaded=$st_set"
	echo "fw_allowed_set_loaded=$st_aset"
	echo "set_blocked_count=$set_n"
	echo "set_allowed_count=$aset_n"
	echo "threshold_ms=$PF_THRESHOLD_MS"
	echo "set_timeout=$PF_SET_TIMEOUT"
	echo "row_ttl=$PF_ROW_TTL"
	echo "block_mode=${PF_BLOCK_MODE:-ping}"
	echo "area_min=${PF_AREA_MIN:-0}"
	echo "match_end_wait=${PF_MATCH_END_WAIT:-30}"
	echo "hold_active=$(_pf_hold_on && echo 1 || echo 0)"
	echo "ping_catch_ms=${PF_PING_CATCH:-0}"
	echo "lite=${PF_LITE:-0}"
	echo "ping_var_pct=${PF_PING_VAR_PCT:-5}"
	echo "hs_rtt=${PF_HS_RTT:-0}"
	echo "probe_retries=${PF_PROBE_RETRIES:-0}"
	echo "auto_pin=${PF_AUTO_PIN:-0}"
	local _a24=""
	[ -f "$PF_RUN_DIR/.auto24" ] && read -r _a24 < "$PF_RUN_DIR/.auto24" 2>/dev/null
	echo "auto24=$_a24"
	echo "active_interval=$PF_ACTIVE_INTERVAL"
	echo "armed_interval=${PF_ARMED_INTERVAL:-1}"
	echo "countries=${PF_COUNTRIES}"
	echo "ignore_ports=${PF_IGNORE_NFT}"
	echo "mac_devices=${PF_MAC_MAP}"
	echo "mac_monitored=${PF_MAC_SEL}"
	echo "ipv6_graded=0"
	echo "offload=$(_pf_offload_on && echo 1 || echo 0)"
	echo "idle_interval=$PF_IDLE_INTERVAL"
	# Same source as the text below and the LuCI JSON (an existence test
	# could say idle while the text said active).
	local _act_state; _act_state=$(pf_activity_state)
	echo "activity=$_act_state"
	echo "total=$total"
	echo "blocked=$blocked"
	echo "allowed=$allowed"
	echo "whitelist=$wl"
	echo "blacklist=$bl"
	echo "real_count=$real_count"
	echo "distance_count=$distance_count"
	echo "gaming_ip4=$GAMING_IP4"
	local _prereq_miss
	_prereq_miss=$(pf_check_prereqs)
	if [ -n "$_prereq_miss" ]; then
		echo "prereq_ok=0"
		echo "prereq_missing=$_prereq_miss"
	else
		echo "prereq_ok=1"
		echo "prereq_missing="
	fi
	local _have_gaming=0 _have_home=0
	[ -n "$GAMING_IP4$GAMING_IP6$PF_MAC_SEL" ] && _have_gaming=1
	{ [ -n "$PF_HOME_LAT" ] && [ -n "$PF_HOME_LON" ]; } && _have_home=1
	echo "have_gaming_ip=$_have_gaming"
	echo "have_home_location=$_have_home"
	echo "home_lat=${PF_HOME_LAT}"
	echo "home_lon=${PF_HOME_LON}"
	echo "@@STATE_END@@"
	echo ""
	local activity_str="$_act_state"
	echo "=== Ping Filter ($DISPLAY_NAME v$VERSION) ==="
	echo "  Enabled:        $PF_ENABLED"
	echo "  Activity:       $activity_str"
	echo "  Daemon:         $([ "$st_run" = 1 ] && echo "running (pid $(cat "$PF_PID_FILE" 2>/dev/null))" || echo "stopped")"
	echo "  Blocked set:    $([ "$st_set"  = 1 ] && echo "loaded ($set_n IPs)"  || echo "not loaded")"
	echo "  Allowed set:    $([ "$st_aset" = 1 ] && echo "loaded ($aset_n IPs)" || echo "not loaded")"
	echo "  Ping Target:    ${PF_THRESHOLD_MS} ms"
	echo "  Block mode:     ${PF_BLOCK_MODE:-ping}"
	if [ "${PF_PING_CATCH:-0}" -gt 0 ] 2>/dev/null; then
		local _w _ao="" _ab=""
		for _w in $_a24; do
			case "$_w" in o:*) _ao="$_ao ${_w#o:}" ;; b:*) _ab="$_ab ${_w#b:}" ;; esac
		done
		echo "  Catch /24s:     allowed:${_ao:- none}  blocked:${_ab:- none}"
	fi
	echo "  Set timeout:    ${PF_SET_TIMEOUT} s"
	echo "  Row TTL:        ${PF_ROW_TTL} s (server memory, persisted)"
	echo "  Cadence:        active=${PF_ACTIVE_INTERVAL}s armed=${PF_ARMED_INTERVAL:-1}s idle=${PF_IDLE_INTERVAL}s"
	echo "  Recheck:        ${PF_RECHECK_INTERVAL}s"
	echo "  Geo lookup:     $PF_GEOIP_LOOKUP"
	_pf_offload_on && echo "  [!!] Flow offloading is ON: established game flows bypass the Ping Filter"
	echo "  Gaming IPv4:    ${GAMING_IP4:-(none)}"
	echo "  Prereqs:"
	if [ -n "$GAMING_IP4$GAMING_IP6$PF_MAC_SEL" ]; then
		echo "    [x] gaming device set${PF_MAC_SEL:+ (MAC: $PF_MAC_SEL)}"
	else
		echo "    [ ] gaming device — set on Setup → Devices & Ports, tick it in Ping Filter → Settings → Devices"
	fi
	if [ -n "$PF_HOME_LAT" ] && [ -n "$PF_HOME_LON" ]; then
		echo "    [x] home location: $PF_HOME_LAT, $PF_HOME_LON"
	else
		echo "    [ ] home location — set home_lat/home_lon on Ping Filter → Settings → Home"
	fi
	echo "  Servers cached: $total (allowed=$allowed blocked=$blocked wl=$wl bl=$bl)"
	echo "  Ping source:    real=$real_count distance=$distance_count"
}

pf_servers_json() {
	# stdout IS the JSON payload: anything the heal path prints goes to
	# stderr.
	local now wl bl activity
	now=$(date +%s)
	wl=$(echo "$PF_WHITELIST" | tr -s ' ' '\n' | grep -v '^$' | tr '\n' ' ')
	bl=$(echo "$PF_BLACKLIST" | tr -s ' ' '\n' | grep -v '^$' | tr '\n' ' ')
	# Off = no daemon verdict, and the fallback scans the whole conntrack
	# table on every poll for a card that says "off".
	if [ "$PF_ENABLED" = "1" ]; then activity=$(pf_activity_state); else activity="idle"; fi
	# play_start: the open play window's start (less one idle tick, so a
	# server first seen just before activity flipped counts); 0 once idle for
	# longer than map_keep.
	local ps=0 pw=0
	[ -f "$PF_RUN_DIR/.playwin" ] && read -r ps pw < "$PF_RUN_DIR/.playwin" 2>/dev/null
	case "$ps" in (''|*[!0-9]*) ps=0 ;; esac
	case "$pw" in (''|*[!0-9]*) pw=0 ;; esac
	if [ "$ps" -gt 0 ] && [ $((now - pw)) -le "${PF_MAP_KEEP:-3600}" ]; then
		ps=$((ps - ${PF_IDLE_INTERVAL:-30} * 2 - 5))
	else ps=0; fi

	# Stuck-matchmaking note from the daemon.
	local stuck=0 geod=0
	[ -f "$PF_RUN_DIR/.stuck" ] && read -r stuck _ < "$PF_RUN_DIR/.stuck" 2>/dev/null
	case "$stuck" in (''|*[!0-9]*) stuck=0 ;; esac
	_pf_geo_is_down && geod=1

	local hlat_q hlon_q
	case "$PF_HOME_LAT" in (''|*[!0-9.-]*) hlat_q="null" ;; (*) hlat_q="$PF_HOME_LAT" ;; esac
	case "$PF_HOME_LON" in (''|*[!0-9.-]*) hlon_q="null" ;; (*) hlon_q="$PF_HOME_LON" ;; esac
	local hr_q="${PF_HOME_RADIUS_KM:-1000}"
	case "$hr_q" in (''|*[!0-9.]*) hr_q="1000" ;; esac
	local bm_q="${PF_BLOCK_MODE:-ping}"

	local allow_pairs block_pairs
	allow_pairs=$(pf_allow_dump 2>/dev/null; pf_allow_dump6 2>/dev/null)   # "ip<TAB>expiry_sec"
	block_pairs=$(pf_block_dump 2>/dev/null; pf_block_dump6 2>/dev/null)

	local canon_tmp="$PF_RUN_DIR/.canon.$$"
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	{
		local ip
		for ip in $PF_WHITELIST; do
			[ -z "$ip" ] && continue
			printf 'W\t%s\t0\n' "$ip"
		done
		for ip in $PF_BLACKLIST; do
			[ -z "$ip" ] && continue
			printf 'L\t%s\t0\n' "$ip"
		done
		echo "$allow_pairs" | while IFS='	' read -r ip exp; do
			[ -z "$ip" ] && continue
			printf 'A\t%s\t%s\n' "$ip" "${exp:-0}"
		done
		echo "$block_pairs" | while IFS='	' read -r ip exp; do
			[ -z "$ip" ] && continue
			printf 'B\t%s\t%s\n' "$ip" "${exp:-0}"
		done
		# CACHED-BUT-UNENFORCED servers, after the enforced sources so the awk
		# SEEN-dedup lets WL / BL / allow / block win:
		#   T = a servers.tsv row whose kernel-set entry has lapsed
		# Shown as "cached", so everything learned can be re-added by hand.
		if [ -s "$PF_SERVERS_TSV" ]; then
			awk -F'\t' '$1 != "" { print "T\t" $1 "\t0" }' "$PF_SERVERS_TSV" 2>/dev/null
		fi
		#   H = a GRADED server (history row): stays until New game / Clear
		#   cache, even after its servers.tsv row ages out.
		if [ -s "$PF_TELE_HIST" ]; then
			awk -F'\t' '$1 != "" { print "H\t" $1 "\t0" }' "$PF_TELE_HIST" 2>/dev/null
		fi
	} > "$canon_tmp"

	if [ ! -s "$canon_tmp" ]; then
		printf '{"servers":[],"ts":%s,"threshold":%s,"enabled":%s,"master_enabled":%s,"activity":"%s","home_lat":%s,"home_lon":%s,"home_radius_km":%s,"block_mode":"%s","active_pps":%s,"ping_catch":%s,"ping_var_pct":%s,"whitelist_ips":"%s","blacklist_ips":"%s","play_start":%s,"map_keep":%s,"stuck":%s,"countries":"%s","geo_down":%s}\n' \
			"$now" "${PF_THRESHOLD_MS:-50}" "${PF_ENABLED:-0}" "${ENABLED:-0}" "$activity" \
			"$hlat_q" "$hlon_q" "$hr_q" "$bm_q" "${PF_ACTIVE_PPS:-20}" "${PF_PING_CATCH:-0}" "${PF_PING_VAR_PCT:-5}" "$wl" "$bl" "$ps" "${PF_MAP_KEEP:-3600}" \
			"$stuck" "$(printf '%s' "$PF_COUNTRIES" | sed 's/[\\"]//g')" "$geod"
		rm -f "$canon_tmp" 2>/dev/null
		return
	fi

	[ -f "$PF_SERVERS_TSV" ] || : > "$PF_SERVERS_TSV"
	[ -f "$PF_GEO_CACHE" ] || : > "$PF_GEO_CACHE"

	PF_J_CO="$PF_COUNTRIES" \
	awk -F'\t' -v now="$now" -v thr="${PF_THRESHOLD_MS:-50}" \
	    -v stuck="$stuck" -v geod="$geod" \
	    -v en="${PF_ENABLED:-0}" -v men="${ENABLED:-0}" -v act="$activity" \
	    -v wl="$wl" -v bl="$bl" \
	    -v ttl_disp="${PF_SET_TIMEOUT:-43200}" \
	    -v hlat="$hlat_q" -v hlon="$hlon_q" -v hr="$hr_q" -v bm="$bm_q" \
	    -v apps_cfg="${PF_ACTIVE_PPS:-20}" -v pcatch="${PF_PING_CATCH:-0}" -v pvar="${PF_PING_VAR_PCT:-5}" -v cmp="${PF_CONN_MIN_PPS:-10}" \
	    -v tsv_file="$PF_SERVERS_TSV" \
	    -v geo_file="$PF_GEO_CACHE" \
	    -v live_file="$PF_LIVE_TSV" \
	    -v hist_file="$PF_TELE_HIST" -v owner_file="$PF_OWNER_TSV" -v pfx_file="$PF_PREFIX_TSV" \
	    -v pfx_ttl="${PF_PREFIX_TTL:-0}" -v pstart="$ps" -v mkeep="${PF_MAP_KEEP:-3600}" '
	# Escapes by concatenation, never a gsub replacement string (BusyBox
	# 1.38 awk drops the backslash of "\\\"" there -> invalid JSON).
	function jesc(s,    o, i, c) {
		gsub(/\t/, " ", s); gsub(/\r/, "", s); gsub(/\n/, " ", s)
		o = ""
		while ((i = match(s, /[\\"]/)) > 0) {
			c = substr(s, i, 1)
			o = o substr(s, 1, i - 1) "\\" c
			s = substr(s, i + 1)
		}
		return o s
	}
	'"$PF_HAV_AWK"'
	function num(s) {
		if (s == "" || s !~ /^-?[0-9]+(\.[0-9]+)?$/) return "0"
		return s
	}
	BEGIN {
		nw = split(wl, WA, /[ \t]+/);  for (i = 1; i <= nw; i++) if (WA[i] != "") WL[WA[i]] = 1
		nb = split(bl, BA, /[ \t]+/);  for (i = 1; i <= nb; i++) if (BA[i] != "") BL[BA[i]] = 1
		while ((getline ln < tsv_file) > 0) {
			n = split(ln, F, "\t")
			if (n >= 10 && F[1] != "") {
				TSV_META[F[1]] = F[2] "\t" F[3] "\t" F[4] "\t" F[5] "\t" F[6] "\t" F[7] "\t" F[8] "\t" F[9] "\t" F[10] "\t" F[11] "\t" F[12]
			}
		}
		close(tsv_file)
		while ((getline ln < geo_file) > 0) {
			n = split(ln, F, "\t")
			if (n >= 5 && F[1] != "") {
				GEO[F[1]] = F[2] "\t" F[3] "\t" F[4] "\t" F[5]
			}
		}
		close(geo_file)
		while ((getline ln < live_file) > 0) {
			n = split(ln, F, "	")
			if (n >= 8 && F[1] != "")
				LIVE[F[1]] = F[2] "	" F[3] "	" F[4] "	" F[5] "	" F[6] "	" F[7] "	" ((n >= 9) ? F[9] : "0") "	" ((n >= 10 && F[10] != "") ? F[10] : "-1")
		}
		close(live_file)
		while ((getline ln < hist_file) > 0) {
			n = split(ln, F, "\t")
			if (n >= 10 && F[1] != "")
				HIST[F[1]] = F[2] "\t" F[4] "\t" F[5] "\t" F[6] "\t" F[9] "\t" F[3] "\t" F[7]
		}
		close(hist_file)
		while ((getline ln < owner_file) > 0) {
			n = split(ln, F, "\t")
			if (n >= 2 && F[1] != "") GN[F[1]] = F[2]
		}
		close(owner_file)
		if (pfx_ttl + 0 > 0) {
			while ((getline ln < pfx_file) > 0) {
				n = split(ln, F, "\t")
				if (n >= 9 && F[4] + 0 > 0 && (now - F[9]) < pfx_ttl + 0) PB[F[1]] = F[4] + 0
			}
			close(pfx_file)
		}
		printf "{\"servers\":["
		first = 0
	}
	NF >= 2 && $2 != "" && !($2 in SEEN) {
		SEEN[$2] = 1
		tag        = $1
		ip         = $2
		ipset_exp  = $3 + 0

		meta       = TSV_META[ip]
		# A MANUAL pin is a statement of intent, not an observation. Until we
		# have actually measured the address it has nothing to show -- no
		# ping, no score, no honest position -- so it stays out of the
		# discovered list and off the map. Evidence is a servers.tsv row, a
		# graded telemetry row. Setting SEEN
		# above means skipping here also suppresses the A/B echo of the same
		# address from the kernel sets, which is the point: whitelisting an
		# IP adds it to @ping_allowed immediately, and that alone is not
		# evidence that anything was ever probed.
		if ((ip in WL || ip in BL) && meta == "" && HIST[ip] == "") next
		state = ""; ping = 0; ping_src = "distance"; lat = ""; lon = ""
		country = ""; city = ""; ts = 0; lan_src = ""; jit = 0; loss_p = 0
		if (meta != "") {
			n = split(meta, M, "\t")
			if (n >= 9) {
				state = M[1]; ping = M[2] + 0; ping_src = M[3]
				lat = M[4]; lon = M[5]; country = M[6]; city = M[7]
				ts  = M[8] + 0; lan_src = M[9]
			}
			# Col 12 holds the handshake connect count: "loss" stays 0.
			if (n >= 10) jit    = M[10] + 0
		}
		if (lat == "" || lat == "0" || lon == "" || lon == "0") {
			g = GEO[ip]
			if (g != "") {
				ng = split(g, GG, "\t")
				if (ng >= 4) {
					lat = GG[1]; lon = GG[2]
					if (country == "") country = GG[3]
					if (city    == "") city    = GG[4]
				}
			}
		}

		tsv_state = state
		if      (tag == "W") state = "whitelist"
		else if (tag == "L") state = "blacklist"
		else if (tag == "A") state = "allowed"
		else if (tag == "B") state = "blocked"
		else if (tag == "T" || tag == "H") state = "cached"
		is_cached = (tag == "T" || tag == "H") ? "true" : "false"
		# A row with LIVE traffic must not read "cached": a set-add hiccup
		# must not hide a server the user is mid-game on.
		# Liveness = the row timestamp (col 9), which the scan refreshes on
		# every live @pf_seen sighting — fresh ts means packets are flowing
		# NOW. Such rows resurface with their graded TSV state (allowed/
		# blocked) so the operator sees the real verdict, not a grey ghost.
		if (is_cached == "true" && ts > 0 && (now - ts) < 30 && tsv_state != "") {
			is_cached = "false"
			state = tsv_state
		}

		# 2.0.4.2: a measured allow stays in the kernel for row_ttl; one not
		# seen within set_timeout still reads "cached" (counts, re-add).
		if (tag == "A" && (now - ts) > ttl_disp + 0) {
			state = "cached"; is_cached = "true"
		}
		if (tag == "A" || tag == "B") expiry_remaining = ipset_exp
		else                          expiry_remaining = 0

		age = (ts > 0) ? (now - ts) : 0

		# connected = the row was refreshed by a live @pf_seen sighting within
		# 15s — packets are flowing NOW. Deliberately verdict-independent: a
		# graded-blocked server the console is mid-game on (pending
		# promotion) must still surface as the connected server; its
		# state column carries the verdict.
		is_conn = (ts > 0 && age < 15) ? "true" : "false"

		h_sess = 0; h_jit = 0; h_jmax = 0; h_loss = 0; h_pps = 0; h_dur = 0; h_gaps = 0
		if (ip in HIST) {
			nh = split(HIST[ip], HV, "\t")
			if (nh >= 4) { h_sess = HV[1] + 0; h_jit = HV[2] + 0; h_jmax = HV[3] + 0; h_loss = HV[4] + 0 }
			if (nh >= 5) h_pps = HV[5] + 0
			if (nh >= 7) { h_dur = HV[6] + 0; h_gaps = HV[7] + 0 }
		}
		l_pps = 0; l_bps = 0; l_jit = 0; l_gmax = 0; l_gaps = 0; l_stall = 0; l_loss = 0; l_tele = "false"; l_lv = -1
		if (ip in LIVE) {
			nl = split(LIVE[ip], LV, "	")
			if (nl >= 6) { l_pps = LV[1] + 0; l_bps = LV[2] + 0; l_jit = LV[3] + 0;
				l_gmax = LV[4] + 0; l_gaps = LV[5] + 0; l_stall = LV[6] + 0; l_tele = "true" }
			if (nl >= 7) l_loss = LV[7] + 0
			# lv: the last raw in-play reading, ms (-1 none).
			if (nl >= 8 && LV[8] + 0 > 0) l_lv = LV[8] + 0
		}
		# "connected" means the server being PLAYED, not every live UDP
		# endpoint. Require sustained gameplay pps (cmp) so relay / voice /
		# matchmaking chatter reads as "discovered", not connected.
		if (is_conn == "true" && l_pps < cmp) is_conn = "false"
		# Physics check: the /24 distance bound vs the plotted location.
		bkm = 0; gsus = "false"; pk = ip; sub(/\.[0-9]+$/, "", pk)
		if (ip !~ /:/ && (pk in PB)) {
			bkm = PB[pk]
			if (hlat != "null" && hlon != "null" && lat != "" && lon != "" && (lat + 0 != 0 || lon + 0 != 0)) {
				d = hav(hlat + 0, hlon + 0, lat + 0, lon + 0)
				if (d > bkm + 100) gsus = "true"
			}
		}
		if (first++) printf ","
		printf "{\"ip\":\"%s\",\"state\":\"%s\",\"cached\":%s,\"ping\":%d,\"ping_src\":\"%s\",\"ping_source\":\"%s\",\"jitter\":%d,\"loss\":%d,\"lat\":%s,\"lon\":%s,\"country\":\"%s\",\"city\":\"%s\",\"ts\":%d,\"src\":\"%s\",\"connected\":%s,\"expiry_remaining_sec\":%d,\"proto\":\"udp\",\"fam\":\"" (ip ~ /:/ ? "v6" : "v4") "\",\"bps\":%d,\"bytes\":0,\"pps\":%d,\"jitter_live\":%d,\"gap_max\":%d,\"gaps\":%d,\"stall\":%d,\"loss_live\":%d,\"lv\":%d,\"tele\":%s,\"hist_sessions\":%d,\"hist_jitter\":%d,\"hist_jitter_max\":%d,\"hist_loss\":%d,\"hist_pps\":%d,\"hist_dur\":%d,\"hist_gaps\":%d,\"bound_km\":%d,\"geo_suspect\":%s,\"gname\":\"%s\",\"unreach_reason\":\"\"}",
			jesc(ip), jesc(state), is_cached, ping, jesc(ping_src), jesc(ping_src),
			jit, loss_p, num(lat), num(lon), jesc(country), jesc(city),
			ts, jesc(lan_src), is_conn, expiry_remaining,
			l_bps, l_pps, l_jit, l_gmax, l_gaps, l_stall, l_loss, l_lv, l_tele,
			h_sess, h_jit, h_jmax, h_loss, h_pps, h_dur, h_gaps, bkm, gsus, jesc(GN[ip])
	}
	END {
		printf "],\"ts\":%s,\"threshold\":%s,\"enabled\":%s,\"master_enabled\":%s,\"activity\":\"%s\",\"home_lat\":%s,\"home_lon\":%s,\"home_radius_km\":%s,\"block_mode\":\"%s\",\"active_pps\":%s,\"ping_catch\":%s,\"ping_var_pct\":%s,\"whitelist_ips\":\"%s\",\"blacklist_ips\":\"%s\",\"play_start\":%s,\"map_keep\":%s,\"stuck\":%d,\"countries\":\"%s\",\"geo_down\":%d}\n", \
			now, thr, en, men, act, hlat, hlon, hr, jesc(bm), apps_cfg, pcatch + 0, pvar + 0, jesc(wl), jesc(bl), pstart + 0, mkeep + 0, stuck + 0, jesc(ENVIRON["PF_J_CO"]), geod + 0
	}
	' "$canon_tmp" 2>/dev/null

	rm -f "$canon_tmp" 2>/dev/null
}

# One-tap presets. Each writes UCI, reloads config and re-grades:
#   competitive — ping mode, 40 ms limit
#   casual      — ping mode, 80 ms limit
#   distance    — distance mode (its radius and Ping Catch as they are)
#   observe     — watch only: ping mode, no limit (graded and recorded; only
#                 the blacklist and a country list block)
#   custom      — report current settings, change nothing (also: no name)
# Only the mode and the ping presets' limit are written; never Ping Catch.
# The user's own change: lands at once (PF_USER_NOW, inherited by the
# background re-grade).
pf_profile() {
	local prof="$1" mode=ping thr=0 PF_USER_NOW=1
	case "$prof" in
		competitive) thr=40 ;;
		casual)      thr=80 ;;
		distance)    mode=distance; thr="" ;;
		observe)     ;;
		custom|"")
			echo "mode=${PF_BLOCK_MODE:-ping} threshold=${PF_THRESHOLD_MS:-0}ms catch=${PF_PING_CATCH:-0}ms"
			return 0
			;;
		*)
			err "unknown profile '$prof' (competitive|casual|distance|observe|custom)"
			return 1
			;;
	esac
	uci set "$UCI_CFG.pingfilter.block_mode=$mode"
	[ -n "$thr" ] && uci set "$UCI_CFG.pingfilter.threshold_ms=$thr"
	uci commit "$UCI_CFG"
	pf_load_config
	# Limit changed without a reload: the hold rule follows.
	pf_table_present && pf_table_install >/dev/null 2>&1
	# The re-grade's phase 2 re-pings every cached server (10-60 s of ICMP):
	# inside the rpcd call it stalls the UI. The config is already committed:
	#   - interactive CLI (stdout is a tty): run inline, keep the receipt
	#   - rpc / scripted: detach to background, return immediately
	if [ -t 1 ]; then
		msg "profile '$prof' applied — re-grading cached servers"
		pf_reclassify_now
	else
		msg "profile '$prof' applied — re-grading cached servers in background"
		# exec form: plain `cmd >/dev/null &` keeps ash's saved copy of stdout
		# open in the child, and the rpcd pipe would not close.
		( _pf_title pf-reclassify; exec </dev/null >/dev/null 2>&1; pf_reclassify_now ) &
	fi
}

pf_connected_ip() {
	# Best effort: the public UDP server the console talks to most right now
	# (busiest inbound flow from a gaming source). Empty when none. Sends
	# nothing.
	[ -r "$PF_CT_PROC" ] || return 0
	[ -n "${GAMING_IP4:-}" ] || return 0
	awk -v srcs="$GAMING_IP4" '
		BEGIN { n = split(srcs, S, " "); for (k = 1; k <= n; k++) IS[S[k]] = 1 }
		/udp/ {
			sip = ""; dip = ""; np = 0
			for (i = 1; i <= NF; i++) {
				if      (substr($i, 1, 4) == "src=" && sip == "") sip = substr($i, 5)
				else if (substr($i, 1, 4) == "dst=" && dip == "") dip = substr($i, 5)
				else if (substr($i, 1, 8) == "packets=") { np++; P[np] = substr($i, 9) + 0 }
			}
			# Original tuple: src=gaming, dst=server. 2nd packets= = reply (inbound).
			if (IS[sip] && dip != "")
				T[dip] += (np >= 2) ? P[2] : (np >= 1 ? P[1] : 0)
		}
		END { best = -1; bi = ""; for (a in T) if (T[a] > best) { best = T[a]; bi = a }
		      if (bi != "") print bi }
	' "$PF_CT_PROC" 2>/dev/null
}

pf_livecap() {
	# On-demand, BOUNDED live-flow report for one server (default: the one
	# being played): the passive tcpdump tap and conntrack counters over one
	# window. Nothing is sent to the server. Not a standing process.
	local ip="$1" secs="${2:-10}"
	case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
	[ "$secs" -lt 3 ]  2>/dev/null && secs=3
	[ "$secs" -gt 30 ] 2>/dev/null && secs=30

	[ -z "$ip" ] && ip=$(pf_connected_ip)
	if [ -n "$ip" ] && [ -z "$(pf_ip_family "$ip")" ]; then
		err "live capture: invalid IP address: $ip"; return 1
	fi
	if [ -z "$ip" ]; then
		echo "live capture: no server given and no active game flow detected."
		echo "  usage: $0 livecap [ip] [seconds]"
		return 1
	fi

	# Graded-cache metadata (country / city / ping / verdict), if present.
	local co="?" ci="?" cping="" csrc="" cstate="ungraded" chow row
	row=""
	[ -f "$PF_SERVERS_TSV" ] && row=$(awk -v ip="$ip" -F'\t' '$1 == ip { print; exit }' "$PF_SERVERS_TSV")
	if [ -n "$row" ]; then
		_pf_row "$row"
		co=${PF_C_CO:-?}; ci=${PF_C_CI:-?}; cping=$PF_C_PING; csrc=$PF_C_SRC
		cstate=${PF_C_STATE:-ungraded}
	fi
	# Which rung of the ladder produced the graded figure (servers.tsv col 4).
	case "$csrc" in
		icmp)     chow="ICMP echo (measured)" ;;
		real)     chow="handshake RTT (measured)" ;;
		prefix)   chow="estimate, measured server in the same /24" ;;
		area)     chow="estimate, measured server within ${PF_AREA_KM}km" ;;
		distance) chow="estimate, distance from home" ;;
		*)        chow="none yet (pending)" ;;
	esac

	local dport rttline rtt rttsrc
	# Diagnostic output only: which port the console is really on, for a
	# capture set up by hand.
	dport=$(pf_game_dport "$ip")
	rttline=$(pf_rtt_probe "$ip"); rtt=${rttline%%	*}; rttsrc=${rttline#*	}
	[ "$rtt" = "$rttline" ] && rttsrc=""

	# Single capture window: read counters, run the tap (blocks ~secs), read
	# counters again -> pps/bps delta over the exact same window.
	local have_td=0; command -v tcpdump >/dev/null 2>&1 && have_td=1
	local c0 p0 b0 c1 p1 b1 sample jit gmax gaps
	c0=$(pf_flow_counters "$ip"); p0=${c0%%	*}; b0=${c0#*	}
	[ "$p0" = "$c0" ] && { p0=""; b0=""; }
	if [ "$have_td" = 1 ]; then
		sample=$(pf_udp_sample "$ip" "$secs")
	else
		sleep "$secs"
	fi
	c1=$(pf_flow_counters "$ip"); p1=${c1%%	*}; b1=${c1#*	}
	[ "$p1" = "$c1" ] && { p1=""; b1=""; }

	local pps="n/a" kbps="n/a"
	if [ -n "$p0" ] && [ -n "$p1" ] && [ "$secs" -gt 0 ]; then
		local dp db; dp=$((p1 - p0)); db=$((b1 - b0))
		[ "$dp" -lt 0 ] && dp=0; [ "$db" -lt 0 ] && db=0
		pps=$((dp / secs)); kbps=$(((db * 8) / 1000 / secs))
	fi

	jit="n/a"; gmax="n/a"; gaps="n/a"
	if [ "$have_td" = 1 ] && [ -n "$sample" ]; then
		jit=${sample%%	*};  sample=${sample#*	}
		gmax=${sample%%	*}; sample=${sample#*	}
		gaps=$sample
	fi

	# Assessment mirrors the interpretation table: idle > gaps > jitter > ok.
	local verdict
	if [ "$pps" != "n/a" ] && [ "$pps" -eq 0 ] 2>/dev/null; then
		verdict="no inbound traffic — flow idle or interrupted"
	elif [ "$gaps" != "n/a" ] && { [ "$gaps" -gt 0 ] 2>/dev/null || [ "${gmax:-0}" -gt 150 ] 2>/dev/null; }; then
		verdict="gaps present — routing hiccup or congestion"
	elif [ "$jit" != "n/a" ] && [ "$jit" -gt 15 ] 2>/dev/null; then
		verdict="elevated jitter — congestion or queueing"
	elif [ "$pps" = "n/a" ] && [ "$jit" = "n/a" ]; then
		verdict="inconclusive — no counters and no capture available"
	else
		verdict="healthy — stable cadence, low jitter, no gaps"
	fi

	local iface="${PF_WAN:-pppoe-wan}"
	echo    "===================================================================="
	printf  " %s — live flow report (v%s)\n" "$DISPLAY_NAME" "$VERSION"
	echo    "===================================================================="
	printf  " Server      : %s  (%s, %s)\n" "$ip" "$ci" "$co"
	printf  " Verdict     : %s\n" "$cstate"
	if [ "$cping" -gt 0 ] 2>/dev/null; then
		printf " Graded ping : %s ms — %s\n" "$cping" "$chow"
	else
		printf " Graded ping : %s\n" "$chow"
	fi
	if [ -n "$rttsrc" ]; then
		printf " ICMP now    : %s ms\n" "$rtt"
	else
		echo  " ICMP now    : no reply"
	fi
	printf  " Game dport  : %s/udp\n" "${dport:-?}"
	printf  " Capture     : %ss on %s (passive tap — nothing sent)\n" "$secs" "$iface"
	echo    " --------------------------------------------------------------"
	if [ "$pps" = "n/a" ]; then
		echo  " Inbound pps : n/a (enable acct: sysctl net.netfilter.nf_conntrack_acct=1)"
	else
		printf " Inbound pps : %s\n" "$pps"
		printf " Inbound rate: %s kbps\n" "$kbps"
	fi
	if [ "$have_td" != 1 ]; then
		echo  " Jitter/gaps : n/a (install tcpdump for the passive jitter tap)"
	else
		printf " Jitter (avg): %s ms\n" "$jit"
		printf " Max gap     : %s ms\n" "$gmax"
		printf " Gaps>%sms  : %s\n" "${PF_GAP_MS:-120}" "$gaps"
	fi
	echo    " --------------------------------------------------------------"
	printf  " Assessment  : %s\n" "$verdict"
	echo    "===================================================================="
}

pf_dispatch() {
	# Log user-visible actions to the PF log. Every mutating verb lands here
	# from the CLI and the LuCI pf_action rpc. Read-only verbs and the
	# internal _daemon_* entries are not logged; the daemon's own calls bypass
	# dispatch.
	case "${1:-}" in
		start|stop|restart|reload|scan|clear|session_reset|reclassify|refresh_lists|enable|disable|whitelist|blacklist|forget|ungrade|clear_wl|clear_bl|list_clear|threshold|radius|catch|mode|profile|mark)
			_logline "INFO" "pingfilter: $1${2:+ $2}${3:+ $3}"
			;;
	esac
	case "${1:-help}" in
		start)     pf_start ;;
		# PF_DAEMON=1 silences terminal writes in msg() / err(). Set HERE
		# only, so no CLI path can go quiet.
		_daemon_supervised) PF_DAEMON=1; pf_daemon_supervised ;;   # internal: procd-supervised foreground entry
		# A runtime Stop must survive procd's respawn (~5 s): .stopped (tmpfs)
		# parks it until start / restart / enable.
		stop)      mkdir -p "$PF_RUN_DIR" 2>/dev/null; : > "$PF_RUN_DIR/.stopped"; pf_stop ;;
		restart)   pf_stop; sleep 1; pf_start ;;
		reload)    pf_reload ;;
		scan)      pf_scan ;;
		status)    pf_status ;;
		servers)   pf_servers_json ;;
		devices)   pf_devices_list ;;
		telemetry) pf_telemetry_json "$2" ;;
		matchmaking) pf_mm_json ;;
		grades)    [ -f "$PF_TELE_HIST" ] && { echo "# ip sessions dur jit_ewma jit_max loss_ewma gaps stalls pps last_ts"; cat "$PF_TELE_HIST"; } || echo "(no session history yet)" ;;
		dump)
			echo "# Cache file: $PF_SERVERS_TSV"
			echo "# Lines:      $([ -f "$PF_SERVERS_TSV" ] && wc -l < "$PF_SERVERS_TSV" || echo "(missing)")"
			echo "# Whitelist:  ${PF_WHITELIST:-(none)}"
			echo "# Blacklist:  ${PF_BLACKLIST:-(none)}"
			echo "# Enabled:    ${PF_ENABLED:-?}"
			echo "# Threshold:  ${PF_THRESHOLD_MS:-?} ms"
			echo "# Gaming v4:  ${GAMING_IP4:-(none)}"
			echo "# Monitored:  ${PF_DEVICES:-(NONE ticked — PF off)}"
			echo "# --- Cache (first 10) ---"
			[ -f "$PF_SERVERS_TSV" ] && head -10 "$PF_SERVERS_TSV" || echo "(no cache yet)"
			echo "# --- Block set (kernel) ---"
			pf_block_dump
			echo "# --- JSON output ---"
			pf_servers_json
			;;
		clear)     pf_clear_cache ;;
		session_reset) pf_session_reset ;;
		reclassify) pf_reclassify_now ;;
		profile)   pf_profile "$2" ;;
		sessions)  pf_sessions_json ;;
		geo_check) pf_geo_check "$2" ;;
		refresh_lists) pf_refresh_lists ;;
		enable)    pf_set_enabled enable ;;
		disable)   pf_set_enabled disable ;;
		whitelist) pf_mark_state "$2" "whitelist" ;;
		blacklist) pf_mark_state "$2" "blacklist" ;;
		forget)    pf_forget_ip "$2" ;;
		ungrade)   pf_ungrade_ip "$2" ;;
		clear_wl)  pf_list_clear whitelist ;;
		clear_bl)  pf_list_clear blacklist ;;
		list_clear) pf_list_clear "$2" ;;
		threshold) pf_set_threshold "$2" ;;
		radius)    pf_set_radius "$2" ;;
		catch)
			case "$2" in (''|*[!0-9]*) err "usage: pf catch <ms>  (0 = off)"; return 1 ;; esac
			# Match the load_config clamp.
			[ "$2" -le 250 ] 2>/dev/null || { err "catch out of range (0-250 ms)"; return 1; }
			[ "$2" = "0" ] || [ "$PF_BLOCK_MODE" = "distance" ] \
				|| { err "ping catch is a distance-mode setting (block_mode is ping)"; return 1; }
			uci set $UCI_CFG.pingfilter.ping_catch_ms="$2"; uci commit $UCI_CFG
			# A live control, as pf_set_threshold: lands at once.
			PF_USER_NOW=1
			pf_load_config; msg "ping catch limit set to ${2}ms"; pf_reload ;;
		mode)      pf_set_mode "$2" ;;
		mark)      pf_mark_state "$2" "$3" ;;
		nfterr)    [ -f "$PF_NFT_ERR" ] && cat "$PF_NFT_ERR" || echo "(no recent ping filter NFT error)" ;;
		verify)       pf_verify_install ;;
		livecap)   pf_livecap "$2" "$3" ;;
		*)
			cat <<EOF
Ping Filter — part of QoS-Ex
Usage: $0 {start|stop|restart|reload|status|servers|scan}
       $0 {enable|disable}
       $0 threshold <ms>          # ping limit (ping mode), 0 = watch only
       $0 mode <ping|distance>
       $0 radius <km>             # distance mode
       $0 catch <ms>              # distance mode: also let in servers outside the radius at or under ms
       $0 profile <competitive|casual|distance|observe>
       $0 profile                 # show the current profile
       $0 {whitelist|blacklist} <IPv4 | a.b.c.d/len>
       $0 forget <ip | a.b.c.d/len>
       $0 mark <IPv4> <allowed|blocked|whitelist|blacklist>
       $0 {clear_wl|clear_bl}     # empty a list
       $0 list_clear <whitelist|blacklist>
       $0 refresh_lists           # re-ping and re-locate the list IPs
       $0 ungrade <ip>            # drop a server's play grade
       $0 session_reset           # new game: drop the servers, keep locations and lists
       $0 clear                   # fresh start: servers, grades, locations, /24 memory
       $0 reclassify              # re-grade the cache against the current settings
       $0 sessions                # play history (JSON)
       $0 telemetry <ip>          # live pps / jitter of one server (JSON)
       $0 livecap [ip] [secs]     # one-shot live flow report
       $0 geo_check <ip>          # why a location lookup fails
       $0 {verify|nfterr|devices|dump|grades}
       $0 matchmaking             # TCP/443 flows of the gaming devices (JSON)
       $0 {install|uninstall|version}

Devices
  Ping Filter watches the gaming devices ticked in Ping Filter -> Settings
  -> Devices (qos-ex.pingfilter.pf_devices), out of the gaming devices on
  Setup -> Devices & Ports (gaming_ipv4, gaming_ipv6, gaming_mac). Nothing
  ticked = Ping Filter off.
  A device named by MAC is followed to whatever IPv4 it holds.
  IPv6 game servers are not graded: an IPv6 server is filtered only by a
  whitelist or blacklist entry in UCI (the whitelist and blacklist verbs
  take IPv4 only).

Kernel side
  One nft table, $PF_FW_TABLE, holds everything: the monitored devices, the
  servers seen (the kernel records every public UDP server a device talks
  to, at packet level), the allow and block sets, and the two chains that
  fill and enforce them. Nothing is written to /etc/config/firewall.
  The enforce chain runs ahead of the firewall's own forward chain, so a
  block also stops a flow that is already up; the conntrack entry of a
  newly blocked server is deleted for the monitored devices. A block drops
  UDP only: TCP to the same address (logins, store) still passes.
  UDP ports in ignore_ports (now: ${PF_IGNORE_NFT:-none}) are never treated as
  a game server.

How a new server is graded (ping mode)
  1. New servers: the first first_pkts (now ${PF_FIRST_PKTS:-2}) packets of
     each flow pass, so the game's own first request -> first reply is timed
     (needs conntrack); the rest wait until it is graded. first_pkts 0: no
     hold, a new server is allowed until graded.
  2. An ICMP burst is sent (the median counts; it gives up at 2 s). Silent
     hosts, and hosts blocked on their own echo, are re-probed up to
     $PF_PROBE_RETRIES times while live.
  3. No echo: an estimate is used instead -- the lowest measured server in
     the same /24, then the median of $PF_AREA_MIN+ measured servers within
     $PF_AREA_KM km lowered area_adjust_pct (else the nearest one), then
     distance from home as the last resort.
  Every reading is an upper bound: a server takes a lower one, never a
  higher one (Re-check cache and its play may raise it). An estimate is the
  last resort: a handshake replaces it, except one over the limit from one
  connect while the estimate is under it (with no limit: one over twice the
  estimate + 50 ms); on two connects it lands, over the limit = confirmed
  over. A reading passes at <= limit + ping_var_pct percent.
  threshold_ms 0 = watch only: pings shown, nothing blocked but the
  blacklist and a country list.

Distance mode
  ping_catch_ms 0: the radius decides. New servers are held until located;
  when no location can come (lookups off or down), a server's own ping is
  held to the radius in ms (this link's distance model).
  ping_catch_ms > 0: the radius lets servers in, the catch adds those
  outside it at or under ping_catch_ms. A server inside the radius is
  allowed whatever its ping (block a bad one by hand). Outside it: its own
  reading at or under the catch allows it; confirmed over blocks it; else
  its group ($PF_AREA_KM km, or its /24): more under the catch than
  confirmed over, with one in its /24 or auto_pin in the area, allows it
  (an echo over the catch counts on neither side); auto_pin confirmed over
  and none under blocks it. Not located yet: allowed until it is. New
  servers wait as in ping mode.

Either mode
  allow_country: when set, a server in any other country is blocked, and
  every new server is held until located and graded (with lookups off, one
  with no reading yet is let in to be graded).
  auto_pin (default 2): a /24 with that many whitelist (or blacklist) hosts
  is put on the list as a prefix.
  A server being played is not cut: a block found while it is in session
  waits until $PF_MATCH_END_WAIT seconds after its last packet. In session:
  its packets reached game rate (a flow it opened through a port forward
  counts), or it is new while another server of the same device was at
  game rate in the last 5 s (a handoff: its first verdict waits too).
  ignore_ports never count. A change from the live controls (mode, limit,
  radius, catch, profile, Re-check cache) lands at once. With telemetry, a
  server is graded on its play: at the end of a stretch with enough
  in-play readings its median becomes its figure, or, carried by its
  group, two slow stretches block it. A stop or restart mid-match grades
  nothing.

Config: /etc/config/qos-ex -> config pingfilter 'pingfilter'
History and caches: $PF_PERSIST_DIR
EOF
			;;
	esac
}

install_self() {
	local prev=""
	[ -x "$PF_BIN" ] && prev=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$PF_BIN" 2>/dev/null | head -n1)
	mkdir -p "$(dirname "$PF_BIN")" 2>/dev/null
	# From the installed copy, install is a no-op (cp refuses same-file).
	# Staged then renamed: an rpcd call mid-copy would run half a script. A
	# running daemon keeps the old inode until restart.
	if [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$PF_BIN" ]; then
		local stage="$PF_BIN.new.$$"
		if ! { cp "$0" "$stage" 2>/dev/null && chmod 755 "$stage" && mv -f "$stage" "$PF_BIN"; }; then
			rm -f "$stage" 2>/dev/null
			err "install: cannot write $PF_BIN"; return 1
		fi
	fi
	chmod 755 "$PF_BIN"
	mkdir -p "$PF_PERSIST_DIR" 2>/dev/null
	# Activity is rate-based on conntrack counters. The daemon sets this at
	# runtime; sysctl.d applies it at boot.
	if [ "$(cat "$PF_SYSCTL" 2>/dev/null)" != "net.netfilter.nf_conntrack_acct=1" ]; then
		mkdir -p /etc/sysctl.d 2>/dev/null
		echo "net.netfilter.nf_conntrack_acct=1" > "$PF_SYSCTL" 2>/dev/null
	fi
	if [ -n "$prev" ] && [ "$prev" != "$VERSION" ]; then
		msg "upgraded v$prev -> v$VERSION ($PF_BIN)"
	elif [ -n "$prev" ]; then
		msg "reinstalled v$VERSION ($PF_BIN)"
	else
		msg "installed v$VERSION ($PF_BIN) - turn it on in Ping Filter > Settings"
	fi
	return 0
}

uninstall_self() {
	pf_load_config
	# Take the daemon out of procd first. Left registered, it is respawned 5 s
	# after pf_stop kills it (and puts the table back), then respawned forever
	# on a binary that is gone. Not registered (the full uninstall stopped the
	# service first): a no-op.
	rm -f "$PF_RUN_DIR/.procd" 2>/dev/null
	command -v ubus >/dev/null 2>&1 && \
		ubus call service delete '{"name":"QoS-Ex","instance":"pingfilter"}' >/dev/null 2>&1
	pf_stop >/dev/null 2>&1
	pf_uninstall_fw_rules >/dev/null 2>&1
	# $PF_RUN_DIR is tmpfs scratch: take it with us.
	rm -rf "$PF_RUN_DIR" 2>/dev/null
	# Its nft error files, and the old /tmp locations.
	rm -f "$PF_NFT_ERR" "$PF_NFT_ERR".* 2>/dev/null
	_pf_old_tmp_cleanup
	rm -f "$PF_BIN" "$PF_SYSCTL" 2>/dev/null
	msg "removed v$VERSION: daemon, firewall rules, $PF_BIN (history kept in $PF_PERSIST_DIR)"
	return 0
}

# Every runtime file is written as root in $PF_RUN_DIR. A directory (or
# symlink) there that this user did not create would let its owner swap the
# files for links: refuse to run on one.
_pf_rundir_safe() {
	[ -L "$PF_RUN_DIR" ] && return 1
	[ -e "$PF_RUN_DIR" ] || return 0
	[ -d "$PF_RUN_DIR" ] && [ -O "$PF_RUN_DIR" ]
}

case "${1:-}" in
	install|uninstall|version) ;;
	*) _pf_rundir_safe || { err "ping filter: $PF_RUN_DIR is not this user's own directory - refusing to run (remove it, then restart QoS-Ex)"; exit 1; } ;;
esac

case "${1:-}" in
	install)   install_self ;;
	uninstall) uninstall_self ;;
	version)   echo "$DISPLAY_NAME v$VERSION" ;;
	"")        pf_load_config; pf_dispatch help ;;
	*)         pf_load_config; pf_dispatch "$@" ;;
esac
