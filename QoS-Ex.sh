#!/bin/sh
# shellcheck shell=dash
# SPDX-License-Identifier: GPL-3.0-or-later
# QoS-Ex shaper for OpenWrt: CAKE / HFSC / HTB queues and the nftables
# classifier. The Ping Filter is QoS-Ex-PF.sh; the `pingfilter` verb is
# passed to it.
#
# Copyright (C) 2025-2026 Ash Clarke <clarkeaj@hotmail.co.uk>
#
# The HFSC class layout and the real-time/link-share curve shape are derived
# from SimpleHFSCgamerscript by dlakelan (https://github.com/dlakelan),
# GPL-3.0.  The ctinfo DSCP restore (DSCP | 0x80 connmark) and parts of the
# Simple classifier (conntrack-keyed meters, mark_500ms/mark_10s, ACK rate
# ladder) are adapted from qosmate by hudra0
# (https://github.com/hudra0/qosmate), GPL-3.0-or-later.  QoS-Ex keeps that
# licence: GPL-3.0-or-later.  The Adaptive and Advanced classifiers, the
# CAKE/HTB backends, the Ping Filter and the LuCI app are original work.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.  See <https://www.gnu.org/licenses/> for details.

VERSION="3.2.1.7"
# Version: <module>.<major>.<minor>.<patch>; module 3 = shaper, 2 = Ping
# Filter, 1 = LuCI app. Odometer: patch 10 -> minor+1, minor 10 -> major+1.
SCRIPT_NAME="QoS-Ex"
DISPLAY_NAME="QoS-Ex"
# SCRIPT_NAME is the service identity (/etc/init.d/QoS-Ex, the hotplug hook,
# System -> Startup). The UCI package, nft tables, $QOS_EX_BIN and the
# /var/run files are lowercase contracts shared with PF, rpcd and LuCI.
QOS_EX_BIN="/usr/sbin/qos-ex.sh"
UCI_CFG="qos-ex"
# Voice (1:11) real-time floor in kbit: one call, for slow lines.
VOICE_RT_MIN=200
# Flow defaults (UCI options in `advanced`: udp_fast_pps, udp_fast_burst,
# udp_small_avgpkt, slow_flow_pps; read by Simple and Adaptive, except
# udp_small_avgpkt, Adaptive only; slow_flow_pps by Advanced too). Why these
# values:
#   udp_fast_pps 450   - well clear of real-time (VoIP 50 pps, games 30-128,
#                        a high-tick shooter a few hundred), far below bulk UDP
#   udp_fast_burst     - bucket depth, half the rate
#   udp_small_avgpkt 576 - voice ~200 B, games 100-400, video ~1100, bulk MTU
#   slow_flow_pps 150  - a flow this slow cannot be what fills the link
# Each floors at 1: nft rejects `burst 0`, and avgpkt 0 matches everything.
# A bad value does not error - the rules load and simply stop matching.
NFT_SIMPLE="qos_ex_simple"
NFT_ADVANCED="qos_ex_advanced"
NFT_ADAPTIVE="qos_ex_adaptive"
# Removed rule set; the name stays so stop / a mode switch delete a table an
# older version left loaded.
NFT_RETIRED="qos_ex_sgs"
# /var/run, not /tmp: a directory anyone can pre-create in /tmp could swap the
# ruleset between the write and `nft -f`. fw4 loads every qos_ex_*.nft here on
# each start and reload (FW4_INC, lib/install.sh), so a rule set stays here
# only while it is the one loaded.
NFT_DIR="/var/run/qos-ex"
# Every fixed name: logs in /var/log, state in /var/run (root's own tmpfs).
NFT_ERR="/var/run/qos-ex-nft.err"
RUN_LOG="/var/log/qos-ex.log"
RUN_LOG_MAX=200

PF_RUN_DIR="/var/run/qos-ex-pingfilter"
PF_PID_FILE="$PF_RUN_DIR/daemon.pid"
PF_NFT_ERR="/var/run/qos-ex-pingfilter-nft.err"

# printf, not echo: ash's echo does not expand backslashes, dash's does.
msg() { printf '[%s] %s\n' "$DISPLAY_NAME" "$*"; _logline "INFO" "$*"; return 0; }
# Errors also go to syslog: the ifup hook discards a boot start's output, so
# without it a failed start never reached logread. Not from the polled verbs.
err() {
	printf '[%s] ERROR: %s\n' "$DISPLAY_NAME" "$*" >&2
	_logline "ERR " "$*"
	[ "$_LOG_QUIET" = 1 ] || logger -t "$SCRIPT_NAME" -p daemon.err "$*" 2>/dev/null
	return 1
}
# log() = msg() without terminal output. The emitted init and hotplug files
# still use logger: boot failures belong in syslog.
log() { _logline "INFO" "$*"; }

################################################################################
### SSH CONSOLE OUTPUT (install / uninstall)                                 ###
################################################################################
# One header line, one line per outcome (ok / !! / XX), one result line.
# Detail goes to $RUN_LOG via ui_note. Colour only on a TTY
# (QOS_EX_NO_COLOR=1 forces plain).
UI_B=""; UI_D=""; UI_G=""; UI_Y=""; UI_R=""; UI_0=""
# ui_bad writes to fd 2, so it has its own colour pair (gated on [ -t 2 ]).
UI_ER=""; UI_E0=""
if [ "${QOS_EX_NO_COLOR:-0}" != "1" ]; then
	if [ -t 1 ]; then
		UI_B=$(printf '\033[1m');  UI_D=$(printf '\033[2m')
		UI_G=$(printf '\033[32m'); UI_Y=$(printf '\033[33m')
		UI_R=$(printf '\033[31m'); UI_0=$(printf '\033[0m')
	fi
	if [ -t 2 ]; then
		UI_ER="$UI_R"; UI_E0="$UI_0"
		[ -n "$UI_ER" ] || { UI_ER=$(printf '\033[31m'); UI_E0=$(printf '\033[0m'); }
	fi
fi
UI_WARNS=0
UI_FAILS=0

ui_head() {   # $1 = verb
	UI_WARNS=0; UI_FAILS=0
	# Run by QoS-Ex-install.sh (QOS_EX_FETCHED=1): its heading is the run's.
	[ "${QOS_EX_FETCHED:-0}" = 1 ] || printf '%s%s v%s %s%s\n' "$UI_B" "$DISPLAY_NAME" "$VERSION" "$1" "$UI_0"
	_logline "INFO" "$1 (v$VERSION)"
}
ui_note() { _logline "INFO" "$1"; }   # log only, never on the console
ui_ok()   { printf '  %sok%s  %s\n' "$UI_G" "$UI_0" "$1"; _logline "INFO" "ok: $1"; }
ui_info() { printf '  %s..  %s%s\n' "$UI_D" "$1" "$UI_0"; }
ui_warn() { UI_WARNS=$((UI_WARNS + 1)); printf '  %s!!%s  %s\n' "$UI_Y" "$UI_0" "$1"; _logline "WARN" "$1"; }
ui_bad()  { UI_FAILS=$((UI_FAILS + 1)); printf '  %sXX%s  %s\n' "$UI_ER" "$UI_E0" "$1" >&2; _logline "ERR " "$1"; return 1; }

# Run a child installer as one ok/XX line. On success only its problem lines
# (!!, XX, ERROR, warning) are replayed; on failure all of its output.
_ui_run() {   # $1 = label, $2.. = command
	local _lbl="$1" _tmp _rc _pat='!!|XX|ERROR|[Ww]arn'
	shift
	# mktemp, not $$: a guessable /tmp name is a symlink-overwrite as root.
	# Without mktemp the child runs unredirected.
	_tmp=$(mktemp /tmp/.qos-ex-ui.XXXXXX 2>/dev/null) || _tmp=""
	if [ -z "$_tmp" ]; then
		"$@"; _rc=$?
		if [ "$_rc" = 0 ]; then ui_ok "$_lbl"; else ui_bad "$_lbl (exit $_rc)"; fi
		return $_rc
	fi
	trap 'rm -f "$_tmp" 2>/dev/null; exit 130' INT
	trap 'rm -f "$_tmp" 2>/dev/null; exit 143' TERM
	"$@" >"$_tmp" 2>&1
	_rc=$?
	trap - INT TERM
	if [ "$_rc" = 0 ]; then
		ui_ok "$_lbl"
		if grep -Eq "$_pat" "$_tmp" 2>/dev/null; then
			UI_WARNS=$((UI_WARNS + 1))
			grep -E "$_pat" "$_tmp" | sed 's/^[[:space:]]*/      /'
		fi
	else
		ui_bad "$_lbl (exit $_rc)"
		sed 's/^[[:space:]]*/      /' "$_tmp" >&2
	fi
	rm -f "$_tmp" 2>/dev/null
	return $_rc
}

_ui_ver() { sed -n 's/^VERSION="\(.*\)"$/v\1/p' "$1" 2>/dev/null | head -n 1; }


# The log is trimmed to $RUN_LOG_MAX on the first line of each run and every
# 25th after it: one wc per writing run, none per dashboard poll.
_LOGN=0
_LOGTS=""
# Set by the polled verbs (status, stats): their config warnings go to
# stdout only, so they do not flood the 200-line log.
_LOG_QUIET=0
_logline() {
	local _chk=0 _n _t
	[ -n "$RUN_LOG" ] || return 0
	[ "$_LOG_QUIET" = 1 ] && return 0
	_LOGN=$((_LOGN + 1))
	if [ "$_LOGN" -eq 1 ] || [ $((_LOGN % 25)) -eq 0 ]; then _chk=1; fi
	# One date fork per 25 lines.
	[ "$_chk" = 0 ] || _LOGTS=$(date '+%Y-%m-%d %H:%M:%S')
	printf '%s [%s] %s\n' "$_LOGTS" "$1" "$2" >> "$RUN_LOG" 2>/dev/null
	[ "$_chk" = 1 ] || return 0
	[ -f "$RUN_LOG" ] || return 0
	_n=$(wc -l < "$RUN_LOG" 2>/dev/null)
	[ "${_n:-0}" -gt "$RUN_LOG_MAX" ] || return 0
	# mktemp in the log's own directory (atomic mv, no guessable name). Not a
	# lock: a line appended between tail and mv can be lost, but a killed lock
	# holder would stop trimming forever.
	_t=$(mktemp "$RUN_LOG.XXXXXX" 2>/dev/null) || return 0
	# The log page reads it through rpcd: 0644, not mktemp's 0600.
	chmod 644 "$_t" 2>/dev/null
	tail -n "$RUN_LOG_MAX" "$RUN_LOG" > "$_t" 2>/dev/null && mv "$_t" "$RUN_LOG"
	rm -f "$_t" 2>/dev/null
}

# True if any of the candidate module names is loaded (/sys/module or
# /proc/modules). Callers pass aliases (kmod-sched-ctinfo -> act_ctinfo).
_mod_loaded() {
	local cand m
	for cand in "$@"; do
		[ -d "/sys/module/${cand}" ] && return 0
		while read -r m _; do
			[ "$m" = "$cand" ] && return 0
		done 2>/dev/null < /proc/modules
	done
	return 1
}

# Short, stable token for stdin: change detector and IFB-name suffix. md5sum
# (a default BusyBox applet), else a djb2-style awk hash (mod the largest
# prime under 2^32) that cannot fail, so this never returns empty. Not cksum:
# it is not a default applet, and a token that changes when a package adds it
# renames the IFB (stop still removes the old one: it reads the start stamp).
_hash_short() {
	if command -v md5sum >/dev/null 2>&1; then
		md5sum | cut -c1-10
	else
		awk 'BEGIN { for (i = 1; i < 256; i++) o[sprintf("%c", i)] = i }
		     { n = length($0)
		       for (i = 1; i <= n; i++) h = (h * 33 + o[substr($0, i, 1)]) % 4294967291 }
		     END { printf "%.0f\n", h }'
	fi
}

_isnum() {
	# Plain non-negative decimal, no leading zero: `[ 08 -ge 0 ]` passes but
	# $((08)) is a fatal ash error and 0100 is octal. Every clamp and every
	# $(( )) that sees a UCI value goes through this. Over 12 digits, `[` and
	# $(( )) disagree, so it is rejected.
	[ "${#1}" -le 12 ] || return 1
	case "${1:-}" in
		''|*[!0-9]*) return 1 ;;
		0)           return 0 ;;
		0*)          return 1 ;;
	esac
	return 0
}

# Leading zeros ("044", "0100000") are decimal, as PF and LuCI read them.
# Only all-digit values change; load_config's checks still apply.
# $@ = variable NAMES (fixed literals at the call site).
_dec() {
	local _n _v
	for _n in "$@"; do
		eval "_v=\${$_n}"
		case "$_v" in
			''|*[!0-9]*|[!0]*) continue ;;
		esac
		_v=${_v#"${_v%%[!0]*}"}
		eval "$_n=\${_v:-0}"
	done
	return 0
}

# yes / no switches read as OpenWrt booleans (1/on/true/enabled and their
# opposites, any case), so `uci set ...=1` does not silently mean "off".
# Anything else is left as is for the caller's check. $@ = variable NAMES.
_yn() {
	local _n _v
	for _n in "$@"; do
		eval "_v=\${$_n}"
		case "$_v" in
			[Yy][Ee][Ss]|1|[Oo][Nn]|[Tt][Rr][Uu][Ee]|[Ee][Nn][Aa][Bb][Ll][Ee][Dd]) eval "$_n=yes" ;;
			[Nn][Oo]|0|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Dd][Ii][Ss][Aa][Bb][Ll][Ee][Dd]) eval "$_n=no" ;;
		esac
	done
	return 0
}

# Lower-case enum values ("Manual", "CAKE"). A fork only when there is an
# upper-case letter: load_config runs on every poll. $@ = variable NAMES.
_lc() {
	local _n _v
	for _n in "$@"; do
		eval "_v=\${$_n}"
		# shellcheck disable=SC2018,SC2019  # ASCII enum values only
		case "$_v" in
			*[A-Z]*) _v=$(printf '%s' "$_v" | tr 'A-Z' 'a-z'); eval "$_n=\$_v" ;;
		esac
	done
	return 0
}

################################################################################
### IPv4 dotted-quad, octets 0-255, optional /CIDR; IPv6 structurally checked.
### Pure shell (no forks): these run on every start, reload and ifup.
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
	# A trailing dot would leave the loop with four octets counted.
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
### Colon-separated groups: each 1-4 hex digits, count into $_G.
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
	# One bad token must not fail the whole nft table: at most one "::",
	# groups of 1-4 hex digits, 8 groups without "::" and at most 7 with one,
	# prefix 0-128.
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
### Keep only tokens that validate; warn (don't abort) on each one dropped.
### Callers capture stdout, so the warning goes to stderr (quiet when polled).
_drop_warn() {
	[ "$_LOG_QUIET" = 1 ] || printf '[%s] %s\n' "$DISPLAY_NAME" "$1" >&2
	_logline "WARN" "$1"
}
pf_filter_ips() {
	local _valid="" _what="$1" _fn _tok
	shift; _fn="$1"; shift
	for _tok in "$@"; do
		[ -n "$_tok" ] || continue
		if "$_fn" "$_tok"; then
			_valid="${_valid:+$_valid }$_tok"
		else
			_drop_warn "dropping invalid $_what address: $_tok"
		fi
	done
	echo "$_valid"
}

### A device by MAC (six hex pairs), matched as `ether saddr`: it follows the
### device through DHCP changes and IPv6 privacy addresses. Duplicates dropped,
### lower case. $1 = list name for the log.
_valid_mac() {
	local _h='[0-9A-Fa-f][0-9A-Fa-f]'
	# shellcheck disable=SC2254  # the pattern is meant to be expanded
	case "$1" in
		$_h:$_h:$_h:$_h:$_h:$_h) return 0 ;;
	esac
	return 1
}
_filter_macs() {
	local _o="" _t _l="$1"
	shift
	[ $# -gt 0 ] || return 0
	for _t in $(echo "$*" | tr 'A-F' 'a-f'); do
		if _valid_mac "$_t"; then
			case " $_o " in *" $_t "*) ;; *) _o="${_o:+$_o }$_t" ;; esac
		else
			_drop_warn "dropping invalid $_l MAC: $_t"
		fi
	done
	echo "$_o"
}

### Keep only well-formed ports/ranges and drop duplicates and overlaps: nft
### rejects them in an interval set ("File exists") and fails the WHOLE table.
### The result goes to $_PORTS, not stdout, so msg() warnings stay out of it.
_port_list_raw() {
	echo "$1" | awk '
	BEGIN { FS = "[, \t]+"; n = 0; out = "" }
	{
		for (f = 1; f <= NF; f++) {
			it = $f
			if (it == "") continue
			# A second dash ("6881-6889-", "1-2-3") passed the charset
			# test and the lo/hi parse below, and the token is emitted
			# VERBATIM into a simple define -- where nft rejects it as a
			# syntax error and the whole Simple table fails to load.
			bad = (it ~ /[^0-9-]/) || (it ~ /-.*-/)
			d = index(it, "-")
			if (d > 0) { lo = substr(it,1,d-1)+0; hi = substr(it,d+1)+0 }
			else       { lo = it+0; hi = lo }
			if (bad || lo < 1 || hi > 65535 || hi < lo) {
				printf "#SKIP %s is not a port or range in 1-65535\n", it
				continue
			}
			dup = 0
			for (i = 1; i <= n; i++) if (lo <= khi[i] && hi >= klo[i]) dup = 1
			if (dup) {
				printf "#SKIP %s duplicates or overlaps an earlier entry\n", it
				continue
			}
			n++; klo[n] = lo; khi[n] = hi
			# The parsed numbers, not the token: nft reads a leading zero as
			# octal, so "0100" loaded as port 64.
			out = out (out == "" ? "" : ", ") (lo == hi ? lo : lo "-" hi)
		}
	}
	END { print out }'
}
_port_filter() {   # $1 = label for messages, $2 = raw list -> $_PORTS
	local _pl
	_PORTS=""
	while IFS= read -r _pl; do
		case "$_pl" in
			"")        continue ;;
			"#SKIP "*) msg "$1: ${_pl#\#SKIP }" ;;
			*)         _PORTS="$_pl" ;;
		esac
	done <<EOF
$(_port_list_raw "$2")
EOF
}

### UCI CONFIG LOADER                                                        ###
################################################################################
load_config() {
	# Sourced once per process; config_load runs every time.
	if ! command -v config_load >/dev/null 2>&1; then
		[ -f /lib/functions.sh ] || { err "/lib/functions.sh missing"; return 1; }
		. /lib/functions.sh
	fi
	config_load "$UCI_CFG"

	# These fallbacks MUST match emit_uci_config: they apply to a hand-edited
	# config, and to a key added after the user's install.
	config_get ENABLED       settings enabled       "0"
	config_get WAN           settings wan           "eth0"
	config_get QDISC         settings qdisc         "cake"
	config_get NFT_MODE      settings nft_mode      "adaptive"
	config_get UPLOAD_KBPS   settings upload_kbps   "100000"
	config_get DOWNLOAD_KBPS settings download_kbps "100000"
	config_get OVERHEAD      settings overhead      "44"
	config_get LINKLAYER     settings linklayer     "ethernet"
	config_get DL_ON         settings download_on   "wan"
	config_get LAN_DEV       settings lan           ""
	config_get MPU           cake     mpu            ""
	[ -n "$MPU" ] || config_get MPU settings mpu "84"
	config_get RTT           cake     rtt            ""
	[ -n "$RTT" ] || config_get RTT settings rtt "100ms"
	config_get WASH_UP       settings wash_up       "yes"
	config_get WASH_DOWN     settings wash_down     "yes"
	config_get ACK_FILTER    settings ack_filter    "auto"
	config_get BW_MAX_RATIO  settings bw_max_ratio  "auto"
	config_get BW_HEADROOM   settings bw_headroom   "90"
	config_get MSS_CLAMP     settings mss           "auto"
	config_get MSS_GATE      settings mss_max_kbps  "3000"

	config_get CAKE_PRIO     cake priority       "diffserv4"
	config_get CAKE_HOSTISO  cake host_isolation "yes"
	config_get CAKE_NAT_ING  cake nat_ingress    "yes"
	config_get CAKE_NAT_EGR  cake nat_egress     "yes"
	config_get CAKE_ING_MODE cake ingress_mode   "yes"
	config_get CAKE_EXTRA_I  cake extra_ingress  ""
	config_get CAKE_EXTRA_E  cake extra_egress   ""

	config_get HFSC_GAMEQ       hfsc game_qdisc    "sfq"
	config_get DEFAULT_QDISC    hfsc default_qdisc "fq_codel"
	config_get HFSC_PFMIN       hfsc pfifo_min     "5"
	config_get HFSC_PKTSZ       hfsc packet_size   "576"
	config_get HFSC_MAXDLY      hfsc max_delay     "5"
	config_get HFSC_BF_MIN      hfsc bfifo_min     "3000"
	config_get HFSC_SFQ_PERTURB hfsc sfq_perturb   "10"
	config_get HFSC_SFQ_QUANTUM hfsc sfq_quantum   "300"
	config_get HFSC_FQ_LIMIT    hfsc fq_limit      "10240"
	config_get HFSC_FQ_FLOWS    hfsc fq_flows      "1024"
	config_get HFSC_FQ_QUANTUM  hfsc fq_quantum    "300"
	config_get HFSC_FQ_TARGET   hfsc fq_target     "5"
	config_get HFSC_FQ_INTERVAL hfsc fq_interval   "100"
	# Gaming class (1:10), HFSC and HTB. 15 / 10 are SimpleHFSCgamerscript's.
	config_get GAME_PCT         hfsc game_pct      "15"
	config_get GAME_BURST       hfsc game_burst    "10"
	config_get GAME_FLOOR       hfsc game_floor    "400"
	config_get VOICE_RT         hfsc voice_rt      "yes"

	# Leaf (1:11..1:15) tuning: def_* are read in Manual mode only; Auto
	# derives its own from the shaped rate.
	config_get DEF_TUNE_MODE    hfsc def_tune_mode    "auto"
	config_get DEF_FQ_LIMIT     hfsc def_fq_limit     "10240"
	config_get DEF_FQ_FLOWS     hfsc def_fq_flows     "1024"
	config_get DEF_FQ_QUANTUM   hfsc def_fq_quantum   "1514"
	config_get DEF_FQ_TARGET    hfsc def_fq_target    "5"
	config_get DEF_FQ_INTERVAL  hfsc def_fq_interval  "100"
	config_get DEF_FQ_MEMORY_MB hfsc def_fq_memory_mb "4"
	config_get DEF_FQ_ECN       hfsc def_fq_ecn       "ecn"
	config_get DEF_SFQ_LIMIT    hfsc def_sfq_limit    "127"
	config_get DEF_SFQ_DEPTH    hfsc def_sfq_depth    "127"
	config_get DEF_SFQ_DIVISOR  hfsc def_sfq_divisor  "1024"
	config_get DEF_SFQ_FLOWS    hfsc def_sfq_flows    "127"
	config_get DEF_SFQ_QUANTUM  hfsc def_sfq_quantum  "1514"
	config_get DEF_SFQ_PERTURB  hfsc def_sfq_perturb  "10"
	config_get DEF_SFQ_HEADDROP hfsc def_sfq_headdrop "no"

	config_get HTTP_PORTS    ports http      "80,443"
	# Empty = that list off. LuCI deletes an emptied option, so these defaults
	# apply only when the whole section is missing.
	config_get TCP_BULK      ports tcp_bulk  ""
	config_get UDP_BULK      ports udp_bulk  ""
	config_get VIDCONF_PORTS ports vidconf   ""
	config_get _PORTS_SEC    ports TYPE      ""
	[ -n "$_PORTS_SEC" ] || {
		TCP_BULK="51413,6881-6889"; UDP_BULK="51413"
		VIDCONF_PORTS="53,500,3478-3481,4500,5223,5938,8801-8802,10000,19302-19309"
	}
	# An empty list would render as `{ }`, which nft rejects (whole ruleset).
	# tcp_bulk / udp_bulk / vidconf empty = off; http_ports has no off switch,
	# so it gets its default back.
	[ -n "$HTTP_PORTS" ] || { msg "ports.http empty - restoring default (80,443)"; HTTP_PORTS="80,443"; }

	# Classification thresholds; repeated in the seed and the LuCI widgets.
	config_get UDP_FAST_PPS     advanced udp_fast_pps     "450"
	config_get UDP_FAST_BURST   advanced udp_fast_burst   "225"
	config_get UDP_SMALL_AVGPKT advanced udp_small_avgpkt "576"
	config_get SLOW_FLOW_PPS    advanced slow_flow_pps    "150"
	config_get HEAVY_FLOW_PPS   advanced heavy_flow_pps   "1000"
	config_get BULK_TIMEOUT     advanced bulk_timeout     "120"
	# Ceilings (Mbit) on the download rate the per-connection byte windows are
	# sized from: real flows do not run at line rate. 80 -> first500ms <= 5 MB;
	# 400 -> first10s <= 500 MB.
	config_get TCP_NEW_CAP      advanced tcp_new_cap_mbit  "80"
	config_get TCP_BULK_CAP     advanced tcp_bulk_cap_mbit "400"

	config_get SIM_BULK_PORTS  simple bulk_ports  "yes"
	config_get SIM_VIDCONF     simple vidconf     "yes"
	config_get SIM_GAMING_IP   simple gaming_ip   "yes"
	config_get SIM_LOWPRIO_IP  simple lowprio_ip  "yes"
	config_get SIM_UDP_RATE    simple udp_rate    "yes"
	# tcp_flow is the pre-split key these three inherit; written empty it must
	# not switch the whole TCP ladder off.
	config_get _SIM_TCP_OLD    simple tcp_flow    "yes"
	config_get SIM_TCP_500MS   simple tcp_500ms   "${_SIM_TCP_OLD:-yes}"
	config_get SIM_TCP_UPGRADE simple tcp_upgrade "${_SIM_TCP_OLD:-yes}"
	config_get SIM_TCP_10S     simple tcp_10s     "${_SIM_TCP_OLD:-yes}"

	config_get ADV_GAMING_IP   advanced gaming_ip   "yes"
	config_get ADV_LOWPRIO_IP  advanced lowprio_ip  "yes"
	config_get _ADV_TCP_OLD    advanced tcp_flow    "yes"
	config_get ADV_TCP_UPGRADE advanced tcp_upgrade "${_ADV_TCP_OLD:-yes}"
	config_get ADV_TCP_10S     advanced tcp_10s     "${_ADV_TCP_OLD:-yes}"
	config_get ADV_METER_DOWN  advanced meter_down  "yes"
	# Advanced per-packet split: rates per connection-direction, packet sizes
	# in bytes, the scratch reset in packets per thousand.
	config_get ADV_WEB_PPS     advanced web_pps     "200"
	config_get ADV_TCP_PPS     advanced tcp_pps     "200"
	config_get ADV_UDP_PPS     advanced udp_pps     "250"
	config_get ADV_SMALL_LEN   advanced small_len   "84"
	config_get ADV_MAX_LEN     advanced max_len     "1256"
	config_get ADV_RESET_PM    advanced reset_pm    "5"

	config_get ADA_HEAVY_PCT    adaptive heavy_pct    "25"
	config_get ADA_HEAVY_SECS   adaptive heavy_secs   "10"
	config_get ADA_P2P_RATE     adaptive p2p_rate     "120"
	config_get ADA_VPN_PORTS    adaptive vpn_ports    "51820,1194"

	# config_get, not config_list_foreach: it returns a list's items space-
	# separated AND a value written as a plain option (`uci set
	# qos-ex.ips.gaming_mac=...`), which config_list_foreach skips silently.
	config_get GAMING_IP4  ips gaming_ipv4  ""
	config_get GAMING_IP6  ips gaming_ipv6  ""
	config_get LOWPRIO_IP4 ips lowprio_ipv4 ""
	config_get LOWPRIO_IP6 ips lowprio_ipv6 ""
	config_get GAMING_MAC  ips gaming_mac   ""
	config_get LOWPRIO_MAC ips lowprio_mac  ""

	# Unquoted on purpose (word splitting feeds the validator). set -f stops a
	# `*` entry globbing the CWD; the caller's setting is restored.
	case "$-" in *f*) _had_f=1 ;; *) _had_f=0 ;; esac
	set -f
	# shellcheck disable=SC2086  # word splitting is the mechanism here
	GAMING_IP4=$(pf_filter_ips  "gaming IPv4"  pf_valid_ip4 $GAMING_IP4)
	# shellcheck disable=SC2086
	GAMING_IP6=$(pf_filter_ips  "gaming IPv6"  pf_valid_ip6 $GAMING_IP6)
	# shellcheck disable=SC2086
	LOWPRIO_IP4=$(pf_filter_ips "lowprio IPv4" pf_valid_ip4 $LOWPRIO_IP4)
	# shellcheck disable=SC2086
	LOWPRIO_IP6=$(pf_filter_ips "lowprio IPv6" pf_valid_ip6 $LOWPRIO_IP6)
	# shellcheck disable=SC2086
	GAMING_MAC=$(_filter_macs gaming $GAMING_MAC)
	# shellcheck disable=SC2086
	LOWPRIO_MAC=$(_filter_macs lowprio $LOWPRIO_MAC)
	[ "$_had_f" = 1 ] || set +f

	_dec UPLOAD_KBPS DOWNLOAD_KBPS OVERHEAD MPU BW_HEADROOM BW_MAX_RATIO MSS_CLAMP MSS_GATE \
		HFSC_PFMIN HFSC_PKTSZ HFSC_MAXDLY HFSC_BF_MIN HFSC_SFQ_PERTURB HFSC_SFQ_QUANTUM \
		HFSC_FQ_LIMIT HFSC_FQ_FLOWS HFSC_FQ_QUANTUM HFSC_FQ_TARGET HFSC_FQ_INTERVAL \
		GAME_PCT GAME_BURST GAME_FLOOR \
		DEF_FQ_LIMIT DEF_FQ_FLOWS DEF_FQ_QUANTUM DEF_FQ_TARGET DEF_FQ_INTERVAL DEF_FQ_MEMORY_MB \
		DEF_SFQ_LIMIT DEF_SFQ_DEPTH DEF_SFQ_DIVISOR DEF_SFQ_FLOWS DEF_SFQ_QUANTUM DEF_SFQ_PERTURB \
		UDP_FAST_PPS UDP_FAST_BURST UDP_SMALL_AVGPKT SLOW_FLOW_PPS HEAVY_FLOW_PPS BULK_TIMEOUT \
		TCP_NEW_CAP TCP_BULK_CAP ADA_HEAVY_PCT ADA_HEAVY_SECS ADA_P2P_RATE \
		ADV_WEB_PPS ADV_TCP_PPS ADV_UDP_PPS ADV_SMALL_LEN ADV_MAX_LEN ADV_RESET_PM

	# A non-numeric operand or divide by zero is fatal in ash mid-build, so
	# rates are checked first. 0 = that direction unshaped (every divide by a
	# rate sits in a builder that only runs for a shaped direction); not a
	# number = unshaped too, never a made-up rate.
	_isnum "${UPLOAD_KBPS:-}"   || { msg "upload_kbps '$UPLOAD_KBPS' invalid - upload not shaped (0)"; UPLOAD_KBPS=0; }
	_isnum "${DOWNLOAD_KBPS:-}" || { msg "download_kbps '$DOWNLOAD_KBPS' invalid - download not shaped (0)"; DOWNLOAD_KBPS=0; }
	# LINE_* keep the rate as entered: calc_bandwidth re-derives the shaped
	# rate each call, so the headroom haircut never compounds.
	LINE_UP_KBPS="$UPLOAD_KBPS"
	LINE_DN_KBPS="$DOWNLOAD_KBPS"
	# Percent of line rate; out of range or not a number = the default 90. A
	# typo must not fail towards shaping at the full line rate.
	if _isnum "${BW_HEADROOM:-}" && [ "$BW_HEADROOM" -ge 50 ] && [ "$BW_HEADROOM" -le 100 ]; then
		:
	else
		msg "bw_headroom '$BW_HEADROOM' out of range 50-100 - using 90"
		BW_HEADROOM=90
	fi
	# OVERHEAD feeds tc (stab) and arithmetic in the auto download cap. 0-256:
	# what CAKE takes; over it tc fails and the line is left unshaped.
	_isnum "${OVERHEAD:-}" && [ "$OVERHEAD" -le 256 ] || { msg "overhead '$OVERHEAD' not 0-256 - using 44"; OVERHEAD=44; }
	_isnum "${GAME_PCT:-}"   && [ "$GAME_PCT" -ge 5 ]   && [ "$GAME_PCT" -le 50 ]   || { msg "game_pct '$GAME_PCT' out of range 5-50 - using 15"; GAME_PCT=15; }
	_isnum "${GAME_BURST:-}" && [ "$GAME_BURST" -ge 1 ] && [ "$GAME_BURST" -le 20 ] || { msg "game_burst '$GAME_BURST' out of range 1-20 - using 10"; GAME_BURST=10; }
	_isnum "${GAME_FLOOR:-}" && [ "$GAME_FLOOR" -le 10000 ] || { msg "game_floor '$GAME_FLOOR' out of range 0-10000 - using 400"; GAME_FLOOR=400; }

	# Switches and enums: OpenWrt booleans and any case are accepted, then
	# each switch must be yes or no, else it gets its default (with a note).
	_yn ENABLED WASH_UP WASH_DOWN CAKE_HOSTISO CAKE_NAT_ING CAKE_NAT_EGR CAKE_ING_MODE \
		VOICE_RT DEF_SFQ_HEADDROP ADV_METER_DOWN \
		SIM_BULK_PORTS SIM_VIDCONF SIM_GAMING_IP SIM_LOWPRIO_IP SIM_UDP_RATE \
		SIM_TCP_500MS SIM_TCP_UPGRADE SIM_TCP_10S \
		ADV_GAMING_IP ADV_LOWPRIO_IP ADV_TCP_UPGRADE ADV_TCP_10S
	case "$ENABLED" in yes) ENABLED=1 ;; *) ENABLED=0 ;; esac
	for _sw in WASH_UP:wash_up:yes WASH_DOWN:wash_down:yes CAKE_HOSTISO:host_isolation:yes \
		CAKE_NAT_ING:nat_ingress:yes CAKE_NAT_EGR:nat_egress:yes CAKE_ING_MODE:ingress_mode:yes \
		VOICE_RT:voice_rt:yes DEF_SFQ_HEADDROP:def_sfq_headdrop:no ADV_METER_DOWN:meter_down:yes \
		SIM_BULK_PORTS:simple.bulk_ports:yes SIM_VIDCONF:simple.vidconf:yes \
		SIM_GAMING_IP:simple.gaming_ip:yes SIM_LOWPRIO_IP:simple.lowprio_ip:yes \
		SIM_UDP_RATE:simple.udp_rate:yes SIM_TCP_500MS:simple.tcp_500ms:yes \
		SIM_TCP_UPGRADE:simple.tcp_upgrade:yes SIM_TCP_10S:simple.tcp_10s:yes \
		ADV_GAMING_IP:advanced.gaming_ip:yes ADV_LOWPRIO_IP:advanced.lowprio_ip:yes \
		ADV_TCP_UPGRADE:advanced.tcp_upgrade:yes ADV_TCP_10S:advanced.tcp_10s:yes; do
		_swk=${_sw#*:}; _swk=${_swk%:*}
		eval "_swv=\${${_sw%%:*}}"
		# shellcheck disable=SC2154  # _swv is set by the eval above
		case "$_swv" in
			yes|no) ;;
			*) msg "$_swk '$_swv' is not yes or no - using ${_sw##*:}"; eval "${_sw%%:*}=${_sw##*:}" ;;
		esac
	done
	_lc QDISC NFT_MODE ACK_FILTER CAKE_PRIO HFSC_GAMEQ DEFAULT_QDISC DEF_TUNE_MODE DEF_FQ_ECN \
		BW_MAX_RATIO MSS_CLAMP LINKLAYER
	case "$DEF_TUNE_MODE" in auto|manual) ;; *) msg "def_tune_mode '$DEF_TUNE_MODE' unknown - using auto"; DEF_TUNE_MODE=auto ;; esac
	case "$DEF_FQ_ECN"    in ecn|noecn) ;;   *) msg "def_fq_ecn '$DEF_FQ_ECN' unknown - using ecn"; DEF_FQ_ECN=ecn ;; esac
	# ATM (ADSL) pads every packet to 53-byte cells: stab and CAKE must know.
	case "$LINKLAYER"     in ethernet|atm) ;; *) msg "linklayer '$LINKLAYER' unknown - using ethernet"; LINKLAYER=ethernet ;; esac

	# Gaming leaf (1:10) values reach tc only. Each is held to what the kernel
	# accepts (a rejected value left 1:10 on a 3-packet pfifo on pppoe-wan):
	# out of range = the nearest bound, not a number = the default.
	_leaf_range "$HFSC_PKTSZ"       576   64    9000;    HFSC_PKTSZ=$_LEAFV
	_leaf_range "$HFSC_PFMIN"         5    0   10000;    HFSC_PFMIN=$_LEAFV
	_leaf_range "$HFSC_MAXDLY"        5    0    1000;    HFSC_MAXDLY=$_LEAFV
	_leaf_range "$HFSC_BF_MIN"     3000 1500 33554432;   HFSC_BF_MIN=$_LEAFV
	_leaf_range "$HFSC_SFQ_PERTURB"  10    0    3600;    HFSC_SFQ_PERTURB=$_LEAFV
	_leaf_range "$HFSC_SFQ_QUANTUM" 300    1   65535;    HFSC_SFQ_QUANTUM=$_LEAFV
	_leaf_range "$HFSC_FQ_LIMIT"  10240   16 1000000;    HFSC_FQ_LIMIT=$_LEAFV
	_leaf_range "$HFSC_FQ_FLOWS"   1024    1   65536;    HFSC_FQ_FLOWS=$_LEAFV
	_leaf_range "$HFSC_FQ_QUANTUM"  300    1 1048576;    HFSC_FQ_QUANTUM=$_LEAFV
	_leaf_range "$HFSC_FQ_INTERVAL" 100    2   10000;    HFSC_FQ_INTERVAL=$_LEAFV
	_leaf_range "$HFSC_FQ_TARGET"     5    1   10000;    HFSC_FQ_TARGET=$_LEAFV
	# A target at or above the interval leaves CoDel nothing to do.
	[ "$HFSC_FQ_TARGET" -lt "$HFSC_FQ_INTERVAL" ] || HFSC_FQ_TARGET=$((HFSC_FQ_INTERVAL / 2))
	# Floor 1 (see the header): bare numbers in nft rule text.
	_isnum "${UDP_FAST_PPS:-}"     && [ "$UDP_FAST_PPS"     -ge 1 ] || UDP_FAST_PPS=450
	_isnum "${UDP_FAST_BURST:-}"   && [ "$UDP_FAST_BURST"   -ge 1 ] || UDP_FAST_BURST=225
	_isnum "${UDP_SMALL_AVGPKT:-}" && [ "$UDP_SMALL_AVGPKT" -ge 1 ] || UDP_SMALL_AVGPKT=576
	_isnum "${SLOW_FLOW_PPS:-}"    && [ "$SLOW_FLOW_PPS"    -ge 1 ] || SLOW_FLOW_PPS=150
	# A rate in nft, and doubled, its burst.
	_isnum "${HEAVY_FLOW_PPS:-}"   && [ "$HEAVY_FLOW_PPS"   -ge 1 ] && [ "$HEAVY_FLOW_PPS" -le 100000 ] || HEAVY_FLOW_PPS=1000
	_isnum "${ADV_WEB_PPS:-}" && [ "$ADV_WEB_PPS" -ge 1 ] && [ "$ADV_WEB_PPS" -le 100000 ] || { msg "web_pps '$ADV_WEB_PPS' out of range 1-100000 - using 200"; ADV_WEB_PPS=200; }
	_isnum "${ADV_TCP_PPS:-}" && [ "$ADV_TCP_PPS" -ge 1 ] && [ "$ADV_TCP_PPS" -le 100000 ] || { msg "tcp_pps '$ADV_TCP_PPS' out of range 1-100000 - using 200"; ADV_TCP_PPS=200; }
	_isnum "${ADV_UDP_PPS:-}" && [ "$ADV_UDP_PPS" -ge 1 ] && [ "$ADV_UDP_PPS" -le 100000 ] || { msg "udp_pps '$ADV_UDP_PPS' out of range 1-100000 - using 250"; ADV_UDP_PPS=250; }
	_isnum "${ADV_MAX_LEN:-}" && [ "$ADV_MAX_LEN" -ge 128 ] && [ "$ADV_MAX_LEN" -le 9000 ] || { msg "max_len '$ADV_MAX_LEN' out of range 128-9000 - using 1256"; ADV_MAX_LEN=1256; }
	_isnum "${ADV_SMALL_LEN:-}" && [ "$ADV_SMALL_LEN" -ge 40 ] && [ "$ADV_SMALL_LEN" -lt "$ADV_MAX_LEN" ] || { msg "small_len '$ADV_SMALL_LEN' not 40 to below max_len - using 84"; ADV_SMALL_LEN=84; }
	_isnum "${ADV_RESET_PM:-}" && [ "$ADV_RESET_PM" -le 999 ] || { msg "reset_pm '$ADV_RESET_PM' out of range 0-999 - using 5"; ADV_RESET_PM=5; }
	_isnum "${ADA_HEAVY_PCT:-}"  && [ "$ADA_HEAVY_PCT"  -ge 1 ] && [ "$ADA_HEAVY_PCT"  -le 100 ] || { msg "adaptive heavy_pct '$ADA_HEAVY_PCT' out of range 1-100 - using 25"; ADA_HEAVY_PCT=25; }
	_isnum "${ADA_HEAVY_SECS:-}" && [ "$ADA_HEAVY_SECS" -ge 1 ] && [ "$ADA_HEAVY_SECS" -le 60 ] || { msg "adaptive heavy_secs '$ADA_HEAVY_SECS' out of range 1-60 - using 10"; ADA_HEAVY_SECS=10; }
	_isnum "${ADA_P2P_RATE:-}"   && { [ "$ADA_P2P_RATE" = 0 ] || { [ "$ADA_P2P_RATE" -ge 10 ] && [ "$ADA_P2P_RATE" -le 10000 ]; }; } || { msg "adaptive p2p_rate '$ADA_P2P_RATE' not 0 or 10-10000 - using 120"; ADA_P2P_RATE=120; }
	# nft `timeout Ns`; 0 = sticky off.
	_isnum "${BULK_TIMEOUT:-}"     && [ "$BULK_TIMEOUT"     -le 86400 ] || { msg "bulk_timeout '$BULK_TIMEOUT' out of range 0-86400 - using 120"; BULK_TIMEOUT=120; }
	# <= 1000 keeps the window products in 32 bits.
	_isnum "${TCP_NEW_CAP:-}"  && [ "$TCP_NEW_CAP"  -ge 1 ] && [ "$TCP_NEW_CAP"  -le 1000 ] || { msg "tcp_new_cap_mbit '$TCP_NEW_CAP' out of range 1-1000 - using 80"; TCP_NEW_CAP=80; }
	_isnum "${TCP_BULK_CAP:-}" && [ "$TCP_BULK_CAP" -ge 1 ] && [ "$TCP_BULK_CAP" -le 1000 ] || { msg "tcp_bulk_cap_mbit '$TCP_BULK_CAP' out of range 1-1000 - using 400"; TCP_BULK_CAP=400; }
	[ "$UDP_SMALL_AVGPKT" -gt 1500 ] && msg "udp_small_avgpkt '$UDP_SMALL_AVGPKT' is above a 1500-byte MTU - the UDP ladder will treat every flow as small"

	# String keys reach tc and nft as bare tokens: enums are whitelisted, RTT
	# and MPU shape-checked. Retired values (sgs, hfsc_sgs) are mapped here for
	# hand edits; uci_migrate rewrites them on install.
	[ "$NFT_MODE" = "sgs" ] && { msg "nft_mode 'sgs' was removed - using simple"; NFT_MODE=simple; }
	case "$NFT_MODE"      in simple|advanced|adaptive) ;; *) msg "nft_mode '$NFT_MODE' unknown - using adaptive"; NFT_MODE=adaptive ;; esac
	[ "$QDISC" = "hfsc_sgs" ] && { msg "qdisc 'hfsc_sgs' was removed - using hfsc"; QDISC=hfsc; }
	case "$QDISC"         in cake|hfsc|htb) ;; *) msg "qdisc '$QDISC' unknown - using cake";   QDISC=cake ;; esac
	# yes / no as on / off, as calc_bandwidth and the LuCI preview read them.
	case "$ACK_FILTER"    in yes|1|true|enabled) ACK_FILTER=on ;; no|0|false|disabled) ACK_FILTER=off ;; esac
	case "$ACK_FILTER"    in auto|on|off) ;;  *) msg "ack_filter '$ACK_FILTER' unknown - using auto";   ACK_FILTER=auto ;; esac
	# 1-99, the UI's range; anything else means auto.
	case "$BW_MAX_RATIO"  in ""|auto|Auto|AUTO|off|Off|OFF|0) ;; *) if _isnum "$BW_MAX_RATIO" && [ "$BW_MAX_RATIO" -ge 1 ] && [ "$BW_MAX_RATIO" -le 99 ]; then :; else msg "bw_max_ratio '$BW_MAX_RATIO' invalid or out of range 1-99 - using auto"; BW_MAX_RATIO=auto; fi ;; esac
	case "$CAKE_PRIO"     in besteffort|precedence|diffserv3|diffserv4|diffserv8) ;; *) msg "cake priority '$CAKE_PRIO' unknown - using diffserv4"; CAKE_PRIO=diffserv4 ;; esac
	# No "none": setup_hfsc_game_q has no such arm.
	case "$HFSC_GAMEQ"    in pfifo|bfifo|sfq|fq_codel) ;; *) msg "game_qdisc '$HFSC_GAMEQ' unknown - using sfq"; HFSC_GAMEQ=sfq ;; esac
	case "$DEFAULT_QDISC" in sfq|fq_codel) ;; *) msg "default_qdisc '$DEFAULT_QDISC' unknown - using fq_codel"; DEFAULT_QDISC=fq_codel ;; esac
	# A tc time: digits with at most one dot, then ms / us / s.
	case "$RTT" in
		*ms) _rtt_n="${RTT%ms}" ;;
		*us) _rtt_n="${RTT%us}" ;;
		*s)  _rtt_n="${RTT%s}"  ;;
		*)   _rtt_n="" ;;
	esac
	case "$_rtt_n" in
		''|*[!0-9.]*|*.*.*|.*|*.) msg "rtt '$RTT' is not a tc time value - using 100ms"; RTT=100ms ;;
	esac
	_isnum "$MPU" && [ "$MPU" -le 256 ] || { msg "mpu '$MPU' not 0-256 - using 84"; MPU=84; }
	_port_filter "http_ports"    "$HTTP_PORTS";    HTTP_PORTS="$_PORTS"
	_port_filter "tcp_bulk"      "$TCP_BULK";      TCP_BULK="$_PORTS"
	_port_filter "udp_bulk"      "$UDP_BULK";      UDP_BULK="$_PORTS"
	_port_filter "vidconf_ports" "$VIDCONF_PORTS"; VIDCONF_PORTS="$_PORTS"
	_port_filter "vpn_ports"     "$ADA_VPN_PORTS"; ADA_VPN_PORTS="$_PORTS"
	# http_ports has no off switch (Simple define, Advanced web_ports).
	[ -n "$HTTP_PORTS" ] || { msg "http_ports emptied by validation - using 80,443"; HTTP_PORTS="80,443"; }
	# WAN is an interface name, an nft define and part of the IFB name: only
	# the charset ip / tc accept.
	case "$WAN" in *[!A-Za-z0-9._-]*|'') err "wan '$WAN' is not a valid interface name"; return 1 ;; esac

	# IFNAMSIZ: "ifb-$WAN" over 15 chars falls back to a hashed name, the same
	# on every load so start / stop / status agree.
	IFB="ifb-$WAN"
	if [ "${#IFB}" -gt 15 ]; then
		# echo, not printf: the newline is part of the hash, and the name is an
		# on-disk contract (a change orphans the old IFB). WAN is charset-checked.
		_ck=$(echo "$WAN" | _hash_short)
		IFB="ifb${_ck}"
	fi
	# Download on the LAN side (settings.download_on lan): the download
	# qdisc goes on the LAN device's egress behind a clsact ctinfo filter,
	# with no IFB and no WAN ingress redirect. $IFB names that device from
	# here on, so the build, status, stats and stop treat it as the IFB.
	# Empty settings.lan = the lan interface's device, else br-lan.
	DL_LAN=0
	case "$DL_ON" in lan) DL_LAN=1 ;; *) DL_ON=wan ;; esac
	if [ "$DL_LAN" = 1 ]; then
		case "$LAN_DEV" in *[!A-Za-z0-9._-]*) err "lan '$LAN_DEV' is not a valid interface name"; return 1 ;; esac
		[ -n "$LAN_DEV" ] || LAN_DEV=$(_lan_dev)
		[ -n "$LAN_DEV" ] && IFB="$LAN_DEV"
	fi
}

################################################################################
### BANDWIDTH CALC                                                           ###
################################################################################
# Auto download cap (HFSC/HTB), as a multiple of the shaped upload: how much
# download the uplink can carry the ACKs for. With delayed ACK, one ACK per
# two full segments:
#   ack_wire  = 52 + overhead      (IPv4 20 + TCP 20 + 12 bytes of options)
#   data_wire = 1500 + overhead
#   ratio     = share * 2 * data_wire / ack_wire
# share = the part of the uplink given to ACKs: 60% (19x on PPPoE overhead
# 44, 26x on ethernet 18), 90% with the ACK filter on (ACKs at 5% of upload).
_auto_bw_ratio() {
	local _oh="${OVERHEAD:-44}" _share=60 _ack _data _r
	_isnum "$_oh" || _oh=44
	[ "$ACK_ON" = "yes" ] && _share=90
	_ack=$((52 + _oh))
	_data=$((1500 + _oh))
	_r=$((2 * _data * _share / (_ack * 100)))
	# Floor 4x; ceiling 99, the UI's range for a manual ratio.
	[ "$_r" -lt 4 ]  && _r=4
	[ "$_r" -gt 99 ] && _r=99
	echo "$_r"
}

# Gaming class (1:10) rate inside 1:1, as SimpleHFSCgamerscript: game_pct %
# of RATE + game_floor kbit; sets _GG. Under the Adaptive EF guard a game
# flow keeps EF up to udp_fast_pps packets and udp_fast_pps x packet_size
# bytes a second, so 1:10 is never below that rate (held to a fifth of the
# rate). Never over 85% of the rate: the floor alone exceeds a link under
# ~2.7 Mbit.
_game_rate() {
	local gd=0
	_GG=$(( $1 * ${GAME_PCT:-15} / 100 + ${GAME_FLOOR:-400} ))
	[ "$NFT_MODE" = adaptive ] &&
		gd=$((${UDP_FAST_PPS:-450} * ${HFSC_PKTSZ:-576} * 8 / 1000))
	[ "$gd" -gt $(($1 / 5)) ] && gd=$(($1 / 5))
	[ "$_GG" -lt "$gd" ] && _GG=$gd
	[ "$_GG" -gt $(($1 * 85 / 100)) ] && _GG=$(($1 * 85 / 100))
	[ "$_GG" -lt 1 ] && _GG=1
	return 0
}

calc_bandwidth() {
	local _bw_ratio="${BW_MAX_RATIO:-auto}"
	local _hr="${BW_HEADROOM:-90}"

	# upload_kbps / download_kbps are the LINE rate; the shaped rate is that
	# minus the headroom, which keeps the queue in this router instead of the
	# ISP's buffer. Derived from LINE_* every call, so it never compounds.
	LINE_UP_KBPS="${LINE_UP_KBPS:-$UPLOAD_KBPS}"
	LINE_DN_KBPS="${LINE_DN_KBPS:-$DOWNLOAD_KBPS}"
	UPLOAD_KBPS=$((LINE_UP_KBPS * _hr / 100))
	DOWNLOAD_KBPS=$((LINE_DN_KBPS * _hr / 100))
	# Line rate 0 = that direction unshaped: no root qdisc (upload) or no IFB,
	# ingress and ctinfo (download). Classification still runs.
	SHAPE_UP=1; [ "$LINE_UP_KBPS" -eq 0 ] && SHAPE_UP=0
	SHAPE_DN=1; [ "$LINE_DN_KBPS" -eq 0 ] && SHAPE_DN=0
	[ "$SHAPE_UP" = 1 ] && [ "$UPLOAD_KBPS"   -lt 1 ] && UPLOAD_KBPS=1
	[ "$SHAPE_DN" = 1 ] && [ "$DOWNLOAD_KBPS" -lt 1 ] && DOWNLOAD_KBPS=1

	# The ACK filter is decided before the download cap: the cap is an ACK
	# budget and the filter changes it. It reads the headroomed rates, never
	# the capped download (that would be circular).
	local up=$((UPLOAD_KBPS / 1000)) dn=$((DOWNLOAD_KBPS / 1000))
	case "$ACK_FILTER" in
		on|yes) ACK_ON="yes" ;;
		off|no) ACK_ON="no"  ;;
		auto|*)
			# In kbit at every rate: whole Mbit truncated a 1.98 Mbit upload to
			# 1, so auto fired at 7.7x instead of the documented 14x.
			if [ "$DOWNLOAD_KBPS" -gt $((UPLOAD_KBPS * 14)) ]; then ACK_ON="yes"
			else ACK_ON="no"; fi ;;
	esac
	# Thinning protects a shaped upload; unshaped there is no rate to size it.
	[ "$SHAPE_UP" = 1 ] || ACK_ON="no"

	# MSS gate inputs, taken before the ratio cap: the cap is an ACK budget, not
	# the line's speed (a 10/0.1 line caps to ~1.9 Mbit). Headroom counts.
	MSS_RATE_UP="$UPLOAD_KBPS"
	MSS_RATE_DN="$DOWNLOAD_KBPS"

	# Download cap: HFSC/HTB only (CAKE has no such failure). BW_RATIO_EFF is
	# what was applied, for status and the UI.
	[ "$QDISC" = "cake" ] && _bw_ratio="off"
	# Nothing to cap unless both directions are shaped.
	[ "$SHAPE_UP$SHAPE_DN" = 11 ] || _bw_ratio="off"
	BW_RATIO_EFF="off"
	case "$_bw_ratio" in
		""|0|off|Off|OFF) ;;  # no cap
		auto|Auto|AUTO)
			BW_RATIO_EFF=$(_auto_bw_ratio)
			local _max_down=$((UPLOAD_KBPS * BW_RATIO_EFF))
			[ "$DOWNLOAD_KBPS" -gt "$_max_down" ] && DOWNLOAD_KBPS="$_max_down"
			;;
		*)
			if _isnum "$_bw_ratio" && [ "$_bw_ratio" -gt 0 ]; then
				BW_RATIO_EFF="$_bw_ratio"
				local _max_down=$((UPLOAD_KBPS * _bw_ratio))
				[ "$DOWNLOAD_KBPS" -gt "$_max_down" ] && DOWNLOAD_KBPS="$_max_down"
			fi
			;;
	esac
	_game_rate "$UPLOAD_KBPS";   GAME_UP=$_GG
	_game_rate "$DOWNLOAD_KBPS"; GAME_DN=$_GG
	[ "$SHAPE_UP" = 1 ] || GAME_UP=0
	[ "$SHAPE_DN" = 1 ] || GAME_DN=0
	# Byte windows from the shaped download, each capped by its ceiling.
	local _nref="$DOWNLOAD_KBPS" _bref="$DOWNLOAD_KBPS"
	# Download unshaped = rate unknown: both windows at their caps.
	[ "$SHAPE_DN" = 1 ] || { _nref=1000000; _bref=1000000; }
	[ "$_nref" -gt $((${TCP_NEW_CAP:-80}   * 1000)) ] && _nref=$((${TCP_NEW_CAP:-80}   * 1000))
	[ "$_bref" -gt $((${TCP_BULK_CAP:-400} * 1000)) ] && _bref=$((${TCP_BULK_CAP:-400} * 1000))
	FIRST_500MS=$((_nref * 500 / 8))
	# * 1250, not * 10000 / 8: keeps the intermediate under INT32_MAX.
	FIRST_10S=$((_bref * 1250))
	# Bulk window above the new-flow window, or a flow is Bulk while still new.
	[ "$FIRST_10S" -gt "$FIRST_500MS" ] || FIRST_10S=$((FIRST_500MS * 2))

	# Post-cap value: what the shaper applies and shows.
	dn=$((DOWNLOAD_KBPS / 1000))
	# Cleared every call, so an off filter reports empty in status.
	SLOW_ACK=""; MED_ACK=""; FAST_ACK=""; XFAST_ACK=""; ACKRATE=""
	if [ "$ACK_ON" = "yes" ]; then
		ACKRATE=$((UPLOAD_KBPS * 5 / 100))
			# Floor 1: `limit rate over 0/second` fails the whole table, and
			# ack_filter=on can force this branch on any line.
		[ "$ACKRATE" -lt 1 ] && ACKRATE=1
		SLOW_ACK="$ACKRATE"
		MED_ACK="$ACKRATE"
		FAST_ACK=$((ACKRATE * 10))
		XFAST_ACK=$((ACKRATE * 100))
	fi
	BW_UP_M="$up"; BW_DN_M="$dn"

	# After the ratio cap: MSS sizes from the final rates.
	calc_mss
}

################################################################################
### MSS CLAMP                                                                ###
###                                                                          ###
### Serialisation delay: a 1500-byte frame takes 4 ms at 3 Mbit/s and 12 ms   ###
### at 1 Mbit/s, which outweighs the queueing budget on a slow uplink. A      ###
### smaller MSS bounds it, at a header cost, so it only pays on slow links.   ###
### Each direction is gated on its own shaped rate.                          ###
###                                                                          ###
### An MSS option says what the SENDER of that segment will RECEIVE:         ###
###   inbound SYN-ACK  (iifname WAN) -> bounds OUR UPLOAD segment size        ###
###   outbound SYN     (oifname WAN) -> bounds OUR DOWNLOAD segment size      ###
################################################################################
MSS_FLOOR=536      # RFC 1122 minimum-MTU MSS. Below this, stacks and middle-
                   # boxes get unreliable and goodput falls off a cliff.
MSS_CEIL=1460      # IPv4 MSS on a 1500-byte MTU.
MSS_BUDGET_MS=3    # auto mode: serialisation budget for one full segment.

# Effective MSS for one direction: echoes the bytes, or nothing = no clamp.
_mss_for_rate() {
	# $1 = rate the gate reads (pre-cap), $2 = rate the size comes from
	# (final); they differ only on HFSC/HTB with a binding ratio cap.
	local _gate_rate="$1" _rate="$2" _v _oh
	# Rate 0 = unshaped, not slow: never clamped.
	_isnum "$_gate_rate" && [ "$_gate_rate" -ge 1 ] && [ "$_gate_rate" -lt "$MSS_GATE" ] || return 0
	if [ "$MSS_MODE" = "auto" ]; then
		# Bytes drainable in MSS_BUDGET_MS, less IPv4+TCP headers and the link
		# overhead (t_ms = 8 * bytes / kbps). OVERHEAD gets a local guard: a
		# non-number here would be a fatal ash error.
		_oh="$OVERHEAD"
		_isnum "$_oh" || _oh=44
		_v=$(( _rate * MSS_BUDGET_MS / 8 - 40 - _oh ))
	else
		_v="$MSS_FIXED"
	fi
	[ "$_v" -lt "$MSS_FLOOR" ] && _v="$MSS_FLOOR"
	[ "$_v" -gt "$MSS_CEIL"  ] && _v="$MSS_CEIL"
	echo "$_v"
}

# MSS_CLAMP / MSS_GATE -> MSS_UP, MSS_DN (empty = not clamped). Called from
# calc_bandwidth, so start, status and debug agree.
calc_mss() {
	MSS_UP=""; MSS_DN=""; MSS_MODE="off"; MSS_FIXED=""
	_isnum "${MSS_GATE:-}" || { msg "mss_max_kbps '$MSS_GATE' invalid - defaulting to 3000"; MSS_GATE=3000; }
	case "$MSS_CLAMP" in
		""|0|off|Off|OFF|no|No|NO) return 0 ;;
		auto|Auto|AUTO) MSS_MODE="auto" ;;
		*)
				# _isnum first: this value goes into nft text and $(( )), where a
				# leading zero is octal or fatal.
			if _isnum "$MSS_CLAMP" && [ "$MSS_CLAMP" -ge "$MSS_FLOOR" ] && [ "$MSS_CLAMP" -le "$MSS_CEIL" ]; then
				MSS_MODE="fixed"; MSS_FIXED="$MSS_CLAMP"
			else
				msg "mss '$MSS_CLAMP' out of range ${MSS_FLOOR}-${MSS_CEIL} - MSS clamping disabled"
				return 0
			fi ;;
	esac
	MSS_UP=$(_mss_for_rate "${MSS_RATE_UP:-$UPLOAD_KBPS}"   "$UPLOAD_KBPS")
	MSS_DN=$(_mss_for_rate "${MSS_RATE_DN:-$DOWNLOAD_KBPS}" "$DOWNLOAD_KBPS")
}

################################################################################
### INGRESS (IFB + ctinfo)                                                   ###
################################################################################
# Ownership is recorded, never guessed from a name or a qdisc kind: other
# shapers (qosify among them) also name their IFB ifb-<wan> and build cake /
# hfsc / htb roots, and treating theirs as ours deleted their download path
# (their redirect then pointed at nothing and dropped every inbound packet).
IFB_ALIAS="qos-ex"
# True when $1 is a device a QoS-Ex start built: the start stamp or the
# partial-start marker names it, or it is an IFB carrying our alias.
_dev_ours() {
	local _d="$1" _f _a=""
	[ -n "$_d" ] || return 1
	for _f in /var/run/qos-ex-started "$START_PART"; do
		[ -r "$_f" ] && grep -qxF -e "WAN=$_d" -e "IFB=$_d" "$_f" 2>/dev/null && return 0
	done
	[ -r "/sys/class/net/$_d/ifalias" ] && read -r _a < "/sys/class/net/$_d/ifalias"
	[ "$_a" = "$IFB_ALIAS" ]
}

# A root qdisc that is not ours belongs to another shaper: replacing it makes
# the two flap. Kernel defaults (mq, pfifo_fast, fq_codel, noqueue) are fine
# to replace; cake / cake_mq / hfsc / htb only when a start of ours built them.
_foreign_root() {
	local dev="$1" _r
	_r=$(tc qdisc show dev "$dev" root 2>/dev/null | awk 'NR==1{print $2}')
	case "${_r:-none}" in
		none|mq|mqprio|pfifo_fast|fq_codel|noqueue) return 0 ;;
		cake|cake_mq|hfsc|htb) _dev_ours "$dev" && return 0 ;;
	esac
	err "$dev already carries a '$_r' root qdisc that QoS-Ex did not build (another shaper?) - stop it first"
	return 1
}

# The download side on the LAN device (download_on lan): a clsact from
# another tool (qosify, a BPF program) is refused; one with no ingress
# filter and only our ctinfo on egress is ours (a run that was killed).
# QoS-Ex filters only egress, so any ingress filter is another tool's. The
# root qdisc is _foreign_root's, by the caller.
_foreign_lan() {
	local _q _t
	_q=$(tc qdisc show dev "$IFB" 2>/dev/null)
	case "$_q" in *"qdisc clsact "*) ;; *) return 0 ;; esac
	_dev_ours "$IFB" && return 0
	_t=$(tc filter show dev "$IFB" ingress 2>/dev/null)
	[ -n "$_t" ] || _t=$(tc filter show dev "$IFB" egress 2>/dev/null | awk '
		/^filter / { n++ }
		/ctinfo/ { c++ }
		/mirred|bpf|pedit|police|skbedit/ { o = 1 }
		END { if (o || (n && !c)) print "other" }')
	[ -z "$_t" ] && return 0
	err "$IFB carries a clsact qdisc from another tool - stop it first"
	return 1
}

# The download side of another shaper on $WAN: SQM's ifb4<wan>, an ifb-<wan>
# that is not ours, a clsact (QoS-Ex uses ingress), or an ingress redirecting
# anywhere but our IFB. Checked before anything is deleted.
_foreign_ingress() {
	local _q _t
	[ "$DL_LAN" = 1 ] && { _foreign_lan; return $?; }
	if ip link show "ifb4$WAN" >/dev/null 2>&1; then
		err "another shaper is on $WAN (ifb4$WAN exists) - stop or disable it first"
		return 1
	fi
	if ip link show "$IFB" >/dev/null 2>&1 && ! _dev_ours "$IFB"; then
		err "$IFB exists but QoS-Ex did not create it (another shaper, such as qosify, uses the same name) - stop that shaper first; if it is left over from QoS-Ex: ip link del $IFB"
		return 1
	fi
	_q=$(tc qdisc show dev "$WAN" 2>/dev/null)
	case "$_q" in
		*"qdisc clsact "*)
			err "$WAN carries a clsact qdisc from another tool (qosify, a BPF program) - stop it first"
			return 1 ;;
		*"qdisc ingress "*) ;;
		*) return 0 ;;
	esac
	# The stamp or marker names this WAN: a start of ours built that ingress
	# (its redirect may dangle if the IFB was deleted under it).
	_dev_ours "$WAN" && return 0
	# An ingress whose filters only redirect to our IFB is ours (left by a run
	# that was killed); an empty one leaves nothing to break.
	_t=$(tc filter show dev "$WAN" parent ffff: 2>/dev/null | awk -v ifb="$IFB" '
		$1 == "filter" { n++ }
		{ for (i = 1; i < NF; i++) if ($i == "device") {
			d = $(i + 1); sub(/\).*/, "", d)
			if (d == ifb) ours = 1; else if (other == "") other = "redirects to " d } }
		END { if (other != "") print other; else if (n && !ours) print "has filters" }')
	[ -z "$_t" ] && return 0
	err "$WAN ingress $_t that QoS-Ex did not add (another shaper?) - stop it first"
	return 1
}

# sqm-scripts enabled on $WAN. Its root is a cake / hfsc / htb that
# _foreign_root cannot tell from ours, so the two would replace each other's
# qdiscs (its ingress IFB is caught in setup_ingress).
_sqm_on() {
	[ -x /etc/init.d/sqm ] && /etc/init.d/sqm enabled 2>/dev/null || return 1
	uci -q show sqm 2>/dev/null | awk -v w="$WAN" -v q="'" '
		{ k = $0; sub(/=.*/, "", k); v = $0; sub(/^[^=]*=/, "", v); gsub(q, "", v)
		  if (split(k, p, ".") != 3) next
		  if (p[3] == "enabled") e[p[2]] = v; else if (p[3] == "interface") i[p[2]] = v }
		END { for (s in i) if (i[s] == w && e[s] == "1") f = 1; exit !f }'
}

# HFSC / HTB class the download by the connmark that ctinfo copies into
# skb->mark (cpmark), not by the DSCP the packet arrived with: a remote host
# could otherwise mark a flood EF and fill the Gaming class. 0x80 = decided,
# low 6 bits = DSCP (see nft_classify_chains).
IFB_CPMARK=0xbf
# Defaults until load_config (settings.download_on): wan = IFB off the WAN.
DL_ON=wan
DL_LAN=0

# The download's ctinfo action into $_CTI (no forks), the same on the IFB's
# WAN ingress and on the LAN device's egress. CAKE picks its tin from the
# DSCP, so the DSCP is restored; with wash_down on every packet that has a
# conntrack entry (no state bit), so a connection QoS-Ex has not classed,
# the router's own, goes Best Effort, not where the sender's mark points.
# HFSC / HTB class by the mark; with wash_down they take only the mark, as
# the firewall clears the DSCP after the IFB (a restore would be undone)
# and before the LAN device's egress (it would hand the devices QoS-Ex's
# marks). Without wash_down the state bit stays: an unclassed connection
# keeps the DSCP it came with.
_ctinfo_act() {
	case "$QDISC$WASH_DOWN" in
		cakeyes)        _CTI="ctinfo dscp 63" ;;
		cake*)          _CTI="ctinfo dscp 63 128" ;;
		hfscyes|htbyes) _CTI="ctinfo cpmark $IFB_CPMARK" ;;
		*)              _CTI="ctinfo dscp 63 128 cpmark $IFB_CPMARK" ;;
	esac
}

setup_ingress() {
	[ "$DL_LAN" = 1 ] && { setup_lan_egress; return $?; }
	# Checked before the deletes: another shaper's download path must not be
	# removed (_start_locked has already checked; this is the backstop).
	_foreign_ingress || return 1
	_QOS_EX_TOUCH_ING=1
	ip link del "$IFB" 2>/dev/null
	tc qdisc del dev "$WAN" ingress 2>/dev/null
	# Loaded as OpenWrt loads kmod-ifb, with no ifb0 / ifb1 of its own
	# (OpenWrt's modprobe passes no module options; insmod does).
	_mod_loaded ifb || insmod ifb numifbs=0 2>/dev/null
	ip link add "$IFB" type ifb          || { err "IFB add failed ($IFB)"; return 1; }
	# The alias marks it as ours for stop and the next start (see _dev_ours).
	ip link set dev "$IFB" alias "$IFB_ALIAS" 2>/dev/null
	ip link set "$IFB" up                || { err "could not bring $IFB up"; return 1; }
	tc qdisc add dev "$WAN" handle ffff: ingress || { err "ingress qdisc add failed on $WAN"; return 1; }
	_ctinfo_act
	# Needs act_ctinfo and act_mirred (separate kmods): name the missing one.
	# shellcheck disable=SC2086  # $_CTI is a deliberate word list
	tc filter add dev "$WAN" parent ffff: protocol all matchall \
		action $_CTI mirred egress redirect dev "$IFB" || {
			_mod_loaded act_ctinfo || err "kmod-sched-ctinfo is not loaded"
			_mod_loaded act_mirred || err "act_mirred is not loaded"
			err "ingress redirect filter failed on $WAN"; return 1; }
	msg "Ingress redirect via ctinfo: $WAN -> $IFB"
}

cleanup_ingress() {
	if [ "$DL_LAN" = 1 ]; then
		tc qdisc del dev "$IFB" clsact 2>/dev/null
		return 0
	fi
	tc qdisc del dev "$WAN" ingress 2>/dev/null
	ip link set "$IFB" down 2>/dev/null
	ip link del "$IFB" 2>/dev/null
}

# download_on lan: the download qdisc sits on the LAN device's egress, so a
# packet is shaped once, where it leaves, with no IFB and no redirect. A
# clsact egress filter applies the connmark (_ctinfo_act) before the root
# qdisc, as the IFB's ingress filter does. Only what leaves through this
# device is shaped: routed traffic and the router's own traffic to the LAN,
# not frames the bridge forwards between LAN ports, nor traffic to the
# router itself.
setup_lan_egress() {
	_foreign_lan || return 1
	_QOS_EX_TOUCH_ING=1
	tc qdisc del dev "$IFB" clsact 2>/dev/null
	tc qdisc add dev "$IFB" clsact || { err "clsact qdisc add failed on $IFB"; return 1; }
	_ctinfo_act
	# shellcheck disable=SC2086  # $_CTI is a deliberate word list
	tc filter add dev "$IFB" egress protocol all matchall action $_CTI || {
		_mod_loaded act_ctinfo || err "kmod-sched-ctinfo is not loaded"
		err "egress ctinfo filter failed on $IFB"; return 1; }
	msg "Download on $IFB egress via ctinfo (no IFB)"
}

################################################################################
### DSCP -> CLASSID FILTERS (for HFSC & HTB)                                 ###
################################################################################
# THE DSCP table, name:codepoint:leaf, high priority first. The u32 filters
# and the nft @priomap are both generated from it. Nine marks in every rule
# set: AF11 = soft demote, CS1 = low-priority devices, LE = bulk (0x01: nft
# parses "le" as less-or-equal). CAKE diffserv4: AF11 Best Effort, CS1 / LE
# Bulk; diffserv8: LE lowest tin, CS1 / AF11 one above.
DSCP_SPEC="ef:46:10 cs5:40:11 cs4:32:11 af41:34:12 af42:36:12 af11:10:14 cs1:8:14 0x01:1:15 cs0:0:13"

# @priomap only covers forwarded egress (skb->priority); these u32 filters
# classify router-originated egress. One tc -batch for all; dsfield = cp<<2
# under 0xfc, IPv6 traffic class cp<<6 under 0x0FC0. Needs a full tc (cake,
# hfsc, u32, ctinfo).
add_dscp_filters() {
	local dev="$1" s cp cid
	for s in $DSCP_SPEC; do
		cp=${s#*:}; cid=${cp#*:}; cp=${cp%%:*}
		printf 'filter add dev %s parent 1: protocol ip   prio 1 u32 match ip dsfield 0x%02x 0xfc classid 1:%s\n' "$dev" $((cp << 2)) "$cid"
		printf 'filter add dev %s parent 1: protocol ipv6 prio 2 u32 match u16 0x%04X 0x0FC0 at 0 classid 1:%s\n' "$dev" $((cp << 6)) "$cid"
	done | tc -force -batch - || {
		err "DSCP filter install failed on $dev - download classification is incomplete"
		return 1; }
	return 0
}

# The IFB of HFSC / HTB: fw filters on the connmark ctinfo copied into
# skb->mark (decided | DSCP under $IFB_CPMARK). A packet with no QoS-Ex
# connmark (unsolicited, or a connection not classified yet) goes to the
# default class whatever DSCP it carries. cls_fw is in kmod-sched-core, with
# sch_hfsc and sch_htb.
add_ifb_filters() {
	local dev="$1" s cp cid
	for s in $DSCP_SPEC; do
		cp=${s#*:}; cid=${cp#*:}; cp=${cp%%:*}
		printf 'filter add dev %s parent 1: protocol all prio 1 handle 0x%x/%s fw classid 1:%s\n' "$dev" $((cp | 0x80)) "$IFB_CPMARK" "$cid"
	done | tc -batch - || {
		err "fw mark filter install failed on $dev"
		return 1; }
	return 0
}

################################################################################
### HFSC                                                                     ###
################################################################################
setup_hfsc_game_q() {
	local dev="$1" gr="$2" cls="$3" h="${3#1:}:" kind args lim _e
	[ "$gr" -le 0 ] && gr=1
	# The pfifo limit is also the last resort below: without a leaf of its
	# own the class keeps the kernel's pfifo of tx_queue_len (3 on PPP).
	lim=$((HFSC_PFMIN + HFSC_MAXDLY * gr / 8 / HFSC_PKTSZ))
	# limit 0 parses but drops every packet.
	[ "$lim" -lt 1 ] && lim=1
	kind="${HFSC_GAMEQ:-sfq}"
	case "$kind" in
		fq_codel)
			args="limit ${HFSC_FQ_LIMIT:-10240} flows ${HFSC_FQ_FLOWS:-1024} quantum ${HFSC_FQ_QUANTUM:-300}"
			args="$args target ${HFSC_FQ_TARGET:-5}ms interval ${HFSC_FQ_INTERVAL:-100}ms"
			;;
		bfifo)
			# max_delay ms x gr kbit/s = bits; /8 = bytes (MAXDEL * GAMERATE / 8).
			local blim=$((HFSC_MAXDLY * gr / 8))
			local bmin=${HFSC_BF_MIN:-3000}; _isnum "$bmin" && [ "$bmin" -gt 0 ] || bmin=3000
			[ "$blim" -lt "$bmin" ] && blim="$bmin"
			args="limit $blim"
			;;
		sfq)
			args="perturb ${HFSC_SFQ_PERTURB:-10} quantum ${HFSC_SFQ_QUANTUM:-300}"
			;;
		pfifo|*)
			kind=pfifo; args="limit $lim"
			;;
	esac
	# shellcheck disable=SC2086  # $args is a deliberate word list
	_e=$(tc qdisc add dev "$dev" parent "$cls" handle "$h" "$kind" $args 2>&1) && return 0
	# A value the kernel rejects: the same qdisc with its own defaults, then
	# a pfifo sized as above.
	log "$kind rejected '$args' on $dev $cls: ${_e:-no error text} - retrying with defaults"
	[ "$kind" != pfifo ] && tc qdisc add dev "$dev" parent "$cls" handle "$h" "$kind" 2>/dev/null && return 0
	tc qdisc add dev "$dev" parent "$cls" handle "$h" pfifo limit "$lim"
}

################################################################################
### Default leaf (1:11..1:15) — fq_codel / sfq                               ###
###                                                                          ###
### Manual: every knob from UCI, defaulting to the qdisc's OpenWrt default.  ###
### Auto: rate-sensitive values derived from the shaped rate. A value tc     ###
### rejects is logged and retried with the bare qdisc.                       ###
################################################################################

# Bounded integer into _LEAFV: _leaf_range VALUE FALLBACK MIN MAX. Out of
# band = clamped to the nearest bound; non-numeric or empty = FALLBACK. The
# bounds keep a leaf working (a 1-packet limit parses but kills it).
_leaf_range() {
	_LEAFV="$2"
	case "$1" in
		''|*[!0-9]*|0[0-9]*) : ;;
		*)           _LEAFV="$1" ;;
	esac
	# Over 10 digits the shell cannot compare it: clamp to the ceiling.
	case "$_LEAFV" in
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) _LEAFV="$4" ;;
	esac
	[ "$_LEAFV" -lt "$3" ] 2>/dev/null && _LEAFV="$3"
	[ "$_LEAFV" -gt "$4" ] 2>/dev/null && _LEAFV="$4"
	return 0
}

# sfq divisor: a power of two <= 65536 or EINVAL; otherwise FALLBACK.
_leaf_pow2() {
	_LEAFV="$2"
	case "$1" in
		''|*[!0-9]*|0[0-9]*) return 0 ;;
	esac
	[ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65536 ] 2>/dev/null || return 0
	[ $(( $1 & ($1 - 1) )) -eq 0 ] && _LEAFV="$1"
	return 0
}

# fq_codel memory_limit as MB. tc prints sizes with a unit when exact
# ("32Mb", "1Gb", "2000Kb"), raw bytes ("21250000b") otherwise.
mem_bytes_to_mb() {
	awk '{
		if (match($0, /memory_limit [0-9]+[A-Za-z]*/)) {
			s = substr($0, RSTART, RLENGTH)
			sub(/^memory_limit /, "", s)
			n = s; gsub(/[^0-9]/, "", n)
			u = s; gsub(/[0-9]/, "", u)
			b = n + 0
			if      (u == "Kb" || u == "kb") b = b * 1024
			else if (u == "Mb" || u == "mb") b = b * 1048576
			else if (u == "Gb" || u == "gb") b = b * 1073741824
			m = b / 1048576
			out = (m < 1) ? int(b / 1024) "kb" : (m == int(m)) ? m "mb" : sprintf("%.1fmb", m)
			$0 = substr($0, 1, RSTART - 1) "memory_limit " out substr($0, RSTART + RLENGTH)
		}
		print
	}'
}

# Leaf qdiscs 1:11-1:15 on $1 as tc holds them, one "<cid> <qdisc ...>" line
# each (stats text and status keys).
_leaf_lines() {
	tc qdisc show dev "$1" 2>/dev/null | mem_bytes_to_mb | awk '
		$1 == "qdisc" && $4 == "parent" && $5 ~ /^1:1[1-5]$/ {
			s = $2; for (i = 6; i <= NF; i++) s = s " " $i
			print substr($5, 3), s
		}' | sort
}

# Root qdisc of $1 as tc holds it, kind and options; empty when none.
_root_line() {
	tc qdisc show dev "$1" root 2>/dev/null | awk '
		NR == 1 && $1 == "qdisc" {
			i = ($5 == "refcnt") ? 7 : 5; s = $2
			for (; i <= NF; i++) s = s " " $i
			print s; exit
		}'
}

################################################################################
### Auto-tuning for the default leaves                                       ###
###                                                                          ###
### Derived from the shaped rate of the direction being built (UPLOAD_KBPS   ###
### on the WAN, DOWNLOAD_KBPS on the IFB). Flow counts, divisors, depth and   ###
### perturb follow the household's flow count, not link speed: defaults.     ###
################################################################################

# CoDel target: 5 ms, or on a slow link the time to send one worst-case
# packet (33 ATM cells, 13992 bits); interval 95 ms + target. Microseconds;
# $1 = shaped rate in kbit/s.
_leaf_auto_target() {
	_isnum "${1:-}" && [ "$1" -ge 1 ] || { _LEAFV=13992000; return 0; }
	_LEAFV=$(( 13992000 / $1 ))
	[ "$_LEAFV" -lt 5000 ] && _LEAFV=5000
	return 0
}
_leaf_auto_interval() {
	_leaf_auto_target "$1"
	_LEAFV=$(( 95000 + _LEAFV ))
	return 0
}

# Quantum: 300 B up to 100 Mbit (small packets get their share), a full frame
# above (300 B costs five DRR rounds per frame on a busy CPU).
_leaf_auto_quantum() {
	if [ "$1" -le 100000 ]; then _LEAFV=300; else _LEAFV=1514; fi
	return 0
}

# fq_codel packet limit: 1001, rising with 40 ms of rate in 1500 B packets
# (rate/300) from 300 Mbit, up to fq_codel's 10240.
_leaf_auto_limit() {
	_LEAFV=$(( $1 / 300 ))
	[ "$_LEAFV" -lt 1001 ]  && _LEAFV=1001
	[ "$_LEAFV" -gt 10240 ] && _LEAFV=10240
	return 0
}

# memory_limit: 200 ms of the shaped rate (rate kbit x 25 B), as
# SimpleHFSCgamerscript. It counts truesize: on the IFB downloads arrive
# GRO-merged up to 64 KB per skb. Floor 2 MB; cap 32 MB and RAM/32 per leaf
# (ten leaves; only a standing queue uses it). Then to the nearest whole
# MB, 1 at least: tc shows a whole MB as "21Mb", any other size in bytes.
_leaf_auto_mem() {
	local _cap=33554432 _memkb
	_memkb=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)
	case "$_memkb" in
		''|*[!0-9]*|0[0-9]*) _memkb=0 ;;
	esac
	# MemTotal kB * 1024 / 32 = kB * 32.
	[ "$_memkb" -gt 0 ] && [ $(( _memkb * 32 )) -lt "$_cap" ] && _cap=$(( _memkb * 32 ))
	_LEAFV=$(( $1 * 25 ))
	[ "$_LEAFV" -lt 2097152 ] && _LEAFV=2097152
	[ "$_LEAFV" -gt "$_cap" ] && _LEAFV="$_cap"
	_LEAFV=$(( (_LEAFV + 524288) / 1048576 * 1048576 ))
	[ "$_LEAFV" -lt 1048576 ] && _LEAFV=1048576
	return 0
}

# sfq limit: ~100 ms of rate in 1500 B packets (rate/120), 127..8000.
_leaf_auto_sfq_limit() {
	_LEAFV=$(( $1 / 120 ))
	[ "$_LEAFV" -lt 127 ]  && _LEAFV=127
	[ "$_LEAFV" -gt 8000 ] && _LEAFV=8000
	return 0
}

# sfq per-flow RED + ECN (sfq has no AQM): a flow's queue is marked or dropped
# as it grows. Bytes of that flow's backlog: min = the CoDel target's worth of
# rate, between 3 frames and a quarter of a full flow (127 x 1514 B); max =
# 3 x min; redflowlimit = a full flow; Bulk (1:15) min x 2. $1 = rate kbit/s,
# $2 = class; tc arguments into _LEAFV. Split as (us / 100) / 10 for 32 bits.
_leaf_auto_sfq_red() {
	local _f=192278 _m
	_leaf_auto_target "$1"
	_m=$(( $1 / 8 * (_LEAFV / 100) / 10 ))
	[ "$2" = "1:15" ] && _m=$(( _m * 2 ))
	[ "$_m" -lt 4542 ] && _m=4542
	[ "$_m" -gt $(( _f / 4 )) ] && _m=$(( _f / 4 ))
	_LEAFV="redflowlimit $_f min $_m max $(( _m * 3 )) probability 0.10 ecn"
	return 0
}

setup_default_leaf() {
	local dev="$1" parent="$2" rate="$3"
	[ "${rate:-0}" -gt 0 ] 2>/dev/null || rate=1000
	local qd="${DEFAULT_QDISC:-fq_codel}"
	local args ivl tgt mem qnt red="" dep div flw m
	case "$qd" in sfq) : ;; *) qd=fq_codel ;; esac

	if [ "${DEF_TUNE_MODE:-auto}" = "manual" ]; then
	case "$qd" in
		sfq)
			_leaf_range "$DEF_SFQ_LIMIT"   127 16 65535;    args="limit $_LEAFV"
			_leaf_range "$DEF_SFQ_DEPTH"   127  1   127;    dep=$_LEAFV
			_leaf_pow2  "$DEF_SFQ_DIVISOR" 1024;            div=$_LEAFV
			[ "$div" -lt 16 ] && div=16
			_leaf_range "$DEF_SFQ_FLOWS"   127  1 65408;    flw=$_LEAFV
			# The kernel caps the limit at depth x min(flows, divisor): keep that
			# at 16 or more. A 1-packet sfq is CVE-2025-37752's trigger on older
			# kernels and EINVAL (manual values dropped) on fixed ones.
			m=$flw; [ "$div" -lt "$m" ] && m=$div
			[ $((dep * m)) -ge 16 ] || dep=$(( (16 + m - 1) / m ))
			args="$args depth $dep divisor $div flows $flw"
			_leaf_range "$DEF_SFQ_QUANTUM" 1514 256 65535;  args="$args quantum $_LEAFV"
			# perturb 0 = rehashing off, so its floor is 0.
			_leaf_range "${DEF_SFQ_PERTURB:-10}" 10 0 3600; args="$args perturb $_LEAFV"
			[ "${DEF_SFQ_HEADDROP:-no}" = "yes" ] && args="$args headdrop"
			;;
		fq_codel|*)
			_leaf_range "$DEF_FQ_INTERVAL" 100 1 10000; ivl="$_LEAFV"
			_leaf_range "$DEF_FQ_TARGET"     5 1 10000; tgt="$_LEAFV"
			# A target at or above interval disables CoDel: keep it below.
			[ "$tgt" -ge "$ivl" ] && tgt=$(( ivl / 2 ))
			[ "$tgt" -lt 1 ] && tgt=1
			# Whole MB in UCI; tc carries bytes as u32, so 4095 MB at most.
			_leaf_range "$DEF_FQ_MEMORY_MB" 4 1 4095; mem=$(( _LEAFV * 1048576 ))
			_leaf_range "$DEF_FQ_LIMIT"   10240 16 1000000; args="limit $_LEAFV"
			_leaf_range "$DEF_FQ_FLOWS"    1024  2   65536; args="$args flows $_LEAFV"
			_leaf_range "$DEF_FQ_QUANTUM"  1514 256 65535;  args="$args quantum $_LEAFV"
			args="$args target ${tgt}ms interval ${ivl}ms memory_limit $mem"
			if [ "${DEF_FQ_ECN:-ecn}" = "noecn" ]; then
				args="$args noecn"
			else
				args="$args ecn"
			fi
			;;
	esac
	else
		# Auto reads none of the manual fields.
		case "$qd" in
			sfq)
				# flows 1024: one slot per hash bucket. headdrop: no AQM, so drop
				# the oldest. red: see _leaf_auto_sfq_red.
				_leaf_auto_sfq_limit "$rate"; args="limit $_LEAFV"
				args="$args depth 127 divisor 1024 flows 1024"
				_leaf_auto_quantum "$rate";   args="$args quantum $_LEAFV"
				args="$args perturb 10 headdrop"
				_leaf_auto_sfq_red "$rate" "$parent"; red="$_LEAFV"
				;;
			fq_codel|*)
				_leaf_auto_interval "$rate"; ivl="$_LEAFV"
				_leaf_auto_target   "$rate"; tgt="$_LEAFV"
				# Bulk (1:15) runs CoDel twice as loose.
				[ "$parent" = "1:15" ] && { ivl=$((ivl * 2)); tgt=$((tgt * 2)); }
				_leaf_auto_quantum  "$rate"; qnt="$_LEAFV"
				_leaf_auto_mem      "$rate"; mem="$_LEAFV"
				_leaf_auto_limit    "$rate"
				args="limit $_LEAFV flows 1024 quantum $qnt"
				args="$args target ${tgt}us interval ${ivl}us memory_limit $mem ecn"
				;;
		esac
	fi

	local _e
	# shellcheck disable=SC2086  # $args / $red are deliberate word lists
	_e=$(tc qdisc add dev "$dev" parent "$parent" "$qd" $args $red 2>&1) && return 0
	# RED needs tc and kernel support: retry the Auto line without it first.
	if [ -n "$red" ]; then
		log "sfq RED/ECN rejected on $dev $parent: ${_e:-no error text} — sfq without it"
		# shellcheck disable=SC2086
		_e=$(tc qdisc add dev "$dev" parent "$parent" "$qd" $args 2>&1) && return 0
	fi
	# Last resort: a bare qdisc always parses. The kernel's reason is logged:
	# for a cross-field sfq constraint it is the only clue.
	log "$qd leaf rejected '$args' on $dev $parent: ${_e:-no error text} — falling back to kernel defaults"
	tc qdisc add dev "$dev" parent "$parent" "$qd" || {
		err "no leaf qdisc on $dev $parent - that class is unmanaged"; return 1; }
	return 0
}

# $1 percent of $2 kbit, floored at 1: a 0-rate curve parses but never gets
# service.
_kbit_pct() { _KV=$(( $1 * $2 / 100 )); [ "$_KV" -lt 1 ] && _KV=1; return 0; }

# Link-share curves, classid:m1%:m2%.
HFSC_LS_SPEC="11:10:5 12:35:20 13:45:55 14:7:10 15:3:10"

# HTB 1:11-1:15 as cid:share%:prio. Shares = HFSC m2 shares, summing to 100
# of what 1:10 leaves (rate - gaming), so guarantees sum to 1:1. All may
# borrow up to the shaped rate.
HTB_CLS_SPEC="11:5:1 12:20:2 13:55:3 14:10:4 15:10:5"

# The class tree as `cid|name|up_kbps|dn_kbps|detail`, read by the text report
# and @@STATE@@. Silent under CAKE.
_class_scheme() {
	_cs_spec="" _cs_s="" _cs_cid="" _cs_rest="" _cs_a="" _cs_b="" _cs_c="" _cs_nm=""
	case "$QDISC" in
		hfsc)
			echo "10|Gaming|${GAME_UP}|${GAME_DN}|rt only, inside 1:1"
			for _cs_spec in $HFSC_LS_SPEC; do
				_cs_cid=${_cs_spec%%:*}; _cs_rest=${_cs_spec#*:}
				_cs_a=${_cs_rest%%:*}; _cs_b=${_cs_rest#*:}
				_class_name "$_cs_cid"; _cs_nm="$_CN"
				_cs_f=""; [ "$_cs_cid" = 11 ] && [ "${VOICE_RT:-yes}" = "yes" ] && _cs_f="rt m1 $((_cs_b * 2))% m2 ${_cs_b}% (min ${VOICE_RT_MIN}k), "
				echo "${_cs_cid}|${_cs_nm}|$((UPLOAD_KBPS*_cs_b/100))|$((DOWNLOAD_KBPS*_cs_b/100))|${_cs_f}ls m1 ${_cs_a}% m2 ${_cs_b}%"
			done
			;;
		htb)
			echo "10|Gaming|${GAME_UP}|${GAME_DN}|rate = ceil, inside 1:1, prio 0"
			for _cs_spec in $HTB_CLS_SPEC; do
				_cs_cid=${_cs_spec%%:*}; _cs_rest=${_cs_spec#*:}
				_cs_a=${_cs_rest%%:*}; _cs_c=${_cs_rest#*:}
				_class_name "$_cs_cid"; _cs_nm="$_CN"
				echo "${_cs_cid}|${_cs_nm}|$(((UPLOAD_KBPS-GAME_UP)*_cs_a/100))|$(((DOWNLOAD_KBPS-GAME_DN)*_cs_a/100))|rate ${_cs_a}%, ceil 100%, prio ${_cs_c}"
			done
			;;
	esac
}

# Result in $_CN: no subshell per call on a polled path.
_class_name() {
	case "$1" in
		10) _CN="Gaming" ;; 11) _CN="Voice" ;; 12) _CN="Video" ;;
		13) _CN="Default" ;; 14) _CN="Low" ;; 15) _CN="Bulk" ;;
		*)  _CN="Class" ;;
	esac
	return 0
}

# The HFSC / HTB size table, into $_STAB. stab charges skb->len + overhead,
# and on an Ethernet WAN (and its IFB, where mirred pushes the MAC header
# back) skb->len already holds the 14-byte header that CAKE takes off before
# adding its overhead: take it off here too, so one overhead value means the
# same to every qdisc. mpu as well as overhead (as CAKE): small frames are
# otherwise under-charged. atm pads to 53-byte cells (ADSL). The charge is
# once per packet: a GRO / GSO burst pays one overhead and none of its
# segments' headers, so bulk TCP runs 3-5% over the rate (90% Headroom
# covers it).
_stab_args() {   # $1 = the device the qdisc goes on
	local _t="" _oh="$OVERHEAD" _d="$WAN"
	# The IFB carries the WAN's header; the LAN device (download_on lan) its own.
	[ "$DL_LAN" = 1 ] && [ "$1" = "$IFB" ] && _d="$1"
	[ -r "/sys/class/net/$_d/type" ] && read -r _t < "/sys/class/net/$_d/type"
	[ "$_t" = 1 ] && _oh=$((_oh - 14))
	_STAB="stab mpu $MPU overhead $_oh linklayer ${LINKLAYER:-ethernet}"
}

# The class tree goes in as one tc -batch: the root's `default 13` names a
# class that must exist at once, or every unclassified packet is dropped
# until it does (it took five tc runs).
_tc_tree() {   # $1 = dev, stdin = tc -batch lines
	local _e
	_e=$(tc -batch - 2>&1) && return 0
	err "$QDISC class tree failed on $1: ${_e:-no error text}"
	return 1
}

setup_hfsc() {
	local dev="$1" rate="$2" gr="$3"
	_foreign_root "$dev" || return 1
	_QOS_EX_TOUCH_ROOT="$_QOS_EX_TOUCH_ROOT $dev"
	local dur gb spec cid rest m1 m2 c vr=0 vb=0 rtc cap2
	# 1:10 inside 1:1 (SimpleHFSCgamerscript): rt only, burst game_burst x its
	# rate for $dur, held to 97% of the rate. voice_rt: Voice (1:11) rt at 5%
	# of the rate, at least VOICE_RT_MIN, at most 90%, burst twice that.
	if [ "${VOICE_RT:-yes}" = "yes" ]; then
		_kbit_pct "$rate" 5; vr=$_KV
		[ "$vr" -lt "$VOICE_RT_MIN" ] && vr=$VOICE_RT_MIN
		[ "$vr" -gt $((rate * 90 / 100)) ] && vr=$((rate * 90 / 100))
		[ "$vr" -lt 1 ] && vr=1
		vb=$((vr * 2)); [ "$vb" -gt $((rate * 97 / 100)) ] && vb=$vr
	fi
	# m1 slope time: five full frames, at least 50 ms.
	dur=$((5 * 1500 * 8 / rate)); [ "$dur" -lt 50 ] && dur=50
	[ "$dur" -gt 1000 ] && dur=1000
	gb=$((gr * ${GAME_BURST:-10})); [ "$gb" -gt $((rate * 97 / 100)) ] && gb=$((rate * 97 / 100))
	[ "$gb" -lt 1 ] && gb=1
	# Real-time service is given before link-sharing and `ul` does not bound
	# it: Gaming + Voice rt must fit inside the shaped rate, or on a slow line
	# they send past it (the queue moves to the modem) and starve the rest.
	# m2 together at most 90%, m1 at most 100%; Voice gives way first.
	if [ "$vr" -gt 0 ]; then
		cap2=$((rate * 90 / 100))
		[ $((gr + vr)) -gt "$cap2" ] && vr=$((cap2 - gr))
		if [ "$vr" -lt 1 ]; then
			vr=0; vb=0
		else
			[ "$vb" -lt "$vr" ] && vb=$vr
			[ $((gb + vb)) -gt "$rate" ] && vb=$((rate - gb))
			if [ "$vb" -lt "$vr" ]; then
				vb=$vr; gb=$((rate - vb)); [ "$gb" -lt "$gr" ] && gb=$gr
			fi
		fi
	fi
	_stab_args "$dev"
	tc qdisc del dev "$dev" root 2>/dev/null
	{
		printf 'qdisc replace dev %s handle 1: root %s hfsc default 13\n' "$dev" "$_STAB"
		printf 'class add dev %s parent 1: classid 1:1 hfsc ls m2 %skbit ul m2 %skbit\n' "$dev" "$rate" "$rate"
		printf 'class add dev %s parent 1:1 classid 1:10 hfsc rt m1 %skbit d %sms m2 %skbit\n' "$dev" "$gb" "$dur" "$gr"
		for spec in $HFSC_LS_SPEC; do
			cid=${spec%%:*}; rest=${spec#*:}
			_kbit_pct "$rate" "${rest%%:*}"; m1=$_KV
			_kbit_pct "$rate" "${rest#*:}";  m2=$_KV
			rtc=""; [ "$cid" = 11 ] && [ "$vr" -gt 0 ] && rtc="rt m1 ${vb}kbit d ${dur}ms m2 ${vr}kbit "
			printf 'class add dev %s parent 1:1 classid 1:%s hfsc %sls m1 %skbit d %sms m2 %skbit\n' "$dev" "$cid" "$rtc" "$m1" "$dur" "$m2"
		done
	} | _tc_tree "$dev" || return 1
	# Not fatal (the class keeps a default qdisc), so reported, not returned.
	setup_hfsc_game_q "$dev" "$gr" "1:10" || err "gaming qdisc ($HFSC_GAMEQ) failed on $dev 1:10 - using the kernel default"
	local lfail=0
	for c in 13 11 12 14 15; do
		setup_default_leaf "$dev" "1:$c" "$rate" || lfail=$((lfail + 1))
	done
	[ "$lfail" = 0 ] || err "$lfail default leaf(es) unmanaged on $dev"
	if [ "$dev" = "$IFB" ]; then add_ifb_filters "$dev" || return 1
	else add_dscp_filters "$dev" || return 1; fi
}

################################################################################
### HTB                                                                      ###
################################################################################
# Result in $_HV (no fork per call). d/8 first keeps r * d under INT32_MAX at
# a gigabit; every d used (1000, 5000, 10000) divides by 8.
htb_q() { local r=$1 d=${2:-1000};  _HV=$(( r * (d / 8) / 1000 )); [ "$_HV" -lt 1500 ] && _HV=1500; [ "$_HV" -gt 200000 ] && _HV=200000; return 0; }
htb_b() { local r=$1 d=${2:-10000}; _HV=$(( r * (d / 8) / 1000 )); [ "$_HV" -lt 1500 ] && _HV=1500; return 0; }

setup_htb() {
	local dev="$1" rate="$2" gr="$3"
	_foreign_root "$dev" || return 1
	_QOS_EX_TOUCH_ROOT="$_QOS_EX_TOUCH_ROOT $dev"
	local qroot broot
	htb_q "$rate";       qroot=$_HV
	htb_b "$rate" 1000;  broot=$_HV
	_stab_args "$dev"
	tc qdisc del dev "$dev" root 2>/dev/null

	# 1:10 inside 1:1, rate = ceil = $gr: borrows nothing. The five shares
	# split rate - $gr, so the rates sum to 1:1. Every other class may borrow
	# up to the shaped rate, lent by prio, and always keeps its own rate.
	local spec
	{
		printf 'qdisc replace dev %s handle 1: root %s htb default 13\n' "$dev" "$_STAB"
		printf 'class add dev %s parent 1: classid 1:1 htb rate %skbit ceil %skbit quantum %s burst %s cburst %s\n' \
			"$dev" "$rate" "$rate" "$qroot" "$broot" "$broot"
		# shellcheck disable=SC2086  # $HTB_CLS_SPEC is a deliberate word list
		for spec in "10:0:0" $HTB_CLS_SPEC; do
			local cid=${spec%%:*} rest=${spec#*:}
			local r=${rest%%:*} p=${rest#*:}
			local c=$rate cq cb cc bd=2000 cbd=1000 par="1:1"
			r=$(((rate - gr) * r / 100))
			[ "$r" -lt 1 ] && r=1
			[ "$cid" = 10 ] && { r=$gr; [ "$r" -lt 1 ] && r=1; c=$r; }
			[ "$c" -lt "$r" ] && c=$r
			htb_q "$r";        cq=$_HV
			# burst / cburst in microseconds of the class rate: a bucket is a burst
			# past the shaped rate, so 2 ms / 1 ms for the bulk classes. Gaming and
			# Voice keep 10 ms / 5 ms so a tick of small packets never waits.
			case "$cid" in 10|11) bd=10000; cbd=5000 ;; esac
			htb_b "$r" "$bd";   cb=$_HV
			htb_b "$r" "$cbd";  cc=$_HV
			printf 'class add dev %s parent %s classid 1:%s htb rate %skbit ceil %skbit prio %s quantum %s burst %s cburst %s\n' \
				"$dev" "$par" "$cid" "$r" "$c" "$p" "$cq" "$cb" "$cc"
		done
	} | _tc_tree "$dev" || return 1

	setup_hfsc_game_q "$dev" "$gr" "1:10" || err "gaming qdisc ($HFSC_GAMEQ) failed on $dev 1:10 - using the kernel default"
	local lfail=0
	for c in 13 11 12 14 15; do setup_default_leaf "$dev" "1:$c" "$rate" || lfail=$((lfail + 1)); done
	[ "$lfail" = 0 ] || err "$lfail default leaf(es) unmanaged on $dev"
	if [ "$dev" = "$IFB" ]; then add_ifb_filters "$dev" || return 1
	else add_dscp_filters "$dev" || return 1; fi
}

################################################################################
### CAKE                                                                     ###
################################################################################
# Host isolation names the LOCAL end of a flow: egress (WAN, LAN -> WAN) =
# dual-srchost, ingress (IFB, WAN -> LAN) = dual-dsthost. Swapped, it loads
# fine but shares bandwidth between remote hosts. triple-isolate does both.
# Results in $_CV (no forks).
cake_isolation() {
	[ "$CAKE_HOSTISO" = "no" ] && { _CV="triple-isolate"; return 0; }
	if [ "$1" = "egress" ]; then _CV="dual-srchost"; else _CV="dual-dsthost"; fi
	return 0
}
cake_nat() { if [ "$1" = "yes" ]; then _CV="nat"; else _CV="nonat"; fi; return 0; }
cake_wash() {
	if [ "$1" = "egress" ]; then
		if [ "$WASH_UP" = "yes" ]; then _CV="wash"; else _CV="nowash"; fi
	else
		if [ "$WASH_DOWN" = "yes" ]; then _CV="wash"; else _CV="nowash"; fi
	fi
	return 0
}

# Online CPUs, into $_NCPU: the online list (0-3, 0,2-3), else the
# processor lines, else 1.
_ncpu() {
	_NCPU=$(awk -F, '{ for (i = 1; i <= NF; i++) { split($i, r, "-"); n += (r[2] == "" ? 1 : r[2] - r[1] + 1) } }
		END { print n + 0 }' /sys/devices/system/cpu/online 2>/dev/null)
	_isnum "$_NCPU" && [ "$_NCPU" -gt 0 ] || _NCPU=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
	_isnum "$_NCPU" && [ "$_NCPU" -gt 0 ] || _NCPU=1
	return 0
}

setup_cake_dev() {
	local dir="$1" dev="$2" rate="$3" nat="$4" extra="$5"
	local iso wsh nt _e
	cake_isolation "$dir"; iso="$_CV"
	cake_wash "$dir";      wsh="$_CV"
	cake_nat "$nat";       nt="$_CV"
	local opts="bandwidth ${rate}kbit $CAKE_PRIO $iso $nt $wsh split-gso"
	opts="$opts overhead $OVERHEAD"
	[ "$LINKLAYER" = atm ] && opts="$opts atm"
	[ -n "$MPU" ] && opts="$opts mpu $MPU"
	[ -n "$RTT" ] && opts="$opts rtt $RTT"
	if [ "$dir" = "egress" ]; then
		[ "$ACK_ON" = "yes" ] && opts="$opts ack-filter" || opts="$opts no-ack-filter"
	fi
	[ "$dir" = "ingress" ] && [ "$CAKE_ING_MODE" = "yes" ] && opts="$opts ingress"

	# $opts / $extra are split on purpose; set -f stops extra_egress='*'
	# globbing the CWD.
	local _had_f _m
	case "$-" in *f*) _had_f=1 ;; *) _had_f=0 ;; esac
	set -f
	# shellcheck disable=SC2086  # deliberate word lists
	_m=$(tc qdisc add dev "$dev" root cake $opts $extra 2>&1); _e=$?
	# A word tc rejects in extra_* must not leave the line unshaped.
	if [ "$_e" != 0 ] && [ -n "$extra" ]; then
		err "cake extra options '$extra' rejected on $dev: ${_m:-no error text} - applied without them"
		# shellcheck disable=SC2086
		tc qdisc add dev "$dev" root cake $opts; _e=$?
	fi
	[ "$_had_f" = 1 ] || set +f
	return $_e
}

setup_cake() {
	# Coexistence check before the deletes. Shaped directions only.
	local _d _devs="" _nat="$CAKE_NAT_ING"
	[ "$SHAPE_UP" = 1 ] && _devs="$WAN"
	[ "$SHAPE_DN" = 1 ] && _devs="$_devs $IFB"
	for _d in $_devs; do _foreign_root "$_d" || return 1; done
	_QOS_EX_TOUCH_ROOT="$_QOS_EX_TOUCH_ROOT $_devs"
	for _d in $_devs; do tc qdisc del dev "$_d" root 2>/dev/null; done
	if [ "$SHAPE_UP" = 1 ]; then
		setup_cake_dev egress  "$WAN" "$UPLOAD_KBPS"   "$CAKE_NAT_EGR" "$CAKE_EXTRA_E" || return 1
	fi
	if [ "$SHAPE_DN" = 1 ]; then
		# On the LAN device NAT is already undone: a NAT lookup there finds
		# each connection's WAN side and puts every IPv4 device in one host.
		[ "$DL_LAN" = 1 ] && _nat=no
		setup_cake_dev ingress "$IFB" "$DOWNLOAD_KBPS" "$_nat" "$CAKE_EXTRA_I" || return 1
	fi
	return 0
}

################################################################################
### NFT HELPERS — shared rule blocks                                         ###
################################################################################

# @priomap: codepoint -> classid, from DSCP_SPEC.
nft_dscp_map() {
	local s n cp e=""
	for s in $DSCP_SPEC; do
		n=${s%%:*}; cp=${s#*:}
		e="${e:+$e, }$n : 1:${cp#*:}"
	done
	printf '\tmap priomap { type dscp : classid ; elements = { %s } }\n' "$e"
}

# set_<name> per DSCP_SPEC mark (LE, written 0x01, is set_le).
nft_dscp_setters() {
	local s n c
	for s in $DSCP_SPEC; do
		n=${s%%:*}; c=$n
		[ "$n" = 0x01 ] && c=le
		printf '\tchain set_%-4s { ip dscp set %-4s counter; ip6 dscp set %-4s counter; return; }\n' "$c" "$n" "$n"
	done
}

# ACK thinning (HFSC/HTB; CAKE uses its ack-filter keyword). Pure ACKs only:
# a per-connection bucket per tier; `limit rate over` matches the excess, and
# the drop chain passes a fixed fraction of it. Tiers are tested in order.
#   xfast  ACKRATE*100  pass 0.5%  (drop995)
#   fast   ACKRATE*10   pass 5%    (drop95)
#   slow   ACKRATE      pass 25%   (drop75)
# The chain name is the DROP rate (`numgen ... ge N return; drop`). MED_ACK
# is computed for status only. Pure ACKs only: `tcp flags & (fin|syn|rst|psh|
# ack) == ack` (a bare `tcp flags ack` also catches FIN|ACK, RST|ACK and data
# with PSH), and no payload: the IP length is exactly the headers (tcp doff
# x 4, plus 20 for IPv4), so a small data segment is never thinned.
nft_ack_sets() {
	cat <<'EOF'
	set xfst4ack { typeof ct id . ct direction; flags dynamic; timeout 1m; size 65535; }
	set fast4ack { typeof ct id . ct direction; flags dynamic; timeout 1m; size 65535; }
	set slow4ack { typeof ct id . ct direction; flags dynamic; timeout 1m; size 65535; }
EOF
}
nft_ack_drop_chains() {
	cat <<'EOF'
	chain drop995 { numgen random mod 1000 ge 995 return; drop; }
	chain drop95  { numgen random mod 1000 ge 950 return; drop; }
	chain drop75  { numgen random mod 1000 ge 750 return; drop; }
EOF
}

_ack_nft_active()   { [ "$ACK_ON" = "yes" ] && [ "$QDISC" != "cake" ]; }
nft_ack_sets_inv()  { _ack_nft_active && nft_ack_sets; }
nft_ack_drop_inv()  { _ack_nft_active && nft_ack_drop_chains; }

# Gated on WAN egress: routed LAN-to-LAN ACKs are not the uplink's to thin.
# The length sets pair each TCP header length with the IP length a segment
# without payload has (IPv6: the payload length field; no extension headers).
nft_ack_jump() {
	_ack_nft_active || return 0
	cat <<'EOF'
		oifname $WAN meta l4proto tcp tcp flags & (fin|syn|rst|psh|ack) == ack meta length <= 84 tcp doff . ip length { 5 . 40, 6 . 44, 7 . 48, 8 . 52, 9 . 56, 10 . 60, 11 . 64, 12 . 68, 13 . 72, 14 . 76, 15 . 80 } jump ack_rules
		oifname $WAN meta l4proto tcp tcp flags & (fin|syn|rst|psh|ack) == ack meta length <= 84 tcp doff . ip6 length { 5 . 20, 6 . 24, 7 . 28, 8 . 32, 9 . 36, 10 . 40, 11 . 44 } jump ack_rules
EOF
}
nft_ack_chain_inv() {
	_ack_nft_active || return 0
	cat <<EOF
	chain ack_rules {
		add @xfst4ack { ct id . ct direction limit rate over ${XFAST_ACK}/second } counter jump drop995
		add @fast4ack { ct id . ct direction limit rate over ${FAST_ACK}/second } counter jump drop95
		add @slow4ack { ct id . ct direction limit rate over ${SLOW_ACK}/second } counter jump drop75
		return
	}
EOF
}

nft_proto_sets() {
	# $1 = udp_meter + udp_fast (udp_rate on), $2 = slowtcp + tcp_fast
	# (tcp_upgrade on): each set only when the rules that read it are emitted.
	# The meters judge the connection; the *_fast sets hold the verdict, so a
	# connection keeps one class instead of splitting packet by packet.
	[ "$1" = "yes" ] && cat <<'EOF'
	set udp_meter { typeof ct id . ct direction; flags dynamic; timeout 10s; size 65535; }
	set udp_fast  { typeof ct id; flags dynamic,timeout; timeout 5s; size 65535; }
EOF
	[ "$2" = "yes" ] && cat <<'EOF'
	set slowtcp   { typeof ct id . ct direction; flags dynamic; timeout 10s; size 65535; }
	set tcp_fast  { typeof ct id; flags dynamic,timeout; timeout 30s; size 65535; }
EOF
	return 0
}

# `< cs4` (as mark_10s): EF, CS5, CS4, AF41 and AF42 are never demoted; LE and
# CS1 are excluded by name.
nft_tcp_mark_500ms() {
	[ "$1" = "yes" ] || return 0
	cat <<'EOF'
	chain mark_500ms {
		ip  dscp < cs4 ip  dscp != { 0x01, cs1 } counter jump set_af11
		ip6 dscp < cs4 ip6 dscp != { 0x01, cs1 } counter jump set_af11
		return
	}
EOF
}

nft_tcp_mark_10s() {
	[ "$1" = "yes" ] || return 0
	# SIMPLE ONLY: past first10s -> LE, same `< cs4` guard.
	cat <<'EOF'
	chain mark_10s {
		ip  dscp < cs4 counter jump set_le
		ip6 dscp < cs4 counter jump set_le
		return
	}
EOF
}

nft_tcp_500ms()   {
	[ "$1" = "yes" ] || return 0
	local pfx="$2"
	echo "		${pfx}meta l4proto tcp ct bytes < \$first500ms counter jump mark_500ms"
}
nft_tcp_10s()     {
	[ "$1" = "yes" ] || return 0
	local pfx="$2"
	echo "		${pfx}meta l4proto tcp ct bytes > \$first10s counter jump mark_10s"
}
# SIMPLE ONLY. Per connection: one under SLOW_FLOW_PPS -> AF41, unless
# already LE, CS1 or AF11 (bulk, low priority, new-TCP window). Once over the
# rate it stays where it is for 30 s (tcp_fast): a per-packet split moved a
# busy connection's packets, and its connmark, between AF41 and CS0.
nft_tcp_upgrade() {
	[ "$1" = "yes" ] || return 0
	cat <<EOF
		meta l4proto tcp update @slowtcp { ct id . ct direction limit rate over ${SLOW_FLOW_PPS}/second burst ${SLOW_FLOW_PPS} packets } update @tcp_fast { ct id }
		ip  dscp != { 0x01, cs1, af11 } meta l4proto tcp ct id != @tcp_fast counter jump set_af41
		ip6 dscp != { 0x01, cs1, af11 } meta l4proto tcp ct id != @tcp_fast counter jump set_af41
EOF
}

# $1 = TCP_BULK, $2 = UDP_BULK. Each half only when its list has entries: no
# rule may use a define that was not emitted, and nft rejects `{ }`.
nft_bulk_port_rules() {
	[ -n "$2" ] && cat <<'EOF'
		meta l4proto udp th sport $udpbulkpt counter jump set_le
		meta l4proto udp th dport $udpbulkpt counter jump set_le
EOF
	[ -n "$1" ] && cat <<'EOF'
		meta l4proto tcp th sport $tcpbulkpt counter jump set_le
		meta l4proto tcp th dport $tcpbulkpt counter jump set_le
EOF
	return 0
}

# $1 = VIDCONF_PORTS; empty = off. Call UDP is CS4 (Voice, 1:11), but AF41
# under CAKE: there CS4 shares the Voice tin with the game, and a call over
# the tin's quarter of the rate makes the game wait for the tin's turn.
nft_vidconf_rules() {
	[ -n "$1" ] || return 0
	local v=cs4
	[ "$QDISC" = cake ] && v=af41
	printf '\t\tmeta l4proto udp th dport $vidconfports counter jump set_%s\n' "$v"
	printf '\t\tmeta l4proto tcp th dport $vidconfports counter jump set_af41\n'
}

# SIMPLE ONLY. WAN ingress is accepted earlier, so saddr is the LAN device;
# the daddr halves match routed LAN-to-LAN traffic towards it.
nft_gaming_ip_rules() {
	[ -n "$1" ] && cat <<'EOF'
		ip saddr $gamingip_v4 udp dport != $http_ports counter jump set_ef
		ip daddr $gamingip_v4 udp sport != $http_ports counter jump set_ef
EOF
	[ -n "$2" ] && cat <<'EOF'
		ip6 saddr $gamingip_v6 udp dport != $http_ports counter jump set_ef
		ip6 daddr $gamingip_v6 udp sport != $http_ports counter jump set_ef
EOF
	[ -n "$3" ] && cat <<'EOF'
		ether saddr $gamingmac udp dport != $http_ports counter jump set_ef
EOF
	return 0
}

# SIMPLE ONLY (Advanced: nft_adv_lowprio).
nft_lowprio_ip_rules() {
	# $3 = per-rule prefix ('meta l4proto udp ' in Simple's flat chain).
	local pfx="$3"
	[ -n "$1" ] && cat <<EOF
		${pfx}ip saddr \$lowpriolan4 counter jump set_cs1
		${pfx}ip daddr \$lowpriolan4 counter jump set_cs1
EOF
	[ -n "$2" ] && cat <<EOF
		${pfx}ip6 saddr \$lowpriolan6 counter jump set_cs1
		${pfx}ip6 daddr \$lowpriolan6 counter jump set_cs1
EOF
	[ -n "$4" ] && cat <<EOF
		${pfx}ether saddr \$lowpriomac counter jump set_cs1
EOF
	return 0
}

# SIMPLE ONLY. Per connection: UDP over UDP_FAST_PPS -> AF11 for as long as
# it stays over and 5 s after (udp_fast), unless EF, LE, CS1 or AF11
# already. Burst UDP_FAST_BURST: nft's default of 5 split a flow near the
# rate between two classes.
nft_udp_rate_rules() {
	local pfx="$1"
	cat <<EOF
		${pfx}meta l4proto udp update @udp_meter { ct id . ct direction limit rate over ${UDP_FAST_PPS}/second burst ${UDP_FAST_BURST} packets } update @udp_fast { ct id }
		${pfx}ip  dscp != { ef, 0x01, cs1, af11 } meta l4proto udp ct id @udp_fast counter jump set_af11
		${pfx}ip6 dscp != { ef, 0x01, cs1, af11 } meta l4proto udp ct id @udp_fast counter jump set_af11
EOF
}

# DSCP -> connmark as constants, all 64 codepoints: $1 = map name, $2 = the
# bits ORed in. `ct mark set ip dscp or 128` widened the one-byte DSCP into
# the 32-bit mark in host byte order, so on a big-endian router (ath79,
# lantiq) the DSCP landed in the top byte and ctinfo restored CS0 for every
# download. A map's values are stored as marks, the right way round on any
# CPU. Decimal, so no fork per element.
nft_dscp_mark_map() {
	local i=0 e=""
	while [ "$i" -lt 64 ]; do
		e="${e:+$e, }$i : $((i | $2))"
		i=$((i + 1))
	done
	printf '\tmap %s { type dscp : mark; elements = { %s } }\n' "$1" "$e"
}

# Classify: final codepoint -> HFSC/HTB leaf via @priomap (skb->priority),
# and DSCP | 0x80 into the connmark for the download's ctinfo (_ctinfo_act).
# The ct mark write replaces the whole mark (_ctmark_users warns).
nft_classify_chains() {
	printf '\tchain classify {\n'
	# skb->priority only for an HFSC/HTB root on a shaped WAN, and only on
	# the way out of it: elsewhere it would steer pfifo_fast bands or a VLAN
	# egress-qos-map on the LAN side.
	case "$QDISC$SHAPE_UP" in hfsc1|htb1)
		printf '\t\toifname $WAN meta priority set ip dscp map @priomap\n\t\toifname $WAN meta priority set ip6 dscp map @priomap\n' ;;
	esac
	# An ICMP error is RELATED and shares its flow's conntrack entry: writing
	# its DSCP would reset that flow's mark.
	printf '\t\tct state related meta l4proto { icmp, ipv6-icmp } return\n'
	printf '\t\tct mark set ip dscp map @dscpmark\n\t\tct mark set ip6 dscp map @dscpmark\n\t}\n'
}

# The WAN edge of the forward chain:
#   1. Wash (wash_down=yes). HFSC/HTB: jump set_cs0 on every packet (inbound
#      clears whatever DSCP it carries, outbound the LAN-sent one). CAKE: its
#      own ingress `wash`, but CAKE picks the tin before washing, so WAN
#      egress is washed here, before classification re-marks it.
#   2. iifname $WAN accept: inbound is classified by ctinfo on the IFB, so
#      the connmark stays egress-authoritative. LAN<->LAN is classified.
nft_edge_rules() {
	[ "$WASH_DOWN" = "yes" ] && [ "$QDISC" != "cake" ] && printf '\t\tcounter jump set_cs0\n'
	# CAKE with download unshaped has no ingress `wash`, and on the LAN
	# device (download_on lan) its `wash` covers only what leaves through
	# it: the rest (a guest network, another VLAN) is washed here, as in
	# Adaptive's down chain.
	[ "$WASH_DOWN" = "yes" ] && [ "$QDISC" = "cake" ] && [ "$SHAPE_DN" = 0 ] && printf '\t\tiifname $WAN counter jump set_cs0\n'
	[ "$WASH_DOWN" = "yes" ] && [ "$QDISC" = "cake" ] && [ "$SHAPE_DN" = 1 ] && [ "$DL_LAN" = 1 ] && printf '\t\tiifname $WAN oifname != "%s" counter jump set_cs0\n' "$IFB"
	# $1 = Advanced's inbound meter jump, ahead of the accept.
	[ -n "${1:-}" ] && printf '%s\n' "$1"
	printf '\t\tiifname $WAN accept\n'
	[ "$WASH_DOWN" = "yes" ] && [ "$QDISC" = "cake" ] && printf '\t\toifname $WAN counter jump set_cs0\n'
	return 0
}

# Exit wash after classification, HFSC/HTB only (they classify on
# skb->priority). CAKE reads the DSCP at the qdisc after this hook, so it
# uses its own `wash` keyword instead.
nft_wash_up_rule() {
	# Upload unshaped: no egress CAKE, so nft washes.
	[ "$QDISC" = "cake" ] && [ "$SHAPE_UP" = 1 ] && return 0
	[ "$WASH_UP" = "yes" ] && echo "		oifname \$WAN counter jump set_cs0"
	return 0
}

# TCP MSS clamp at the WAN edge. Only ever shrinks (`size > target`): fw4's
# mtu_fix (mangle_forward, -150) may already have set a smaller PMTU value.
# `tcp flags syn` is a bit test, so it catches SYN-ACK too. Emitted BEFORE
# nft_edge_rules (its accept ends the hook for WAN ingress). IPv6 is 20 bytes
# lower (1440 on a 1500 MTU).
nft_mss_clamp_rules() {
	local _u6 _d6
	if [ -n "$MSS_UP" ]; then
		_u6=$((MSS_UP - 20)); [ "$_u6" -lt 536 ] && _u6=536
		printf '\t\tmeta nfproto ipv4 iifname $WAN tcp flags syn tcp option maxseg size > %s counter tcp option maxseg size set %s\n' "$MSS_UP" "$MSS_UP"
		printf '\t\tmeta nfproto ipv6 iifname $WAN tcp flags syn tcp option maxseg size > %s counter tcp option maxseg size set %s\n' "$_u6" "$_u6"
	fi
	if [ -n "$MSS_DN" ]; then
		_d6=$((MSS_DN - 20)); [ "$_d6" -lt 536 ] && _d6=536
		printf '\t\tmeta nfproto ipv4 oifname $WAN tcp flags syn tcp option maxseg size > %s counter tcp option maxseg size set %s\n' "$MSS_DN" "$MSS_DN"
		printf '\t\tmeta nfproto ipv6 oifname $WAN tcp flags syn tcp option maxseg size > %s counter tcp option maxseg size set %s\n' "$_d6" "$_d6"
	fi
	return 0
}

# Pure parameter expansion, no forks.
ipset_fmt() {
	local _o="" _t
	for _t in $1; do _o="${_o:+$_o, }$_t"; done
	echo "$_o"
}

# Gaming / low-priority lists in nft set syntax, into named globals.
_pf_fmt_ipsets() {
	_PF_G4=$(ipset_fmt "$GAMING_IP4");  _PF_G6=$(ipset_fmt "$GAMING_IP6")
	_PF_L4=$(ipset_fmt "$LOWPRIO_IP4"); _PF_L6=$(ipset_fmt "$LOWPRIO_IP6")
	_PF_GM=$(ipset_fmt "$GAMING_MAC");  _PF_LM=$(ipset_fmt "$LOWPRIO_MAC")
}

# Load a generated ruleset ($1.new); on failure, the error and the whole
# ruleset go to $NFT_ERR for the UI. $1 = path, $2 = label. $1 itself is only
# ever the text that last LOADED: a failed one is never moved over it, so it
# cannot later pass for "unchanged". On reload (_NFT_KEEP=1) an identical
# rebuild is not loaded: a load resets flow flags, sticky pairs and counters,
# and the procd trigger fires on any commit.
nft_load_or_log() {
	local _nft="$1" _label="$2" _err _tbl="${1##*/}" _was
	_tbl="${_tbl%.nft}"
	if [ "${_NFT_KEEP:-0}" = 1 ] && cmp -s "$_nft.new" "$_nft" 2>/dev/null && \
	   nft list tables inet 2>/dev/null | grep -qx "table inet $_tbl"; then
		rm -f "$_nft.new"
		msg "NFT $_label unchanged - kept"
		return 0
	fi
	# Data, never executed; holds LAN topology and device addresses: 0600.
	chmod 600 "$_nft.new" 2>/dev/null
	# Dry run first. The file replaces the table atomically (table / delete /
	# table), so a bad ruleset is a logged no-op, never an outage.
	if _err=$(nft -c -f "$_nft.new" 2>&1); then
		if _err=$(nft -f "$_nft.new" 2>&1); then
			mv -f "$_nft.new" "$_nft" || err "nft $_label: could not keep $_nft"
			rm -f "$NFT_ERR"
			msg "NFT $_label loaded"
			return 0
		fi
		_was="failed"
	else
		_was="FAILED VALIDATION"
	fi
	{
		echo "=== NFT $_label $_was at $(date) ==="
		echo "$_err"
		echo ""
		echo "=== Generated ruleset ($_nft.new) ==="
		cat "$_nft.new"
	} > "$NFT_ERR"
	# Contains the ruleset: 0600.
	chmod 600 "$NFT_ERR" 2>/dev/null
	rm -f "$_nft.new"
	if nft list tables inet 2>/dev/null | grep -qx "table inet $_tbl"; then
		err "nft $_label $_was - ruleset NOT applied, the previous $_label rules are still loaded (see $NFT_ERR)"
	else
		err "nft $_label $_was - ruleset NOT applied, no $_label rules are loaded (see $NFT_ERR)"
	fi
	log "nft $_label $_was: $_err"
	return 1
}

################################################################################
### NFT ADVANCED HELPERS — named sets, shared with Adaptive                  ###
###                                                                          ###
### Device, port and meter sets for Advanced and Adaptive. A ct expression   ###
### BREAKS on an untracked packet, which then reaches classify at the DSCP   ###
### it arrived with (fw4 drops invalid at priority 0, right after this       ###
### table). ct bytes / avgpkt read 0 without the conntrack acct extension; ###
### loading such a rule turns acct on, and start() sets nf_conntrack_acct=1  ###
### first. Flow offloading must stay off.                                    ###
################################################################################

# Comma/space list -> nft set elements. Empty in = empty out; callers then skip
# the set (nft rejects `{ }`).
_adv_elems() {
	local _o="" _t _in="$1"
	while :; do
		case "$_in" in
			*,*) _in="${_in%%,*} ${_in#*,}" ;;
			*)   break ;;
		esac
	done
	# shellcheck disable=SC2086  # word splitting is the mechanism here
	for _t in $_in; do _o="${_o:+$_o, }$_t"; done
	echo "$_o"
}

# Port list as a set; flags interval for ranges.

nft_adv_port_set() {
	local e; e=$(_adv_elems "$1")
	[ -n "$e" ] || return 0
	echo "	set $2 { type inet_service; flags interval; elements = { $e } }"
}

# Service map elements (Adaptive) are matched on ct original proto-dst: the
# port the connection was opened to, the same on every packet both ways
# (under DNAT, the external port: the original tuple is recorded before NAT).
# Overlap is fatal (nft "File exists" fails
# the whole table), so each range has the ranges already claimed for its
# protocol subtracted. Prints "#SKIP <reason>" lines, then the element list.
# Overlap-subtracting builder: proto<TAB>list<TAB>verdict lines, earlier wins.
# A verdict written ~name is a built-in list: its overlaps are not reported.
_svc_awk() {
	awk '
	BEGIN { FS = "\t"; cnt = 0; out = "" }
	function emit(proto, lo, hi, verdict,   key) {
		cnt++; kp[cnt] = proto; klo[cnt] = lo; khi[cnt] = hi
		key = (lo == hi) ? sprintf("%d", lo) : sprintf("%d-%d", lo, hi)
		out = out (out == "" ? "" : ", ") proto " . " key " : goto " verdict
	}
	{
		proto = $1; list = $2; verdict = $3
		quiet = (substr(verdict, 1, 1) == "~"); if (quiet) verdict = substr(verdict, 2)
		if (list == "") next
		n = split(list, items, ",")
		for (i = 1; i <= n; i++) {
			it = items[i]; gsub(/[ \t]/, "", it)
			if (it == "") continue
			d = index(it, "-")
			if (d > 0) { lo = substr(it, 1, d - 1) + 0; hi = substr(it, d + 1) + 0 }
			else       { lo = it + 0; hi = lo }
			if (lo < 1 || hi > 65535 || hi < lo) {
				printf "#SKIP %s %s is not a port or range in 1-65535\n", proto, it
				continue
			}
			# same-proto claims overlapping this candidate, ascending by lo.
			# Selection sort: the list is a handful of entries, so an O(n^2)
			# pass costs less than the bookkeeping a real sort would need.
			m = 0
			for (k = 1; k <= cnt; k++)
				if (kp[k] == proto && lo <= khi[k] && hi >= klo[k]) { m++; slo[m] = klo[k]; shi[m] = khi[k] }
			for (a = 1; a < m; a++) {
				b = a
				for (c = a + 1; c <= m; c++) if (slo[c] < slo[b]) b = c
				t = slo[a]; slo[a] = slo[b]; slo[b] = t
				t = shi[a]; shi[a] = shi[b]; shi[b] = t
			}
			cur = lo; kept = 0
			for (a = 1; a <= m; a++) {
				if (shi[a] < cur) continue
				if (slo[a] > hi) break
				if (slo[a] > cur) { emit(proto, cur, slo[a] - 1, verdict); kept++ }
				cur = shi[a] + 1
				if (cur > hi) break
			}
			if (cur <= hi) { emit(proto, cur, hi, verdict); kept++ }
			if (m > 0 && !quiet) {
				if (kept == 0) printf "#SKIP %s %s is already claimed in full by an earlier list\n", proto, it
				else           printf "#SKIP %s %s overlapped an earlier list; kept the unclaimed part\n", proto, it
			}
		}
	}
	END { if (out != "") print out }'
}
# Verdict map: the lists carry different classes.
nft_adv_svc_map() {
	[ -n "$1" ] || return 0
	echo "	map svc { type inet_proto . inet_service : verdict; flags interval; elements = { $1 } }"
}
# Bulk -> LE, video -> CS4 (UDP) / AF41 (TCP). After gaming and low priority.
nft_adv_service() {
	[ -n "$1" ] || return 0
	echo "		meta l4proto . ct original proto-dst vmap @svc"
}

# flags interval for CIDR entries; auto-merge folds a host into a listed
# subnet (else "conflicting intervals" fails the table).
nft_adv_ip_set() {
	local e; e=$(_adv_elems "$2")
	[ -n "$e" ] || return 0
	echo "	set $1 { type $3; flags interval; auto-merge; elements = { $e } }"
}


# ADVANCED: a per-packet rate split, devices first.
#   udp_dev      UDP: gaming EF, low priority CS1 (first match, to_<cp>)
#   http         from a web port CS0; to a web port: small CS0, mid-size
#                AF42, mid-size over web_pps AF11. Web TCP: heavy past
#                first10s / sticky pair LE, slow AF42
#   process_tcp  non-web CS0 packets up to max_len over tcp_pps set the
#   process_udp  scratch meta mark (TCP 30 v4 / 40 v6, UDP 10 / 20); reset_pm
#                per thousand of them drop it again. Marked: TCP CS0, UDP
#                AF41 (small ones only upload); unmarked: TCP AF41, UDP CS5.
#                (TCP over the rate was AF42: the same leaf and CAKE tin as
#                AF41, so the split changed nothing.)
#                The scratch is cleared at chain exit. A packet that
#                arrives with the mark's low byte set (an fw4 set_mark rule)
#                skips the split: the scratch would overwrite that byte.
# The class is per packet: one connection's packets may sit in two classes.
# Dynamic sets (meters fed with `update`, which refreshes their timeout):
#   web_meter / tcp_meter / udp_meter  per connection-direction bucket
#   slowtcp / tcp_fast    web TCP over SLOW_FLOW_PPS (30 s hold)
#   heavytcp / tcp_heavy  web TCP over HEAVY_FLOW_PPS (30 s hold)
# Devices by MAC: $1 = set name, $2 = comma-separated list. Empty = no set.
nft_adv_mac_set() {
	[ -n "$2" ] || return 0
	echo "	set $1 { type ether_addr; elements = { $2 } }"
}

# $1 = tcp_upgrade, $2 = tcp_10s.
nft_adv_dyn_sets() {
	cat <<'EOF'
	set web_meter { typeof ct id . ct direction; flags dynamic; timeout 10s; size 65535; }
	set tcp_meter { typeof ct id . ct direction; flags dynamic; timeout 10s; size 65535; }
	set udp_meter { typeof ct id . ct direction; flags dynamic; timeout 10s; size 65535; }
EOF
	[ "$1" = "yes" ] && cat <<'EOF'
	set slowtcp   { typeof ct id . ct direction; flags dynamic; timeout 10s; size 65535; }
	set tcp_fast  { typeof ct id; flags dynamic,timeout; timeout 30s; size 65535; }
EOF
	[ "$2" = "yes" ] && cat <<'EOF'
	set heavytcp  { typeof ct id . ct direction; flags dynamic; timeout 10s; size 65535; }
	set tcp_heavy { typeof ct id; flags dynamic,timeout; timeout 30s; size 65535; }
EOF
	return 0
}

################################################################################
### BULK SOURCE PAIRS (sticky LE, Advanced and Adaptive)                     ###
################################################################################
# Armed when tcp_10s is on and bulk_timeout != 0. Keyed on the connection's
# original addresses: LAN . remote for one the LAN opened, so a download's
# parallel connections to one host all go LE and the device's other traffic
# is judged on its own; remote . WAN address for one opened from outside (a
# port forward). v4 / v6 split (key types differ).
_bulk_sticky_on() { [ "$1" = "yes" ] && [ "${BULK_TIMEOUT:-0}" != "0" ]; }

nft_bulk_src_sets() {
	_bulk_sticky_on "$1" || return 0
	cat <<EOF
	set bulk_src4 { type ipv4_addr . ipv4_addr; flags dynamic,timeout; timeout ${BULK_TIMEOUT}s; size 4096; }
	set bulk_src6 { type ipv6_addr . ipv6_addr; flags dynamic,timeout; timeout ${BULK_TIMEOUT}s; size 4096; }
EOF
}

# to_<cp> = set_<cp> then `goto done` (first match).
nft_adv_to_chains() {
	local cp
	for cp in ef cs1 le; do
		printf '\tchain to_%s { jump set_%s; goto done; }\n' "$cp" "$cp"
	done
	printf '\tchain done {\n\t\tjump classify\n'
	nft_wash_up_rule
	printf '\t\taccept\n\t}\n'
}

# EF for gaming devices' non-web UDP (saddr = the LAN device on this hook).
nft_adv_gaming() {
	[ -n "$1" ] && echo "		ip  saddr @gaming4 ct original proto-dst != @web_ports goto to_ef"
	[ -n "$2" ] && echo "		ip6 saddr @gaming6 ct original proto-dst != @web_ports goto to_ef"
	[ -n "$3" ] && echo "		ether saddr @gaming_mac ct original proto-dst != @web_ports goto to_ef"
	return 0
}

# CS1 for low-priority devices, UDP only. $3 = MAC list; gaming runs first.
nft_adv_lowprio() {
	[ -n "$1" ] && echo "		ip  saddr @lowprio4 goto to_cs1"
	[ -n "$2" ] && echo "		ip6 saddr @lowprio6 goto to_cs1"
	[ -n "$3" ] && echo "		ether saddr @lowprio_mac goto to_cs1"
	return 0
}

# Web TCP meters. $1 = tcp_upgrade, $2 = tcp_10s, $3 = rule prefix. Inbound
# never reaches the stages (accepted at the edge), so meter_down=yes runs
# them in meter_in ahead of that accept as well.
_ADV_WEB_TCP='meta l4proto tcp ct original proto-dst @web_ports '
nft_adv_tcp_meter() {
	[ "$1" = "yes" ] && echo "		${3}update @slowtcp { ct id . ct direction limit rate over ${SLOW_FLOW_PPS}/second burst ${SLOW_FLOW_PPS} packets } update @tcp_fast { ct id }"
	[ "$2" = "yes" ] && echo "		${3}update @heavytcp { ct id . ct direction limit rate over ${HEAVY_FLOW_PPS}/second burst $((HEAVY_FLOW_PPS * 2)) packets } update @tcp_heavy { ct id }"
	return 0
}

# Web ports, both ways. The AF42 rule takes every mid-size packet and the
# meter rule re-marks the excess over web_pps AF11. Then web TCP: heavy past
# first10s (recording the pair) or a sticky pair -> LE, slow -> AF42.
# $1 = tcp_upgrade, $2 = tcp_10s.
nft_adv_http() {
	local w='meta l4proto { tcp, udp } th dport @web_ports' t="$_ADV_WEB_TCP"
	local mid="$((ADV_SMALL_LEN + 1))-$ADV_MAX_LEN"
	printf '\tchain http {\n'
	cat <<EOF
		meta l4proto { tcp, udp } th sport @web_ports counter jump set_cs0
		$w meta length <= $ADV_SMALL_LEN counter jump set_cs0
		$w meta length $mid counter jump set_af42
		$w meta length $mid update @web_meter { ct id . ct direction limit rate over ${ADV_WEB_PPS}/second } counter jump set_af11
EOF
	nft_adv_tcp_meter "$1" "$2" "$t"
	if [ "$2" = "yes" ]; then
		if _bulk_sticky_on yes; then
			cat <<EOF
		${t}ct bytes > \$first10s ct id @tcp_heavy counter goto tcp_10s
		${t}ip  saddr . ip  daddr @bulk_src4 counter goto to_le
		${t}ip6 saddr . ip6 daddr @bulk_src6 counter goto to_le
EOF
		else
			echo "		${t}ct bytes > \$first10s ct id @tcp_heavy counter goto to_le"
		fi
	fi
	[ "$1" = "yes" ] && echo "		${t}ct id != @tcp_fast counter jump set_af42"
	printf '\t\treturn\n\t}\n'
	[ "$2" = "yes" ] && _bulk_sticky_on yes && cat <<'EOF'
	chain tcp_10s {
		update @bulk_src4 { ip  saddr . ip  daddr }
		update @bulk_src6 { ip6 saddr . ip6 daddr }
		goto to_le
	}
EOF
	return 0
}

# Everything not on a web port. $1 = tcp|udp, $2 / $3 = v4 / v6 scratch,
# $4 = rate, $5 = marked class, $6 = unmarked class. The family test comes
# before the meter, so one packet feeds one rule's bucket.
nft_adv_process() {
	local n='th dport != @web_ports th sport != @web_ports'
	cat <<EOF
	chain process_$1 {
		meta mark and 0xff != 0 return
		meta l4proto $1 $n meta length <= $ADV_MAX_LEN ip  dscp cs0 update @$1_meter { ct id . ct direction limit rate over $4/second } counter meta mark set meta mark and 0xffffff00 or $2
		meta l4proto $1 $n meta length <= $ADV_MAX_LEN ip6 dscp cs0 update @$1_meter { ct id . ct direction limit rate over $4/second } counter meta mark set meta mark and 0xffffff00 or $3
EOF
	[ "$ADV_RESET_PM" != 0 ] && cat <<EOF
		meta l4proto $1 numgen random mod 1000 < $ADV_RESET_PM meta mark and 0xff == $2 counter meta mark set meta mark and 0xffffff00
		meta l4proto $1 numgen random mod 1000 < $ADV_RESET_PM meta mark and 0xff == $3 counter meta mark set meta mark and 0xffffff00
EOF
	cat <<EOF
		meta l4proto $1 meta length <= $ADV_SMALL_LEN oifname \$WAN meta mark and 0xff { $2, $3 } counter jump set_$5
		meta l4proto $1 meta length > $ADV_SMALL_LEN meta mark and 0xff { $2, $3 } counter jump set_$5
		meta l4proto $1 $n meta mark and 0xff != $2 meta length <= $ADV_MAX_LEN ip  dscp cs0 counter jump set_$6
		meta l4proto $1 $n meta mark and 0xff != $3 meta length <= $ADV_MAX_LEN ip6 dscp cs0 counter jump set_$6
		meta mark set meta mark and 0xffffff00
		return
	}
EOF
}

# LAN-sent DSCP is trusted only with wash_down off: non-cs0 skips the stages.
nft_adv_trust() {
	[ "$WASH_DOWN" = "yes" ] && return 0
	printf '\t\tip  dscp != cs0 goto done\n\t\tip6 dscp != cs0 goto done\n'
}

# A rule block as a named chain, or nothing when it is empty.
nft_adv_chain() {
	[ -n "$2" ] || return 0
	printf '\tchain %s {\n%s\n\t}\n' "$1" "$2"
}

# Forward jump to a stage, only when it exists. $3 = gate.
nft_adv_jump() {
	[ -n "$2" ] || return 0
	printf '\t\t%sjump %s\n' "${3:+$3 }" "$1"
}

################################################################################
### NFT SIMPLE (SGS)                                                         ###
###                                                                          ###
### Forward chain order: mss clamp; edge (wash, iifname WAN accept); ACK     ###
### thinning (HFSC/HTB); bulk ports; video-call ports; gaming; low priority; ###
### UDP rate; TCP 500ms / 10s / upgrade; classify; exit wash.               ###
################################################################################
setup_nft_simple() {
	local nft="$NFT_DIR/$NFT_SIMPLE.nft"
	local g4 g6 l4 l6
	_pf_fmt_ipsets
	g4="$_PF_G4"; g6="$_PF_G6"; l4="$_PF_L4"; l6="$_PF_L6"

	local r_bulkp=""    && [ "$SIM_BULK_PORTS" = "yes" ] && r_bulkp=$(nft_bulk_port_rules "$TCP_BULK" "$UDP_BULK")
	local r_vid=""      && [ "$SIM_VIDCONF"    = "yes" ] && r_vid=$(nft_vidconf_rules "$VIDCONF_PORTS")
	local r_gip=""      && [ "$SIM_GAMING_IP"  = "yes" ] && r_gip=$(nft_gaming_ip_rules "$g4" "$g6" "$_PF_GM")
	local r_lip=""      && [ "$SIM_LOWPRIO_IP" = "yes" ] && r_lip=$(nft_lowprio_ip_rules "$l4" "$l6" 'meta l4proto udp ' "$_PF_LM")
	local r_udpr=""     && [ "$SIM_UDP_RATE"   = "yes" ] && r_udpr=$(nft_udp_rate_rules '')
	local r_tcp_500
	r_tcp_500=$(nft_tcp_500ms   "$SIM_TCP_500MS")
	local r_tcp_upg
	r_tcp_upg=$(nft_tcp_upgrade "$SIM_TCP_UPGRADE")
	# One bulk trigger: past first10s -> LE. No sticky pairs (Advanced only).
	local r_tcp_10s
	r_tcp_10s=$(nft_tcp_10s     "$SIM_TCP_10S")

	# No delete first: the ruleset replaces the table in one transaction.
	mkdir -p "$NFT_DIR"; chmod 700 "$NFT_DIR" 2>/dev/null
	cat > "$nft.new" <<EOF
#!/usr/sbin/nft -f
# Auto-generated by $SCRIPT_NAME v$VERSION — simple mode
table inet $NFT_SIMPLE
delete table inet $NFT_SIMPLE

table inet $NFT_SIMPLE {
	# ----- constants -----
	define http_ports   = { $HTTP_PORTS }
	define first500ms   = $FIRST_500MS
	define first10s     = $FIRST_10S
	define WAN          = "$WAN"
$([ -n "$r_bulkp" ] && [ -n "$TCP_BULK" ]      && echo "	define tcpbulkpt    = { $TCP_BULK }")
$([ -n "$r_bulkp" ] && [ -n "$UDP_BULK" ]      && echo "	define udpbulkpt    = { $UDP_BULK }")
$([ -n "$r_vid" ]   && echo "	define vidconfports = { $VIDCONF_PORTS }")
$([ -n "$g4" ] && echo "	define gamingip_v4  = { $g4 }")
$([ -n "$g6" ] && echo "	define gamingip_v6  = { $g6 }")
$([ -n "$_PF_GM" ] && echo "	define gamingmac    = { $_PF_GM }")
$([ -n "$l4" ] && echo "	define lowpriolan4  = { $l4 }")
$([ -n "$l6" ] && echo "	define lowpriolan6  = { $l6 }")
$([ -n "$_PF_LM" ] && echo "	define lowpriomac   = { $_PF_LM }")

$(nft_dscp_map)
$(nft_dscp_mark_map dscpmark 128)

	# ----- dynamic sets -----
$(nft_proto_sets "$SIM_UDP_RATE" "$SIM_TCP_UPGRADE")
$(nft_ack_sets_inv)

	# ----- forward chain (order per spec) -----
	# priority -1: run just before fw4's filter forward (0) so classification
	# marks are written deterministically ahead of fw4's verdicts — matches
	# the advanced builder (S7, 1.3.8).
	chain forward {
		type filter hook forward priority -1; policy accept;
$(nft_mss_clamp_rules)
$(nft_edge_rules)
$(nft_ack_jump)

$r_bulkp
$r_vid
$r_gip
$r_lip
$r_udpr

		# Flow rules last, and in this order. 500ms and 10s are mutually
		# exclusive (first500ms is always the smaller bound). The upgrade
		# leaves le, cs1 and af11 alone, so it cannot undo the bulk demote and
		# does not lift a connection still inside the new-TCP window.
$r_tcp_500
$r_tcp_10s
$r_tcp_upg

		jump classify
$(nft_wash_up_rule)
	}


$(nft_classify_chains)

$(nft_ack_chain_inv)

	# ----- TCP flow action chains (only when toggle is on) -----
$(nft_tcp_mark_500ms "$SIM_TCP_500MS")
$(nft_tcp_mark_10s   "$SIM_TCP_10S")

	# ----- DSCP setters + ACK drop chains -----
$(nft_dscp_setters)
$(nft_ack_drop_inv)
}
EOF
	nft_load_or_log "$nft" "Simple"
}

################################################################################
### NFT ADVANCED — per-packet rate split, flat chains                        ###
###                                                                          ###
###   forward  -> event mask (no mark events), mss clamp, wash, meter_in     ###
###               + WAN ingress accept, ACK thinning, udp_dev, trust gate,   ###
###               http, process_tcp / process_udp, done                      ###
###   done     -> classify (priomap, DSCP | 0x80 into the connmark),         ###
###               exit wash, accept                                          ###
### Only WAN ingress skips the rules: routed LAN-to-LAN is classified too,   ###
### so ACK thinning is gated on the WAN in nft_ack_jump.                     ###
################################################################################
setup_nft_advanced() {
	local nft="$NFT_DIR/$NFT_ADVANCED.nft"
	local r_dev="" s_dev="" r_min=""
	_pf_fmt_ipsets

	if [ "$ADV_GAMING_IP" = "yes" ]; then
		s_dev="$(nft_adv_ip_set gaming4 "$_PF_G4" ipv4_addr)
$(nft_adv_ip_set gaming6 "$_PF_G6" ipv6_addr)
$(nft_adv_mac_set gaming_mac "$_PF_GM")"
		r_dev=$(nft_adv_gaming "$_PF_G4" "$_PF_G6" "$_PF_GM")
	fi
	if [ "$ADV_LOWPRIO_IP" = "yes" ]; then
		s_dev="$s_dev
$(nft_adv_ip_set lowprio4 "$_PF_L4" ipv4_addr)
$(nft_adv_ip_set lowprio6 "$_PF_L6" ipv6_addr)
$(nft_adv_mac_set lowprio_mac "$_PF_LM")"
		r_dev="$r_dev
$(nft_adv_lowprio "$_PF_L4" "$_PF_L6" "$_PF_LM")"
	fi
	r_dev=$(printf '%s\n' "$r_dev" | grep -v '^[[:space:]]*$')
	[ "$ADV_METER_DOWN" = "yes" ] && r_min=$(nft_adv_tcp_meter "$ADV_TCP_UPGRADE" "$ADV_TCP_10S" "$_ADV_WEB_TCP")

	mkdir -p "$NFT_DIR"; chmod 700 "$NFT_DIR" 2>/dev/null
	cat > "$nft.new" <<EOF
#!/usr/sbin/nft -f
# Auto-generated by $SCRIPT_NAME v$VERSION — advanced mode
table inet $NFT_ADVANCED
delete table inet $NFT_ADVANCED

table inet $NFT_ADVANCED {
	# ----- constants -----
	define first10s = $FIRST_10S
	define WAN      = "$WAN"

$(nft_dscp_map)
$(nft_dscp_mark_map dscpmark 128)

	# ----- lookup sets -----
$(nft_adv_port_set "$HTTP_PORTS" web_ports)
$(echo "$s_dev" | grep -v '^[[:space:]]*$')

	# ----- dynamic sets -----
$(nft_adv_dyn_sets "$ADV_TCP_UPGRADE" "$ADV_TCP_10S")
$(nft_bulk_src_sets "$ADV_TCP_10S")
$(nft_ack_sets_inv)

	# ----- forward chain (priority -1: after fw4 mangle_forward at -150,
	# before fw4 filter forward at 0) -----
	chain forward {
		type filter hook forward priority -1; policy accept;
		# The connmark follows each packet, so it changes often: keep mark
		# changes out of conntrack's events (the Ping Filter listens to them).
		ct event set new,related,destroy,reply,assured,protoinfo
$(nft_mss_clamp_rules)
$(nft_edge_rules "$(nft_adv_jump meter_in "$r_min" 'iifname $WAN')")
$(nft_ack_jump)
$(nft_adv_jump udp_dev "$r_dev" 'meta l4proto udp')
$(nft_adv_trust)
		meta l4proto { tcp, udp } jump http
		meta l4proto tcp jump process_tcp
		meta l4proto udp jump process_udp
		goto done
	}

$(nft_ack_chain_inv)

$(nft_adv_chain meter_in "$r_min")
$(nft_adv_chain udp_dev "$r_dev")
$(nft_adv_http "$ADV_TCP_UPGRADE" "$ADV_TCP_10S")
$(nft_adv_process tcp 30 40 "$ADV_TCP_PPS" cs0 af41)
$(nft_adv_process udp 10 20 "$ADV_UDP_PPS" af41 cs5)

$(nft_adv_to_chains)

$(nft_classify_chains)

	# ----- DSCP setters + ACK drop chains -----
$(nft_dscp_setters)
$(nft_ack_drop_inv)
}
EOF
	nft_load_or_log "$nft" "Advanced"
}

################################################################################
### NFT ADAPTIVE — decide once, adapt the unlisted                           ###
###                                                                          ###
### The connmark is the source of truth. A connection's first upload packet ###
### runs `decide`: listed traffic (gaming / low-priority devices, bulk /     ###
### video-call / VPN / DNS ports, ping) is STATIC for life; the rest is AUTO ###
### and moves between Interactive (AF42 TCP, CS5 small UDP), Default, Low    ###
### (AF11 busy UDP) and Bulk (LE) by per-connection flags. Every upload      ###
### packet replays the mark into DSCP (and skb->priority under HFSC/HTB).    ###
###   connmark  bits 0-5 DSCP  0x80 decided (ctinfo statemask)               ###
###             0x100 STATIC  0x200 GUARD (gaming UDP)  0x400 VGUARD (video- ###
###             call UDP)  0xf000 generation                                 ###
### The generation is a hash of the ruleset text: an identical rebuild keeps ###
### the table, a changed one makes live connections decide again (never the ###
### generation already loaded: see setup_nft_adaptive).                      ###
################################################################################
# P2P = a device opening unlisted non-web connections faster than p2p_rate a
# minute. A rate, not `ct count` (no nft_connlimit on OpenWrt). 0 = off.
_ada_p2p_ok() { [ "${ADA_P2P_RATE:-0}" != 0 ]; }

# Heavy = heavy_pct of the direction's shaped rate in bytes/s (unshaped = 1
# Gbit). $1 = kbit, $2 = shaped. The direction is the packet's way through
# the WAN (out = upload), not ct direction: a port-forwarded server's upload
# is its connection's reply direction. Two meters at that rate: one per
# connection, and one per LAN device (upload by ip saddr, download by ip
# daddr, after DNAT) over all its unlisted traffic. A device over it moves
# its busy connections (@fast) to Bulk, so a download split over many
# connections is caught; its slow ones stay where they are.
_ada_heavy() {
	local k="$1"
	[ "$2" = 1 ] && [ "${k:-0}" -gt 0 ] 2>/dev/null || k=1000000
	_AH=$(( k * 125 * ADA_HEAVY_PCT / 100 ))
	[ "$_AH" -lt 12500 ] && _AH=12500
	_AB=$(( _AH * ADA_HEAVY_SECS ))
	[ "$_AB" -gt 4000000000 ] && _AB=4000000000
	return 0
}

_nft_adaptive_body() {
	local G=$(( $1 << 12 ))
	local DEC STC EF CS5 CALL AF41 LOW BULK VPN TCPA VC=32 GB GBB
	# Call UDP: CS4, AF41 under CAKE (see nft_vidconf_rules).
	[ "$QDISC" = cake ] && VC=34
	DEC=$(printf '0x%x' $((G | 0x80)));   TCPA=$(printf '0x%x' $((G | 0x80 | 36)))
	EF=$(printf '0x%x' $((G | 0x380 | 46)));  CS5=$(printf '0x%x' $((G | 0x180 | 40)))
	CALL=$(printf '0x%x' $((G | 0x580 | VC))); AF41=$(printf '0x%x' $((G | 0x180 | 34)))
	LOW=$(printf '0x%x' $((G | 0x180 | 8)));  BULK=$(printf '0x%x' $((G | 0x180 | 1)))
	VPN=$(printf '0x%x' $((G | 0x180)));      STC=$(printf '0x%x' $((G | 0x180)))
	_ada_heavy "$UPLOAD_KBPS" "$SHAPE_UP";   local hu=$_AH hub=$_AB
	_ada_heavy "$DOWNLOAD_KBPS" "$SHAPE_DN"; local hd=$_AH hdb=$_AB
	# The guard's byte rate: udp_fast_pps x packet_size a second, what 1:10
	# is sized for (_game_rate). nft's byte bucket holds a second of the rate
	# plus the burst (udp_fast_burst x packet_size): a stream at twice the
	# rate keeps EF about 1.5 s.
	GB=$((UDP_FAST_PPS * HFSC_PKTSZ)); GBB=$((UDP_FAST_BURST * HFSC_PKTSZ))
	[ "$GBB" -gt 4000000000 ] && GBB=4000000000
	cat <<EOF
#!/usr/sbin/nft -f
# Auto-generated by $SCRIPT_NAME v$VERSION — adaptive mode, generation $1
table inet $NFT_ADAPTIVE
delete table inet $NFT_ADAPTIVE

table inet $NFT_ADAPTIVE {
	define WAN = "$WAN"

	# ----- lookup sets -----
$(nft_adv_port_set "$HTTP_PORTS" web_ports)
$(nft_adv_svc_map "$_ADA_SVC")
$([ -n "$_ADA_SVC_SRC" ] && printf '\tmap svc_src { type inet_proto . inet_service : verdict; flags interval; elements = { %s } }\n' "$_ADA_SVC_SRC")
$(echo "$_ADA_SETS" | grep -v '^[[:space:]]*$')
$([ "$WASH_DOWN" = yes ] || nft_dscp_mark_map dscpstc $((STC)))

	# ----- replay: connmark DSCP bits -> packet DSCP / HFSC-HTB leaf -----
	map dscp_of { type mark : verdict; elements = { $_ADA_DSCP } }
	map leaf_of { type mark : classid; elements = { $_ADA_LEAF } }

	# ----- per-connection state (AUTO and guarded connections only) -----
	set flow_meter { typeof ct id . ct direction; flags dynamic; timeout 10s; size 65535; }
	set fast       { typeof ct id; flags dynamic,timeout; timeout 30s; size 65535; }
	set udp_fast   { typeof ct id; flags dynamic,timeout; timeout 5s; size 65535; }
	set guard_bytes { typeof ct id . ct direction; flags dynamic; timeout 10s; size 65535; }
	set byte_meter { typeof ct id . ct direction; flags dynamic; timeout 20s; size 65535; }
	set heavy      { typeof ct id; flags dynamic,timeout; timeout 30s; size 65535; }
	set dev_up4    { type ipv4_addr; flags dynamic; timeout 20s; size 1024; }
	set dev_dn4    { type ipv4_addr; flags dynamic; timeout 20s; size 1024; }
	set dev_up6    { type ipv6_addr; flags dynamic; timeout 20s; size 1024; }
	set dev_dn6    { type ipv6_addr; flags dynamic; timeout 20s; size 1024; }
$(nft_bulk_src_sets yes)
$([ -n "$_ADA_P2P" ] && cat <<P2P
	set new_conn4  { type ipv4_addr; flags dynamic,timeout; timeout 2m; size 4096; }
	set new_conn6  { type ipv6_addr; flags dynamic,timeout; timeout 2m; size 4096; }
	set p2p4       { type ipv4_addr; flags dynamic,timeout; timeout 5m; size 1024; }
	set p2p6       { type ipv6_addr; flags dynamic,timeout; timeout 5m; size 1024; }
P2P
)
$(nft_ack_sets_inv)

	# ----- forward chain (priority -1: after fw4 mangle_forward at -150,
	# before fw4 filter forward at 0) -----
	chain forward {
		type filter hook forward priority -1; policy accept;
$(nft_mss_clamp_rules)
		iifname \$WAN goto down
		oifname != \$WAN accept
$(nft_ack_jump)
		# An ICMP error is RELATED and shares its flow's conntrack: it replays
		# the flow's class and never re-judges it (auto would rewrite it).
		ct state related meta l4proto { icmp, ipv6-icmp } goto replay
		ct mark and 0xf080 != $DEC jump decide
		ct mark and 0x100 == 0 jump auto
		ct mark and 0x200 != 0 jump guard
		ct mark and 0x400 != 0 jump vguard
		goto replay
	}

	# Every upload packet: the connmark's DSCP into the packet (and leaf).
	chain replay {
$(case "$QDISC$SHAPE_UP" in hfsc1|htb1) printf '\t\tmeta priority set ct mark and 0x3f map @leaf_of\n' ;; esac)
		ct mark and 0x3f vmap @dscp_of
$(nft_wash_up_rule)
	}

	# Download: feed the meters and move the class. On the IFB, ctinfo has
	# already applied this packet's mark, so a move counts from the next
	# packet; on the LAN device ctinfo runs after this chain.
	chain down {
$([ "$WASH_DOWN" = yes ] && if [ "$QDISC" != cake ] || [ "$SHAPE_DN" = 0 ]; then printf '\t\tcounter jump set_cs0\n'; elif [ "$DL_LAN" = 1 ]; then printf '\t\toifname != "%s" counter jump set_cs0\n' "$IFB"; fi)
		ct state related meta l4proto { icmp, ipv6-icmp } accept
		ct mark and 0x180 == 0x80 jump auto
		ct mark and 0x200 != 0 jump guard
		ct mark and 0x400 != 0 jump vguard
		accept
	}

	# Once per connection, and again after a ruleset change.
	chain decide {
		ct state related meta l4proto { icmp, ipv6-icmp } return
$([ "$WASH_DOWN" = yes ] || printf '\t\tip dscp != cs0 ct mark set ip dscp map @dscpstc return\n\t\tip6 dscp != cs0 ct mark set ip6 dscp map @dscpstc return\n')
		ct mark set $DEC
$([ -n "$_PF_GM" ] && printf '\t\tmeta l4proto udp ether saddr @gaming_mac ct original proto-dst != @web_ports goto s_ef\n')
$([ -n "$_PF_G4" ] && printf '\t\tmeta l4proto udp ip saddr @gaming4 ct original proto-dst != @web_ports goto s_ef\n')
$([ -n "$_PF_G6" ] && printf '\t\tmeta l4proto udp ip6 saddr @gaming6 ct original proto-dst != @web_ports goto s_ef\n')
$([ -n "$_PF_LM" ] && printf '\t\tether saddr @lowprio_mac goto s_low\n')
$([ -n "$_PF_L4" ] && printf '\t\tip saddr @lowprio4 goto s_low\n')
$([ -n "$_PF_L6" ] && printf '\t\tip6 saddr @lowprio6 goto s_low\n')
$(nft_adv_service "$_ADA_SVC")
$([ -n "$_ADA_SVC_SRC" ] && printf '\t\tmeta l4proto . th sport vmap @svc_src\n')
		icmp type echo-request goto s_cs5
		icmpv6 type echo-request goto s_cs5
$([ -n "$_ADA_P2P" ] && printf '\t\tct state new ct original proto-dst != @web_ports update @new_conn4 { ct original ip saddr limit rate over %s/minute burst %s packets } update @p2p4 { ct original ip saddr }\n\t\tct state new ct original proto-dst != @web_ports update @new_conn6 { ct original ip6 saddr limit rate over %s/minute burst %s packets } update @p2p6 { ct original ip6 saddr }\n' "$_ADA_P2P" "$_ADA_P2P" "$_ADA_P2P" "$_ADA_P2P")
		meta l4proto tcp ct mark set $TCPA
	}
	chain s_ef   { ct mark set $EF; }
	chain s_cs5  { ct mark set $CS5; }
	chain s_call { ct mark set $CALL; }
	chain s_af41 { ct mark set $AF41; }
	chain s_low  { ct mark set $LOW; }
	chain s_bulk { ct mark set $BULK; }
	chain s_vpn  { ct mark set $VPN; }

	# AUTO: unlisted traffic, re-judged on every packet from its flags.
	chain auto {
		meta l4proto tcp update @flow_meter { ct id . ct direction limit rate over ${SLOW_FLOW_PPS}/second burst ${SLOW_FLOW_PPS} packets } update @fast { ct id }
		meta l4proto != tcp update @flow_meter { ct id . ct direction limit rate over ${UDP_FAST_PPS}/second burst ${UDP_FAST_BURST} packets } update @fast { ct id }
		oifname \$WAN update @byte_meter { ct id . ct direction limit rate over $hu bytes/second burst $hub bytes } update @heavy { ct id }
		iifname \$WAN update @byte_meter { ct id . ct direction limit rate over $hd bytes/second burst $hdb bytes } update @heavy { ct id }
		oifname \$WAN update @dev_up4 { ip saddr limit rate over $hu bytes/second burst $hub bytes } ct id @fast update @heavy { ct id }
		oifname \$WAN update @dev_up6 { ip6 saddr limit rate over $hu bytes/second burst $hub bytes } ct id @fast update @heavy { ct id }
		iifname \$WAN update @dev_dn4 { ip daddr limit rate over $hd bytes/second burst $hdb bytes } ct id @fast update @heavy { ct id }
		iifname \$WAN update @dev_dn6 { ip6 daddr limit rate over $hd bytes/second burst $hdb bytes } ct id @fast update @heavy { ct id }
$(if _bulk_sticky_on yes; then cat <<STK
		ct id @heavy jump mark_bulk
		ct original ip saddr . ct original ip daddr @bulk_src4 goto a_bulk
		ct original ip6 saddr . ct original ip6 daddr @bulk_src6 goto a_bulk
STK
else printf '\t\tct id @heavy goto a_bulk\n'; fi)
$([ -n "$_ADA_P2P" ] && printf '\t\tct original ip saddr @p2p4 ct original proto-dst != @web_ports goto a_bulk\n\t\tct original ip6 saddr @p2p6 ct original proto-dst != @web_ports goto a_bulk\n')
		meta l4proto tcp ct id @fast goto a_cs0
		ct id @fast goto a_af11
		meta l4proto tcp goto a_af42
		ct original proto-dst @web_ports goto a_af42
		ct avgpkt <= ${UDP_SMALL_AVGPKT} goto a_cs5
		goto a_cs0
	}
$(_bulk_sticky_on yes && cat <<'STK'
	chain mark_bulk {
		update @bulk_src4 { ct original ip saddr . ct original ip daddr }
		update @bulk_src6 { ct original ip6 saddr . ct original ip6 daddr }
		goto a_bulk
	}
STK
)
	chain a_bulk { ct mark set ct mark and 0xffffffc0 or 1; }
	chain a_cs0  { ct mark set ct mark and 0xffffffc0; }
	chain a_af11 { ct mark set ct mark and 0xffffffc0 or 10; }
	chain a_af42 { ct mark set ct mark and 0xffffffc0 or 36; }
	chain a_cs5  { ct mark set ct mark and 0xffffffc0 or 40; }

	# Gaming guard: EF while under udp_fast_pps packets and udp_fast_pps x
	# packet_size bytes a second each way, AF11 while over (5 s hold), as
	# fast UDP is in Simple. A stream on a gaming device (screen share,
	# Remote Play) would fill 1:10 and crowd out the game.
	chain guard {
		update @flow_meter { ct id . ct direction limit rate over ${UDP_FAST_PPS}/second burst ${UDP_FAST_BURST} packets } update @udp_fast { ct id }
		update @guard_bytes { ct id . ct direction limit rate over $GB bytes/second burst $GBB bytes } update @udp_fast { ct id }
		ct id @udp_fast ct mark set ct mark and 0xffffffc0 or 10 return
		ct mark set ct mark and 0xffffffc0 or 46
	}

	# Video-call guard: call UDP keeps its mark (CS4, AF41 under CAKE) under
	# udp_fast_pps, AF11 while over (5 s hold). The default list carries IPsec
	# (500 / 4500, Wi-Fi Calling), and a full IPsec tunnel carries bulk too.
	chain vguard {
		update @flow_meter { ct id . ct direction limit rate over ${UDP_FAST_PPS}/second burst ${UDP_FAST_BURST} packets } update @udp_fast { ct id }
		ct id @udp_fast ct mark set ct mark and 0xffffffc0 or 10 return
		ct mark set ct mark and 0xffffffc0 or $VC
	}

$(nft_ack_chain_inv)

	# ----- DSCP setters + ACK drop chains -----
$(nft_dscp_setters)
$(nft_ack_drop_inv)
}
EOF
}

setup_nft_adaptive() {
	local nft="$NFT_DIR/$NFT_ADAPTIVE.nft" gen _sl s n cp h0 pg ph gen_f="$NFT_DIR/$NFT_ADAPTIVE.gen"
	_pf_fmt_ipsets
	_ADA_SETS="$(nft_adv_ip_set gaming4 "$_PF_G4" ipv4_addr)
$(nft_adv_ip_set gaming6 "$_PF_G6" ipv6_addr)
$(nft_adv_mac_set gaming_mac "$_PF_GM")
$(nft_adv_ip_set lowprio4 "$_PF_L4" ipv4_addr)
$(nft_adv_ip_set lowprio6 "$_PF_L6" ipv6_addr)
$(nft_adv_mac_set lowprio_mac "$_PF_LM")"
	# Listed ports, earlier wins an overlap: bulk, video, VPN, DNS / DoT / NTP.
	_ADA_SVC=""
	while IFS= read -r _sl; do
		case "$_sl" in
			"")        continue ;;
			"#SKIP "*) msg "adaptive service map: ${_sl#\#SKIP }" ;;
			*)         _ADA_SVC="$_sl" ;;
		esac
	done <<EOF
$(printf 'tcp\t%s\ts_bulk\nudp\t%s\ts_bulk\nudp\t%s\ts_call\ntcp\t%s\ts_af41\nudp\t%s\ts_vpn\ntcp\t%s\ts_vpn\nudp\t53,123\t~s_cs5\ntcp\t53,853\t~s_cs5\n' \
	"$TCP_BULK" "$UDP_BULK" "$VIDCONF_PORTS" "$VIDCONF_PORTS" "$ADA_VPN_PORTS" "$ADA_VPN_PORTS" | _svc_awk)
EOF
	# The bulk lists as a LAN SOURCE port too, as Simple matches them and the
	# UI says: a torrent client sends from its listening port to random ones.
	_ADA_SVC_SRC=$(printf 'tcp\t%s\t~s_bulk\nudp\t%s\t~s_bulk\n' "$TCP_BULK" "$UDP_BULK" | _svc_awk | grep -v '^#SKIP ')
	# The replay maps, codepoint -> leaf and codepoint -> set_<name>.
	_ADA_LEAF=""; _ADA_DSCP=""
	for s in $DSCP_SPEC; do
		n=${s%%:*}; cp=${s#*:}
		[ "$n" = 0x01 ] && n=le
		_ADA_LEAF="${_ADA_LEAF:+$_ADA_LEAF, }${cp%%:*} : 1:${cp#*:}"
		_ADA_DSCP="${_ADA_DSCP:+$_ADA_DSCP, }${cp%%:*} : jump set_$n"
	done
	_ADA_P2P=""; _ada_p2p_ok && _ADA_P2P=$ADA_P2P_RATE
	mkdir -p "$NFT_DIR"; chmod 700 "$NFT_DIR" 2>/dev/null
	# Squeeze the blank lines the optional blocks leave.
	_nft_adaptive_body 0 | awk 'NF || !b; { b = !NF }' > "$nft.new" || return 1
	h0=$(_hash_short < "$nft.new")
	gen=$(printf '%s\n' "$h0" | awk '{ n = 0; for (i = 1; i <= length($0); i++) n = (n * 31 + index("0123456789abcdef", substr($0, i, 1))) % 15; print n + 1 }')
	# The hash has only 15 values: a changed ruleset that hashed to the
	# generation already loaded would leave every live connection on its old
	# decision. The last load is kept as "<generation> <hash of the gen-0
	# text>" (it outlives a stop, as the connmarks do): the same text keeps
	# its generation, a different one never reuses it.
	if [ -r "$gen_f" ] && read -r pg ph < "$gen_f" && _isnum "$pg" && [ "$pg" -ge 1 ] && [ "$pg" -le 15 ]; then
		if [ "$ph" = "$h0" ]; then gen=$pg
		elif [ "$pg" = "$gen" ]; then gen=$((gen % 15 + 1)); fi
	fi
	_nft_adaptive_body "${gen:-1}" | awk 'NF || !b; { b = !NF }' > "$nft.new" || return 1
	nft_load_or_log "$nft" "Adaptive" || return 1
	printf '%s %s\n' "${gen:-1}" "$h0" > "$gen_f" 2>/dev/null
	return 0
}

# The file before the table: a fw4 reload in between would load it again.
cleanup_nft() {
	local t
	for t in "$NFT_RETIRED" "$NFT_SIMPLE" "$NFT_ADVANCED" "$NFT_ADAPTIVE"; do
		rm -f "$NFT_DIR/$t.nft"
		nft delete table inet "$t" 2>/dev/null
	done
}

# Drop the inactive modes' tables and their files (the next fw4 reload would
# load those beside the active one); the active one is replaced atomically.
_nft_drop_inactive() {
	local t a; a=$(_nft_table)
	for t in "$NFT_RETIRED" "$NFT_SIMPLE" "$NFT_ADVANCED" "$NFT_ADAPTIVE"; do
		[ "$t" = "$a" ] && continue
		rm -f "$NFT_DIR/$t.nft"
		nft delete table inet "$t" 2>/dev/null
	done
	return 0
}

################################################################################
### OPERATIONS                                                               ###
################################################################################
nft_mode_disp() {
	case "$NFT_MODE" in
		simple)   echo "Simple" ;;
		advanced) echo "Advanced" ;;
		adaptive) echo "Adaptive" ;;
		*)        echo "$NFT_MODE" ;;
	esac
}
_nft_table() {
	case "$NFT_MODE" in
		simple)   echo "$NFT_SIMPLE" ;;
		advanced) echo "$NFT_ADVANCED" ;;
		adaptive) echo "$NFT_ADAPTIVE" ;;
	esac
}

# TRUE when procd owns the lifecycle and this call did not come from the init
# script (which calls back with QOS_EX_SUPERVISED=1, so no recursion).
_init_owns() {
	[ "${QOS_EX_SUPERVISED:-0}" != "1" ] && [ -x "/etc/init.d/$SCRIPT_NAME" ]
}

# What start() would run in tc and ip, as text, without running it (tc / ip
# are stubbed in a subshell; `show` calls return nothing). _tc_hash
# fingerprints it, so reload() can tell a classifier change from one that
# needs the qdiscs rebuilt; `tcplan` prints it. Needs load_config +
# calc_bandwidth first.
_tc_plan() {
	(
		exec 3>&1 >/dev/null 2>&1
		tc() {
			case "$1" in -force|-batch) cat >&3; return 0 ;; esac
			[ "$2" = "show" ] && return 0
			printf 'tc %s\n' "$*" >&3
		}
		ip() {
			[ "$2" = "show" ] && return 1
			printf 'ip %s\n' "$*" >&3
		}
		insmod() { :; }
		msg() { :; }
		log() { :; }
		err() { return 1; }
		_logline() { :; }
		[ "$SHAPE_DN" = 1 ] && setup_ingress
		case "$QDISC" in
			cake) setup_cake ;;
			hfsc|htb)
				[ "$SHAPE_UP" = 1 ] && "setup_$QDISC" "$WAN" "$UPLOAD_KBPS"   "$GAME_UP"
				[ "$SHAPE_DN" = 1 ] && "setup_$QDISC" "$IFB" "$DOWNLOAD_KBPS" "$GAME_DN" ;;
		esac
		:
	)
}

_tc_hash() { _tc_plan | _hash_short; }

tcplan() {
	_LOG_QUIET=1
	load_config || return 1
	calc_bandwidth
	_tc_plan
}

# Serialises start / stop / reload: a procd reload, a LuCI restart and an ifup
# can land together, and interleaved IFB delete / add half-builds the tree.
# flock on fd 9: the kernel drops the lock when its holder dies, so there is
# no stale lock to take over. Taken after the _init_owns re-route, or the init
# script's call-back deadlocks. A child that outlives the run (the Ping Filter
# daemon) is started with fd 9 closed in _pf_delegate, or it would hold the
# lock. /var/run: /tmp and OpenWrt's /var/lock are 1777.
LOCK_FILE="/var/run/qos-ex.lock"
START_PART="/var/run/qos-ex-partial"
LOCK_WAIT=30
# A reload that could not get the lock is queued here; the start or reload
# holding it runs it before letting go. A stop drops it.
RELOAD_PEND="/var/run/qos-ex-reload.pending"
_lock() {   # $1 = seconds to wait (default LOCK_WAIT)
	local _max="${1:-$LOCK_WAIT}" _w=0
	# A BusyBox built without flock: unserialised, as before there was a lock.
	command -v flock >/dev/null 2>&1 || { log "flock not found - start / stop / reload not serialised"; return 0; }
	# A failed redirection on exec ends the shell: probe it first.
	( : >> "$LOCK_FILE" ) 2>/dev/null || { err "cannot open $LOCK_FILE"; return 1; }
	exec 9>> "$LOCK_FILE"
	until flock -n 9; do
		if [ "$_w" -ge "$_max" ]; then
			exec 9>&-
			[ "$_max" = 0 ] || msg "another QoS-Ex run still holds the lock after ${_max}s"
			return 1
		fi
		_w=$((_w + 1))
		sleep 1
	done
	return 0
}
# Closing the fd releases the lock.
_unlock() { exec 9>&-; }
_reload_pending() {
	[ -f "$RELOAD_PEND" ] || return 0
	rm -f "$RELOAD_PEND" 2>/dev/null
	msg "applying the reload queued while this run held the lock"
	_reload_locked
}

# A start that fails after replacing qdiscs removes what it built: an HFSC
# root without its default class drops every unclaimed packet. A device the
# coexistence guards refused is not touched.
_start_abort() {
	local _d
	for _d in $_QOS_EX_TOUCH_ROOT; do tc qdisc del dev "$_d" root 2>/dev/null; done
	[ "$_QOS_EX_TOUCH_ING" = 1 ] && cleanup_ingress
	rm -f "$START_PART" 2>/dev/null
	_QOS_EX_TOUCH_ROOT=""; _QOS_EX_TOUCH_ING=0
	err "start aborted - partial qdiscs removed, $WAN left unshaped"
	return 1
}

start() {
	# When procd owns the service, start through the init script so the
	# Ping Filter instance is registered.
	if _init_owns; then
		"/etc/init.d/$SCRIPT_NAME" start || return 1
		# rc.common drops start_service's status; the start stamp is the result.
		[ "$(uci -q get "$UCI_CFG.settings.enabled")" = "1" ] || return 0
		[ -f /var/run/qos-ex-started ]
		return $?
	fi
	local _rc
	_lock || return 1
	_start_locked; _rc=$?
	_reload_pending
	_unlock
	return $_rc
}

_start_locked() {
	_NFT_KEEP=0
	load_config || return 1
	[ "$ENABLED" = "1" ] || { msg "Disabled in UCI — not starting"; return 0; }
	ip link show "$WAN" >/dev/null 2>&1 || { err "WAN $WAN not found"; return 1; }
	# A DSA switch's CPU port (eth0 on most DSA routers, the old default
	# wan) carries every LAN port too: shaping it shapes the whole switch.
	[ -d "/sys/class/net/$WAN/dsa" ] && { err "wan '$WAN' is the switch's CPU port (DSA conduit), not the WAN - set the WAN device in Setup -> Line"; return 1; }
	# Not an L3 device (the port under pppoe-wan, say): the ifup hook never
	# fires for it, and forwarded traffic never names it. Warned, not refused.
	_wan_l3
	[ $? = 1 ] && msg "WARNING: wan '$WAN' is not the device of any interface that is up - autostart (the ifup hook) and classification both need that device (ip route get 1.1.1.1)"
	calc_bandwidth
	_ct_acct_on
	_QOS_EX_CTM=$(_ctmark_users)
	[ -z "$_QOS_EX_CTM" ] || { printf '[%s] WARNING: %s\n' "$DISPLAY_NAME" "$_QOS_EX_CTM enabled - QoS-Ex rewrites the whole conntrack mark, so its per-connection marks do not hold"
		_logline "WARN" "$_QOS_EX_CTM enabled - QoS-Ex rewrites the whole conntrack mark, so its per-connection marks do not hold"; }
	[ "$SHAPE_UP$SHAPE_DN" != 00 ] || { err "upload_kbps and download_kbps are both 0 - nothing to shape"; return 1; }
	if [ "$DL_LAN" = 1 ] && [ "$SHAPE_DN" = 1 ]; then
		if [ -z "$LAN_DEV" ] || ! ip link show "$IFB" >/dev/null 2>&1; then
			err "download_on lan: LAN device '${LAN_DEV:-none}' not found - set it in Setup -> Queue (settings.lan)"; return 1
		fi
	fi
	_sqm_on && { err "SQM is enabled on $WAN - stop or disable it first"; return 1; }
	# Every coexistence check before anything is deleted: a check that failed
	# half-way through the build had already removed the other shaper's
	# download path.
	if [ "$SHAPE_UP" = 1 ]; then _foreign_root "$WAN" || return 1; fi
	if [ "$SHAPE_DN" = 1 ]; then
		_foreign_ingress || return 1
		ip link show "$IFB" >/dev/null 2>&1 && { _foreign_root "$IFB" || return 1; }
	fi
	_QOS_EX_TOUCH_ROOT=""; _QOS_EX_TOUCH_ING=0
	# Written before the build: a run killed half-way still tells the next
	# stop and start which devices are ours.
	printf 'WAN=%s\nIFB=%s\nUP=%s\nDN=%s\nDLON=%s\n' "$WAN" "$IFB" "$SHAPE_UP" "$SHAPE_DN" "$DL_ON" > "$START_PART" 2>/dev/null
	if [ "$SHAPE_DN" = 1 ]; then
		setup_ingress || { _start_abort; return 1; }
	fi
	case "$QDISC" in
		cake)
			if ! setup_cake; then
				_mod_loaded sch_cake || err "kmod-sched-cake is not loaded"
				err "cake qdisc setup failed"; _start_abort; return 1
			fi ;;
		hfsc|htb)
			if [ "$SHAPE_UP" = 1 ]; then
				"setup_$QDISC" "$WAN" "$UPLOAD_KBPS"   "$GAME_UP" || { err "$QDISC setup failed on $WAN"; _start_abort; return 1; }
			fi
			if [ "$SHAPE_DN" = 1 ]; then
				"setup_$QDISC" "$IFB" "$DOWNLOAD_KBPS" "$GAME_DN" || { err "$QDISC setup failed on $IFB"; _start_abort; return 1; }
			fi ;;
		*) err "Unknown qdisc: $QDISC"; return 1 ;;
	esac
	# The qdiscs are up: until the start stamp exists, the marker tells stop
	# they are ours. The active table is replaced atomically, so a failed load
	# keeps the old rules; the other modes' tables go only once it loaded.
	case "$NFT_MODE" in
		simple)   setup_nft_simple   || { err "NFT setup failed — qdisc is up but classification is not"; return 1; } ;;
		advanced) setup_nft_advanced || { err "NFT setup failed — qdisc is up but classification is not"; return 1; } ;;
		adaptive) setup_nft_adaptive || { err "NFT setup failed — qdisc is up but classification is not"; return 1; } ;;
		*) err "Unknown nft_mode: $NFT_MODE"; return 1 ;;
	esac
	_nft_drop_inactive
	log "Started: qdisc=$QDISC nft=$NFT_MODE wan=$WAN"
	msg "Started ($QDISC / $(nft_mode_disp)) v$VERSION"
	# The devices and tc plan actually applied: stop uses them (settings.wan
	# may have changed since), reload compares the plan hash.
	local _upt=""
	read -r _upt _ < /proc/uptime 2>/dev/null
	{
		echo "WAN=$WAN"
		echo "IFB=$IFB"
		echo "TCHASH=$(_tc_hash)"
		echo "UP=$SHAPE_UP"
		echo "DN=$SHAPE_DN"
		echo "DLON=$DL_ON"
		# Seconds since boot: uptime that an NTP step cannot inflate.
		echo "UPT=${_upt%%.*}"
		# What the live counters need: the rpcd shim reads these with the
		# sliced lib live.sh instead of parsing this script every poll.
		echo "QDISC=$QDISC"
		echo "PRIO=$CAKE_PRIO"
		echo "UL=$UPLOAD_KBPS"
		echo "DL=$DOWNLOAD_KBPS"
	} > /var/run/qos-ex-started 2>/dev/null
	rm -f "$START_PART" 2>/dev/null
	[ "${_PF_KEEP:-0}" = 1 ] && return 0
	pf_start
	_pf_sig > "$PF_SIG" 2>/dev/null
	return 0
}

stop() {
	# When procd owns the service, stop through the init script, or procd
	# respawns the Ping Filter; it calls back with QOS_EX_SUPERVISED=1.
	if _init_owns; then
		"/etc/init.d/$SCRIPT_NAME" stop
		# rc.common drops stop_service's status (as start's): a stop that
		# worked left neither the start stamp nor the partial marker.
		[ ! -f /var/run/qos-ex-started ] && [ ! -f "$START_PART" ]
		return $?
	fi
	local _rc
	_lock || return 1
	_stop_locked; _rc=$?
	rm -f "$RELOAD_PEND" 2>/dev/null
	_unlock
	return $_rc
}

_stop_locked() {
	load_config 2>/dev/null
	# Ping Filter goes down with the shaper (not across a reload's restart).
	[ "${_PF_KEEP:-0}" = 1 ] || { rm -f "$PF_SIG" 2>/dev/null; pf_stop; }
	# The devices the last start recorded, else the loaded config.
	local _swan _sifb _sup="" _sdn="" _st=/var/run/qos-ex-started
	# A start whose classifier failed left the marker, not the stamp.
	[ -r "$_st" ] || _st="$START_PART"
	if [ -r "$_st" ]; then
		_swan=$(sed -n 's/^WAN=//p' "$_st" 2>/dev/null)
		_sifb=$(sed -n 's/^IFB=//p' "$_st" 2>/dev/null)
		# 0 = that start left the direction unshaped.
		_sup=$(sed -n 's/^UP=//p' "$_st" 2>/dev/null)
		_sdn=$(sed -n 's/^DN=//p' "$_st" 2>/dev/null)
		[ -n "$_swan" ] && WAN="$_swan"
		[ -n "$_sifb" ] && IFB="$_sifb"
		# Where that start put the download (the config may have moved since).
		case "$(sed -n 's/^DLON=//p' "$_st" 2>/dev/null)" in lan) DL_LAN=1 ;; wan) DL_LAN=0 ;; esac
	fi
	# Only what a start of ours built: the stamp or marker names it, or the
	# IFB carries our alias. Never an ifb-<wan> by its name alone (other
	# shapers such as qosify use the same one): start_service and the ifup
	# hook stop first, even with QoS-Ex disabled.
	local _ours=0
	[ -r "$_st" ] && _ours=1
	[ -n "$IFB" ] && ip link show "$IFB" >/dev/null 2>&1 && _dev_ours "$IFB" && _ours=1
	if [ "$_ours" = 1 ]; then
		# The WAN root only when it is one of ours by kind.
		if [ -n "$WAN" ] && [ "$_sup" != 0 ]; then
			case "$(tc qdisc show dev "$WAN" root 2>/dev/null | awk 'NR==1{print $2}')" in
				cake|cake_mq|hfsc|htb) tc qdisc del dev "$WAN" root 2>/dev/null ;;
			esac
		fi
		if [ "$_sdn" != 0 ]; then
			# The download root only when it is ours by kind (a LAN device
			# keeps whatever else it carries).
			if [ -n "$IFB" ]; then
				case "$(tc qdisc show dev "$IFB" root 2>/dev/null | awk 'NR==1{print $2}')" in
					cake|cake_mq|hfsc|htb) tc qdisc del dev "$IFB" root 2>/dev/null ;;
				esac
			fi
			cleanup_ingress
		fi
	fi
	cleanup_nft
	rm -f /var/run/qos-ex-started "$START_PART" 2>/dev/null
	log "Stopped"
	msg "Stopped"
}

reload() {
	local _rc
	# Not running while procd owns the service: start through the init
	# script. A direct start here left procd without the service, its Ping
	# Filter instance and the reload trigger, and the ifup hook then saw the
	# stamp and never repaired it.
	if _init_owns && [ ! -f /var/run/qos-ex-started ]; then
		case "$(uci -q get "$UCI_CFG.settings.enabled")" in
			1|yes|on|true|enabled)
				msg "not running - starting through /etc/init.d/$SCRIPT_NAME"
				start; return $? ;;
		esac
	fi
	if ! _lock; then
		# Queued for the holder. A few more seconds cover a holder that let
		# go between its own check and this file.
		: > "$RELOAD_PEND" 2>/dev/null
		_lock 5 || { msg "reload queued - applied when the current run finishes"; return 0; }
		# Got it: unless that holder already ran the queued reload.
		[ -f "$RELOAD_PEND" ] || { _unlock; return 0; }
	fi
	rm -f "$RELOAD_PEND" 2>/dev/null
	_reload_locked; _rc=$?
	_reload_pending
	_unlock
	return $_rc
}

_reload_locked() {
	load_config || return 1
	# The procd trigger also fires on master_disable's commit. Disabled: stop
	# a running shaper (a hand edit), else nothing; classifier rules with no
	# qdiscs would still write the ct mark ctinfo replays.
	if [ "$ENABLED" != "1" ]; then
		# A start whose classifier failed left its qdiscs and the marker.
		if [ -f /var/run/qos-ex-started ] || [ -f "$START_PART" ]; then
			msg "Disabled in UCI - stopping"
			_stop_locked
		else
			msg "Disabled in UCI - nothing to reload"
		fi
		return 0
	fi
	ip link show "$WAN" >/dev/null 2>&1 || { err "WAN $WAN not found"; return 1; }
	# The trigger cannot tell a classifier change from a shaping change: if
	# the tc plan moved, escalate to a full restart.
	local _was _now
	_was=$(sed -n 's/^TCHASH=//p' /var/run/qos-ex-started 2>/dev/null)
	# Not shaping (no stamp): a full start, never an nft-only reload.
	if [ -z "$_was" ]; then
		msg "not running - full start rather than an nft-only reload"
		_start_locked
		return $?
	fi
	calc_bandwidth
	_now=$(_tc_hash)
	# A plan that moved, or qdiscs lost since the start (a PPPoE redial with
	# the ifup hook off, another tool): a full restart. The plan hash alone
	# never saw the second.
	if [ "$_was" != "$_now" ] || ! _live_ok; then
		if [ "$_was" != "$_now" ]; then
			msg "shaping config changed - full restart rather than an nft-only reload"
		else
			msg "qdiscs missing since the start - full restart"
		fi
		# Ping Filter stays up: its sets do not depend on the qdiscs.
		local _rc
		_PF_KEEP=1
		_stop_locked
		sleep 1
		_start_locked; _rc=$?
		_PF_KEEP=0
		[ "$_rc" = 0 ] || return "$_rc"
		_pf_sync
		return 0
	fi
	_NFT_KEEP=1
	# The other modes' tables go only once the active one loaded: a mode
	# switch whose ruleset fails keeps the old classifier.
	case "$NFT_MODE" in
		simple)   setup_nft_simple   || { err "NFT reload failed — see $NFT_ERR"; return 1; } ;;
		advanced) setup_nft_advanced || { err "NFT reload failed — see $NFT_ERR"; return 1; } ;;
		adaptive) setup_nft_adaptive || { err "NFT reload failed — see $NFT_ERR"; return 1; } ;;
		*) err "Unknown nft_mode: $NFT_MODE"; return 1 ;;
	esac
	_nft_drop_inactive
	_pf_sync
}

# Every shaped direction still has its qdiscs: the WAN root of the running
# kind, and the ingress, IFB and IFB root. Needs load_config + calc_bandwidth.
_live_ok() {
	local _q
	if [ "$SHAPE_UP" = 1 ]; then
		_q=$(tc qdisc show dev "$WAN" root 2>/dev/null | awk 'NR==1{print $2}')
		[ "$_q" = "$QDISC" ] || return 1
	fi
	if [ "$SHAPE_DN" = 1 ]; then
		ip link show "$IFB" >/dev/null 2>&1 || return 1
		if [ "$DL_LAN" = 1 ]; then tc qdisc show dev "$IFB" 2>/dev/null | grep -q '^qdisc clsact ' || return 1
		else tc qdisc show dev "$WAN" 2>/dev/null | grep -q '^qdisc ingress ' || return 1; fi
		_q=$(tc qdisc show dev "$IFB" root 2>/dev/null | awk 'NR==1{print $2}')
		[ "$_q" = "$QDISC" ] || return 1
	fi
	return 0
}

################################################################################
### STATUS / STATS                                                           ###
################################################################################
# 1 when the /root source differs from the installed copy (reload runs the
# installed one). Absent source or any failure = 0: never a false positive.
_file_drift() {
	local src="$1" dst="$2" a b
	[ -f "$src" ] && [ -f "$dst" ] || { echo 0; return 0; }
	[ "$(readlink -f "$src" 2>/dev/null)" = "$(readlink -f "$dst" 2>/dev/null)" ] && { echo 0; return 0; }
	# Size first: no read at all when lengths differ (polled path).
	a=$(wc -c < "$src" 2>/dev/null)
	b=$(wc -c < "$dst" 2>/dev/null)
	[ -n "$a" ] && [ -n "$b" ] || { echo 0; return 0; }
	[ "$a" != "$b" ] && { echo 1; return 0; }
	# cmp, else md5sum.
	if command -v cmp >/dev/null 2>&1; then
		cmp -s "$src" "$dst" >/dev/null 2>&1 && echo 0 || echo 1
	else
		a=$(md5sum "$src" 2>/dev/null | cut -d" " -f1)
		b=$(md5sum "$dst" 2>/dev/null | cut -d" " -f1)
		[ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] && echo 1 || echo 0
	fi
}

# The LAN device for download_on lan: netifd's device for the lan
# interface, else br-lan when it exists. Empty = none found.
_lan_dev() {
	local _d=""
	# A subshell: network.sh sources jshn.sh unguarded (see _wan_live).
	if [ -f /lib/functions/network.sh ] && [ -f /usr/share/libubox/jshn.sh ]; then
		_d=$(
			# shellcheck disable=SC1091
			. /lib/functions/network.sh 2>/dev/null
			command -v network_get_device >/dev/null 2>&1 || exit 0
			_ld=""; network_get_device _ld lan 2>/dev/null
			echo "$_ld"
		)
	fi
	[ -n "$_d" ] || { [ -d /sys/class/net/br-lan ] && _d=br-lan; }
	case "$_d" in *[!A-Za-z0-9._-]*) _d="" ;; esac
	echo "$_d"
}

# The device carrying the default route: netifd's answer via network.sh,
# else `ip route`. Empty = unknown (line down), never "wrong".
_wan_live() {
	local _wl_if="" _wl_dev=""
	# A subshell here: network.sh sources jshn.sh unguarded, and a missing
	# file is fatal to the sourcing shell.
	if [ -f /lib/functions/network.sh ] && [ -f /usr/share/libubox/jshn.sh ]; then
		_wl_dev=$(
			. /lib/functions/network.sh 2>/dev/null
			command -v network_find_wan >/dev/null 2>&1 || exit 0
			network_find_wan _wl_if 2>/dev/null
			[ -n "$_wl_if" ] || exit 0
			network_get_device _wl_dev "$_wl_if" 2>/dev/null
			echo "$_wl_dev"
		)
	fi
	# First default route = the primary line right now.
	if [ -z "$_wl_dev" ]; then
		_wl_dev=$(ip -4 route show default 2>/dev/null | \
			awk '$1 == "default" { for (i = 2; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
	fi
	echo "$_wl_dev"
}

# Enabled users of the conntrack mark (mwan3, pbr): classify writes the WHOLE
# mark (DSCP | 0x80), so theirs do not hold. Space separated; empty = none.
_ctmark_users() {
	local _s _o=""
	for _s in mwan3 pbr; do
		_svc_enabled "$_s" && _o="${_o:+$_o }$_s"
	done
	echo "$_o"
}

# A service's autostart, from its rc.d symlink: what `/etc/init.d/X enabled`
# tests, without a shell to source the init script.
_svc_enabled() {
	local _f
	for _f in /etc/rc.d/S[0-9][0-9]"$1"; do
		[ -e "$_f" ] && return 0
	done
	return 1
}

# 0 when $WAN is the L3 device of an interface netifd has up (what the ifup
# hook fires for, and what the classifier's iifname / oifname see), 1 when
# netifd answers and it is not, 2 when that cannot be told (no ubus answer).
_wan_l3() {
	[ -f /lib/functions/network.sh ] && [ -f /usr/share/libubox/jshn.sh ] || return 2
	command -v ubus >/dev/null 2>&1 || return 2
	# A subshell, as _wan_live: network.sh sources jshn.sh unguarded.
	(
		. /lib/functions/network.sh 2>/dev/null
		command -v network_get_device >/dev/null 2>&1 || exit 2
		_ifs=$(ubus -t 3 list 'network.interface.*' 2>/dev/null)
		[ -n "$_ifs" ] || exit 2
		for _i in $_ifs; do
			_i=${_i#network.interface.}
			network_is_up "$_i" || continue
			network_get_device _d "$_i" && [ "$_d" = "$WAN" ] && exit 0
		done
		exit 1
	)
}

# The download path's facts for state / status, into the caller's st_ifb,
# st_ingress and st_ctinfo: the device the download is shaped on, its hook
# qdisc (the WAN ingress, or the LAN device's clsact with download_on lan)
# and the ctinfo filter on it. $1 = the WAN's `tc qdisc show` output.
_dl_facts() {
	ip link show "$IFB" >/dev/null 2>&1 && st_ifb=1
	if [ "$DL_LAN" = 1 ]; then
		tc qdisc show dev "$IFB" 2>/dev/null | grep -q '^qdisc clsact ' && st_ingress=1
		tc filter show dev "$IFB" egress 2>/dev/null | grep -q ctinfo && st_ctinfo=1
	else
		case "$1" in *"qdisc ingress "*) st_ingress=1 ;; esac
		tc filter show dev "$WAN" parent ffff: 2>/dev/null | grep -q ctinfo && st_ctinfo=1
	fi
	return 0
}

# Up = every SHAPED direction has its qdiscs (rate 0 builds none). Reads the
# caller's st_* locals; answer in $_RUN.
_st_running() {
	_RUN=0
	[ "$st_nft" = 1 ] && [ "$SHAPE_UP$SHAPE_DN" != 00 ] || return 0
	[ "$SHAPE_UP" = 0 ] || [ "$st_root" = 1 ] || return 0
	[ "$SHAPE_DN" = 0 ] || { [ "$st_ingress" = 1 ] && [ "$st_ifb" = 1 ]; } || return 0
	_RUN=1
}

_state_uptime() {
	[ "$1" = 1 ] && [ -f /var/run/qos-ex-started ] || return 0
	local _now="" _start _u=""
	# Monotonic when the stamp has it: the wall clock is often stepped by
	# NTP just after the ifup start, which inflated the difference.
	_start=$(sed -n 's/^UPT=//p' /var/run/qos-ex-started 2>/dev/null)
	if _isnum "$_start" && read -r _u _ < /proc/uptime 2>/dev/null; then
		_now=${_u%%.*}
	else
		_now=$(date +%s 2>/dev/null || echo 0)
		_start=$(date -r /var/run/qos-ex-started +%s 2>/dev/null || echo 0)
	fi
	[ "$_now" -gt "$_start" ] 2>/dev/null && echo "uptime_s=$((_now - _start))"
	return 0
}

# Gaming devices the router hears now: the configured MACs and addresses
# whose neighbour entry is REACHABLE, DELAY, PROBE or PERMANENT (STALE,
# FAILED or no entry = not heard from lately). Lower case, space-separated.
_gaming_online() {
	[ -n "$GAMING_MAC$GAMING_IP4$GAMING_IP6" ] || return 0
	ip neigh show 2>/dev/null | awk -v want="$GAMING_MAC $GAMING_IP4 $GAMING_IP6" '
		BEGIN { n = split(tolower(want), A, " "); for (i = 1; i <= n; i++) W[A[i]] = 1 }
		$NF ~ /^(REACHABLE|DELAY|PROBE|PERMANENT)$/ {
			ip = tolower($1); mac = ""
			for (i = 2; i < NF; i++) if ($i == "lladdr") mac = tolower($(i + 1))
			if (ip in W) O[ip] = 1
			if (mac in W) O[mac] = 1
		}
		END { s = ""; for (k in O) s = s (s == "" ? "" : " ") k; print s }'
}

# Poll snapshot for Overview and Status: only the @@STATE@@ keys that move,
# from tc, one `nft list tables` and file tests. status() is the full report,
# fetched again only when cfg_sum or the state changes.
state() {
	_LOG_QUIET=1
	load_config || return 1
	calc_bandwidth
	local _qd _tbl st_root=0 st_ingress=0 st_ifb=0 st_ctinfo=0 st_nft=0
	_tbl=$(_nft_table)
	_qd=$(tc qdisc show dev "$WAN" 2>/dev/null)
	case "$_qd" in *cake*|*hfsc*|*htb*) st_root=1 ;; esac
	_dl_facts "$_qd"
	[ -n "$_tbl" ] && nft list tables inet 2>/dev/null | grep -qx "table inet $_tbl" && st_nft=1
	echo "@@STATE@@"
	echo "version=$VERSION"
	echo "enabled=$ENABLED"
	echo "qdisc=$QDISC"
	echo "nft_mode=$NFT_MODE"
	echo "wan=$WAN"
	echo "ifb=$IFB"
	echo "download_on=$DL_ON"
	echo "ul_kbps_eff=$UPLOAD_KBPS"
	echo "dl_kbps_eff=$DOWNLOAD_KBPS"
	_st_running
	echo "shape_up=$SHAPE_UP"
	echo "shape_dn=$SHAPE_DN"
	echo "running=$_RUN"
	# PF on only under the master switch; activity active | matchmaking | idle.
	local _pfon _pfact=idle _pft
	config_get _pfon pingfilter enabled 0
	[ "$ENABLED" = 1 ] && [ "$_pfon" = 1 ] || _pfon=0
	# Stopped from SSH (`pingfilter stop` parks it with .stopped): off,
	# whatever UCI says.
	[ -e "$PF_RUN_DIR/.stopped" ] && _pfon=0
	[ "$_pfon" = 1 ] && [ -r "$PF_RUN_DIR/.activity" ] && read -r _pfact _pft < "$PF_RUN_DIR/.activity"
	case "$_pfact" in active|matchmaking) ;; *) _pfact=idle ;; esac
	# PF's own freshness rule (pf_activity_state): a verdict older than two
	# idle intervals + 5 s is from a daemon that is no longer writing.
	case "$_pft" in
		''|*[!0-9]*) _pfact=idle ;;
		*) [ $(( $(date +%s) - _pft )) -le 65 ] 2>/dev/null || _pfact=idle ;;
	esac
	echo "pf_on=$_pfon"
	echo "pf_act=$_pfact"
	echo "gaming_online=$(_gaming_online)"
	local _pfv=""
	[ -r "$PF_BIN" ] && _pfv=$(sed -n '/^VERSION="/{s/^VERSION="\([^"]*\)".*/\1/p;q;}' "$PF_BIN" 2>/dev/null)
	echo "pf_ver=$_pfv"
	# The GitHub branch the last update installed (QoS-Ex-install.sh).
	local _br=""
	[ -r /etc/qos-ex/installed-ref ] && read -r _br < /etc/qos-ex/installed-ref
	case "$_br" in dev) ;; *) _br=main ;; esac
	echo "branch=$_br"
	echo "backend_stale=$(_file_drift "/root/$SCRIPT_NAME.sh" "$QOS_EX_BIN")"
	echo "pf_stale=$(_file_drift "/root/$SCRIPT_NAME-PF.sh" "$PF_BIN")"
	echo "cfg_sum=$(md5sum "/etc/config/$UCI_CFG" 2>/dev/null | cut -c1-12)"
	echo "ifb_up=$st_ifb"
	echo "root_qdisc=$st_root"
	echo "ingress_qdisc=$st_ingress"
	echo "ctinfo=$st_ctinfo"
	echo "nft_table=$st_nft"
	[ -f /etc/init.d/$SCRIPT_NAME ]             && echo "init=1"    || echo "init=0"
	[ -f /etc/hotplug.d/iface/99-$SCRIPT_NAME ] && echo "hotplug=1" || echo "hotplug=0"
	_state_uptime "$_RUN"
	echo "@@STATE_END@@"
}

status() {
	_LOG_QUIET=1
	load_config || err "config load failed - the report below is incomplete"
	calc_bandwidth
	local st_ifb=0 st_root=0 st_ingress=0 st_ctinfo=0 st_nft=0 st_init=0 st_hotplug=0
	local nft_tbl; nft_tbl=$(_nft_table)
	# One tc and one nft call, held in locals (polled path).
	local _qd _nftout
	_qd=$(tc qdisc show dev "$WAN" 2>/dev/null)
	case "$_qd" in *cake*|*hfsc*|*htb*) st_root=1 ;; esac
	_dl_facts "$_qd"
	if [ -n "$nft_tbl" ]; then
		# -t: chain and set counts only, without every set element.
		_nftout=$(nft -t list table inet "$nft_tbl" 2>/dev/null) && st_nft=1
	fi
	[ -f /etc/init.d/$SCRIPT_NAME ]             && st_init=1
	[ -f /etc/hotplug.d/iface/99-$SCRIPT_NAME ] && st_hotplug=1

	# Facts for both @@STATE@@ and the System Checks below.
	local st_init_en=0 nft_chains=0 nft_sets=0 ifb_filters=0
	if [ "$st_init" = 1 ]; then
		_svc_enabled "$SCRIPT_NAME" && st_init_en=1
	fi
	if [ "$st_nft" = 1 ]; then
		nft_chains=$(echo "$_nftout" | grep -c "chain ")
		nft_sets=$(echo "$_nftout" | grep -cE '^[[:space:]]+set ')
	fi
	if [ "$st_ifb" = 1 ]; then
		# One line per classifying filter (u32 flowid, fw classid), not the
		# u32 hash-table headers.
		ifb_filters=$(tc filter show dev "$IFB" 2>/dev/null | grep -cE '(flowid|classid) ')
	fi
	local st_mgr st_missing=""
	st_mgr=$(_pkg_mgr)
	[ -n "$st_mgr" ] && st_missing=$(_pkg_missing "$st_mgr")
	# Flow offloading bypasses nft for established flows; re-enabled by hand
	# it would be silent.
	local st_off_sw st_off_hw
	st_off_sw=$(uci -q get firewall.@defaults[0].flow_offloading || echo 0)
	st_off_hw=$(uci -q get firewall.@defaults[0].flow_offloading_hw || echo 0)
	# The ifup hook only fires when DEVICE equals settings.wan, so a wrong WAN
	# never starts. Compared with the default route (eth0 can exist and still
	# not be the L3 device on PPPoE).
	local _ct_acct_v; _ct_acct_v=$(_ct_acct)
	local wan_live wan_match="-" _ctm _s
	_ctm=$(_ctmark_users)
	wan_live=$(_wan_live)
	# Match = settings.wan carries an interface that is up: the default route
	# may sit on a VPN, a tunnel or a second line and still shape fine.
	# Mismatch only when netifd says it does not and there is a live line to
	# name; netifd silent = the default-route test as before.
	_wan_l3; _s=$?
	if [ "$_s" = 0 ]; then
		wan_match=1
	elif [ -n "$wan_live" ]; then
		if [ "$_s" = 2 ] && [ "$wan_live" = "$WAN" ]; then wan_match=1; else wan_match=0; fi
	fi

	echo "@@STATE@@"
	echo "version=$VERSION"
	echo "script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")"
	echo "backend_stale=$(_file_drift "/root/$SCRIPT_NAME.sh" "$QOS_EX_BIN")"
	echo "pf_stale=$(_file_drift "/root/$SCRIPT_NAME-PF.sh" "$PF_BIN")"
	# No location service answered the Ping Filter (its geo-svc "down").
	local _pfon _pfgeo=""
	config_get _pfon pingfilter enabled 0
	[ "$ENABLED" = 1 ] && [ "$_pfon" = 1 ] && [ ! -e "$PF_RUN_DIR/.stopped" ] \
		&& [ -r "$PF_RUN_DIR/geo-svc" ] && read -r _pfgeo _ < "$PF_RUN_DIR/geo-svc"
	echo "pf_geo_down=$([ "$_pfgeo" = down ] && echo 1 || echo 0)"
	# A source with no installed copy is what a sysupgrade leaves.
	if [ -f "/root/$SCRIPT_NAME.sh" ] && [ ! -x "$QOS_EX_BIN" ]; then
		echo "backend_missing=1"
	else
		echo "backend_missing=0"
	fi
	echo "qdisc=$QDISC"
	echo "nft_mode=$NFT_MODE"
	# Same token as state(): tells a fresh reply from a cached one.
	echo "cfg_sum=$(md5sum "/etc/config/$UCI_CFG" 2>/dev/null | cut -c1-12)"
	echo "def_tune=$DEF_TUNE_MODE"
	echo "root_tc=$(_root_line "$WAN")|$(_root_line "$IFB")"
	# Class tree, structure only: name|up_kbps|dn_kbps|detail. None under CAKE.
	echo "cls_mode=$QDISC"
	[ "$QDISC" = "cake" ] && echo "cls_tins=$CAKE_PRIO"
	_class_scheme | while IFS='|' read -r _cid _nm _up _dn _det; do
		echo "cls_${_cid}=${_nm}|${_up}|${_dn}|${_det}"
	done
	# leaf_<cid>=<upload>|<download>, a side empty when it has no such leaf.
	{ _leaf_lines "$WAN" | sed 's/^/u /'; _leaf_lines "$IFB" | sed 's/^/d /'; } | awk '
		{ d = $1; k = $2; sub(/^[ud] [0-9]+ /, ""); if (d == "u") U[k] = $0; else D[k] = $0; S[k] = 1 }
		END { for (k = 11; k <= 15; k++) if (k in S) print "leaf_" k "=" U[k] "|" D[k] }'
	echo "wan=$WAN"
	# wan_match: 1 match, 0 mismatch, - undetermined.
	echo "wan_live=$wan_live"
	echo "wan_match=$wan_match"
	# The lan interface's device, for Setup's LAN device field.
	echo "lan_live=$(_lan_dev)"
	echo "ifb=$IFB"
	echo "download_on=$DL_ON"
	# Line and effective rates (the HFSC/HTB ratio cap may lower download).
	echo "ul_kbps_line=$LINE_UP_KBPS"
	echo "dl_kbps_line=$LINE_DN_KBPS"
	echo "ul_kbps_eff=$UPLOAD_KBPS"
	echo "dl_kbps_eff=$DOWNLOAD_KBPS"
	_st_running
	echo "shape_up=$SHAPE_UP"
	echo "shape_dn=$SHAPE_DN"
	echo "running=$_RUN"
	echo "bw_headroom=$BW_HEADROOM"
	echo "bw_ratio=$BW_MAX_RATIO"
	echo "bw_ratio_eff=$BW_RATIO_EFF"
	# Machine-readable copies of the report's figures.
	echo "overhead=$OVERHEAD"
	echo "mpu=$MPU"
	echo "linklayer=$LINKLAYER"
	echo "ack_on=$ACK_ON"
	echo "ack_filter=$ACK_FILTER"
	echo "ack_slow=${SLOW_ACK:-}"
	echo "ack_med=${MED_ACK:-}"
	echo "ack_fast=${FAST_ACK:-}"
	echo "ack_xfast=${XFAST_ACK:-}"
	echo "wash_up=$WASH_UP"
	echo "wash_down=$WASH_DOWN"
	echo "mss_mode=$MSS_MODE"
	echo "mss_gate=$MSS_GATE"
	echo "mss_up=${MSS_UP:-}"
	echo "mss_dn=${MSS_DN:-}"
	echo "game_up=$GAME_UP"
	echo "game_dn=$GAME_DN"
	echo "game_pct=$GAME_PCT"
	echo "game_burst=$GAME_BURST"
	echo "game_floor=$GAME_FLOOR"
	echo "voice_rt=$VOICE_RT"
	echo "bulk_timeout=$BULK_TIMEOUT"
	echo "first_500ms=$FIRST_500MS"
	echo "first_10s=$FIRST_10S"
	echo "udp_fast_pps=$UDP_FAST_PPS"
	echo "udp_fast_burst=$UDP_FAST_BURST"
	echo "udp_small_avgpkt=$UDP_SMALL_AVGPKT"
	echo "slow_flow_pps=$SLOW_FLOW_PPS"
	echo "heavy_flow_pps=$HEAVY_FLOW_PPS"
	echo "mss_rate_up=${MSS_RATE_UP:-}"
	echo "mss_rate_dn=${MSS_RATE_DN:-}"
	echo "nft_tbl=${nft_tbl:-}"
	echo "nft_chains=$nft_chains"
	echo "nft_sets=$nft_sets"
	echo "ifb_filters=$ifb_filters"
	echo "init_enabled=$st_init_en"
	echo "game_qdisc=$HFSC_GAMEQ"
	echo "def_qdisc=$DEFAULT_QDISC"
	if [ -x "$PF_BIN" ]; then echo "pf_installed=1"; else echo "pf_installed=0"; fi
	echo "script_bin=$QOS_EX_BIN"
	echo "pf_bin=$PF_BIN"
	echo "ct_acct=$_ct_acct_v"
	echo "offload_sw=$st_off_sw"
	echo "offload_hw=$st_off_hw"
	echo "ct_mark_users=$_ctm"
	echo "pkg_mgr=${st_mgr:-}"
	echo "pkg_missing=${st_missing:-}"
	if [ "$NFT_MODE" = "adaptive" ]; then
		echo "toggles=gaming_guard:yes,bulk_sticky:$([ "$BULK_TIMEOUT" != 0 ] && echo yes || echo no),p2p:$(_ada_p2p_ok && echo yes || echo no)"
		echo "ada_heavy_pct=$ADA_HEAVY_PCT"
		echo "ada_heavy_secs=$ADA_HEAVY_SECS"
		echo "ada_p2p_rate=$ADA_P2P_RATE"
		echo "ada_vpn_ports=$ADA_VPN_PORTS"
	elif [ "$NFT_MODE" = "simple" ]; then
		echo "toggles=bulk_ports:$SIM_BULK_PORTS,vidconf:$SIM_VIDCONF,gaming_ip:$SIM_GAMING_IP,lowprio_ip:$SIM_LOWPRIO_IP,udp_rate:$SIM_UDP_RATE,tcp_500ms:$SIM_TCP_500MS,tcp_upgrade:$SIM_TCP_UPGRADE,tcp_10s:$SIM_TCP_10S"
	else
		echo "toggles=gaming_ip:$ADV_GAMING_IP,meter_down:$ADV_METER_DOWN,lowprio_ip:$ADV_LOWPRIO_IP,tcp_upgrade:$ADV_TCP_UPGRADE,tcp_10s:$ADV_TCP_10S"
	fi
	echo "http_ports=$HTTP_PORTS"
	echo "vidconf_ports=$VIDCONF_PORTS"
	echo "tcp_bulk=${TCP_BULK:-}"
	echo "udp_bulk=${UDP_BULK:-}"
	echo "gaming_ip4=${GAMING_IP4:-}"
	echo "gaming_ip6=${GAMING_IP6:-}"
	echo "gaming_mac=${GAMING_MAC:-}"
	echo "lowprio_ip4=${LOWPRIO_IP4:-}"
	echo "lowprio_ip6=${LOWPRIO_IP6:-}"
	echo "lowprio_mac=${LOWPRIO_MAC:-}"
	echo "enabled=$ENABLED"
	echo "ifb_up=$st_ifb"
	echo "root_qdisc=$st_root"
	echo "ingress_qdisc=$st_ingress"
	echo "ctinfo=$st_ctinfo"
	echo "nft_table=$st_nft"
	echo "init=$st_init"
	echo "hotplug=$st_hotplug"
	_state_uptime "$_RUN"
	echo "@@STATE_END@@"

	local mpu_disp="$MPU"
	local bw_disp="$BW_MAX_RATIO"
	case "$BW_MAX_RATIO" in
		0|""|off|Off|OFF) bw_disp="off" ;;
		auto|Auto|AUTO)   bw_disp="auto (${BW_RATIO_EFF}x cap, ACK filter ${ACK_ON:-no})" ;;
	esac
	case "$QDISC" in cake) bw_disp="N/A (cake)" ;; esac
	local mss_disp="off"
	if [ "$MSS_MODE" != "off" ]; then
		if [ -z "$MSS_UP" ] && [ -z "$MSS_DN" ]; then
			mss_disp="$MSS_MODE, inactive - both directions are at or above ${MSS_GATE} kbps"
		else
			mss_disp="$MSS_MODE, below ${MSS_GATE} kbps  ->  upload seg <= ${MSS_UP:-unclamped}  download seg <= ${MSS_DN:-unclamped}"
		fi
	fi

	echo ""
	echo "=== $SCRIPT_NAME v$VERSION Status ==="
	echo ""

	echo "--- Configuration ---"
	echo "  Enabled:            $ENABLED"
	if [ "$DL_LAN" = 1 ]; then echo "  Interfaces:         WAN=$WAN  LAN=$IFB (download shaped on its egress)"
	else echo "  Interfaces:         WAN=$WAN  IFB=$IFB"; fi
	echo "  Line rate:          Up ${LINE_UP_KBPS} kbps / Down ${LINE_DN_KBPS} kbps"
	echo "  Bandwidth:          Up ${UPLOAD_KBPS} kbps (${BW_UP_M} Mbps) / Down ${DOWNLOAD_KBPS} kbps (${BW_DN_M} Mbps)"
	[ "$SHAPE_UP" = 0 ] && echo "    Upload:           not shaped (upload_kbps 0)"
	[ "$SHAPE_DN" = 0 ] && echo "    Download:         not shaped (download_kbps 0)"
	echo "    Headroom:         ${BW_HEADROOM}% of line rate"
	echo "    Overhead/MPU:     ${OVERHEAD} / ${mpu_disp}  (link layer ${LINKLAYER})"
	echo "    BW Ratio Cap:     ${bw_disp}"
	echo "  Qdisc:              $QDISC"
	echo "  NFT mode:           $(nft_mode_disp)  (table: inet ${nft_tbl:-<none>})"
	echo "  DSCP Washing:       up=$WASH_UP  down=$WASH_DOWN"
	[ "$QDISC" = "cake" ] && [ "$WASH_DOWN" = "yes" ] && echo "    (cake: device-set DSCP washed in nft before classification)"
	echo "  MSS clamp:          ${mss_disp}"
	echo ""

	case "$QDISC" in
		hfsc|htb)
			local _qu; case "$QDISC" in hfsc) _qu=HFSC ;; htb) _qu=HTB ;; *) _qu="$QDISC" ;; esac
			echo "  Class scheme:       6-class $_qu tree (1:10..1:15)"
			_class_scheme | while IFS='|' read -r _cid _nm _up _dn _det; do
				printf '    1:%s %-9s %s/%s kbps  (%s)\n' "$_cid" "${_nm}:" "$_up" "$_dn" "$_det"
			done
			echo "                      (see Stats tab for live per-class counters)"
			;;
		cake)
			# The LAN device never looks up NAT (setup_cake).
			local _ni="$CAKE_NAT_ING"; [ "$DL_LAN" = 1 ] && _ni="no (LAN device)"
			echo "  CAKE:               priority=${CAKE_PRIO} nat_ingress=${_ni} nat_egress=${CAKE_NAT_EGR}"
			echo "                      host_isolation=${CAKE_HOSTISO} ingress_mode=${CAKE_ING_MODE}"
			[ -n "$CAKE_EXTRA_E" ] && echo "    Extra egress:     ${CAKE_EXTRA_E}"
			[ -n "$CAKE_EXTRA_I" ] && echo "    Extra ingress:    ${CAKE_EXTRA_I}"
			;;
	esac
	echo ""

	echo "  ACK Thinning:       resolved=${ACK_ON}  (ACK_FILTER=${ACK_FILTER})"
	# The auto test reads the headroomed rates before the ratio cap.
	case "$ACK_FILTER" in
		on|off)
			echo "    Forced ${ACK_FILTER} by ack_filter" ;;
		*)
			if [ "$SHAPE_UP" = 0 ]; then
				echo "    Off:              upload not shaped"
			elif [ "$ACK_ON" = "yes" ]; then
				echo "    Threshold:        down ${MSS_RATE_DN:-0} kbps > up ${MSS_RATE_UP:-0} x 14 = $(( ${MSS_RATE_UP:-0} * 14 )) kbps"
			else
				echo "    Threshold:        down ${MSS_RATE_DN:-0} kbps <= up ${MSS_RATE_UP:-0} x 14 = $(( ${MSS_RATE_UP:-0} * 14 )) kbps (not met)"
			fi ;;
	esac
	[ "$ACK_ON" = "yes" ] && echo "    Rates (pps):      slow=${SLOW_ACK} med=${MED_ACK} fast=${FAST_ACK} xfast=${XFAST_ACK}"
	echo ""

	if [ "$NFT_MODE" = "adaptive" ]; then
	echo "  Unlisted TCP:       slow (under ${SLOW_FLOW_PPS} pps) = AF42, busy = CS0, heavy = LE"
	echo "    Heavy = over ${ADA_HEAVY_PCT}% of the direction's shaped rate for ${ADA_HEAVY_SECS}s (one connection, or a device's busy ones together)"
	echo "  Bulk Source Sticky: timeout=${BULK_TIMEOUT}s (0 = off)"
	elif [ "$NFT_MODE" = "advanced" ]; then
	echo "  Web ports:          small (<= ${ADV_SMALL_LEN}B) = CS0, mid-size = AF42, over ${ADV_WEB_PPS} pps = AF11"
	echo "    Web TCP:          heavy > first10s=${FIRST_10S}B ($((FIRST_10S/1024/1024))MB) -> LE + sticky pair, slow (under ${SLOW_FLOW_PPS} pps) -> AF42"
	echo "  Other TCP:          over ${ADV_TCP_PPS} pps = CS0, else AF41 (<= ${ADV_MAX_LEN}B, per connection, reset ${ADV_RESET_PM}/1000)"
	echo "  Other UDP:          over ${ADV_UDP_PPS} pps = AF41, else CS5 (<= ${ADV_MAX_LEN}B)"
	echo "  Bulk Source Sticky: timeout=${BULK_TIMEOUT}s (0 = off)"
	else
	echo "  TCP Flow Thresholds: first500ms=${FIRST_500MS}B ($((FIRST_500MS/1024))KB)  first10s=${FIRST_10S}B ($((FIRST_10S/1024/1024))MB)"
	echo "    Sized from:       download ${DOWNLOAD_KBPS} kbps, at most ${TCP_NEW_CAP} Mbit (first500ms) / ${TCP_BULK_CAP} Mbit (first10s)"
	fi
	echo ""

	echo "  NFT Section Toggles (active mode: $(nft_mode_disp)):"
	if [ "$NFT_MODE" = "adaptive" ]; then
		echo "    Adaptive: decided once per connection; listed = static, the rest re-judged"
		echo "            heavy = over ${ADA_HEAVY_PCT}% of the shaped rate for ${ADA_HEAVY_SECS}s, p2p_rate=${ADA_P2P_RATE}/min ($(_ada_p2p_ok && echo on || echo off)), vpn=${ADA_VPN_PORTS:-none}"
	elif [ "$NFT_MODE" = "simple" ]; then
		echo "    Simple:   bulk_ports=$SIM_BULK_PORTS  vidconf=$SIM_VIDCONF  gaming_ip=$SIM_GAMING_IP  lowprio_ip=$SIM_LOWPRIO_IP  udp_rate=$SIM_UDP_RATE"
		echo "            tcp_500ms=$SIM_TCP_500MS  tcp_upgrade=$SIM_TCP_UPGRADE  tcp_10s=$SIM_TCP_10S"
	else
		echo "    Advanced: gaming_ip=$ADV_GAMING_IP  meter_down=$ADV_METER_DOWN  lowprio_ip=$ADV_LOWPRIO_IP"
		echo "            tcp_upgrade=$ADV_TCP_UPGRADE  tcp_10s=$ADV_TCP_10S"
	fi
	echo "    ack_filter=$ACK_ON  wash_up=$WASH_UP  wash_down=$WASH_DOWN"
	echo ""

	echo "  Priority IPs (UDP):"
	echo "    Gaming:           ${GAMING_IP4:-(none)} / ${GAMING_IP6:-(none)}"
	echo "    Gaming (MAC):     ${GAMING_MAC:-(none)}"
	echo "    LowPrio:          ${LOWPRIO_IP4:-(none)} / ${LOWPRIO_IP6:-(none)}"
	echo "    LowPrio (MAC):    ${LOWPRIO_MAC:-(none)}"
	echo "  Bulk Ports:         TCP=${TCP_BULK:-none}  UDP=${UDP_BULK:-none}"
	echo "  Service Ports:      HTTP=${HTTP_PORTS}  VidConf=${VIDCONF_PORTS}"
	if [ "$NFT_MODE" = "adaptive" ]; then
		echo "  Unlisted flows:     TCP under ${SLOW_FLOW_PPS}pps = AF42, small UDP = CS5, busy TCP = CS0, busy UDP = AF11, heavy = LE"
	elif [ "$NFT_MODE" = "simple" ]; then
		echo "  UDP rate:           a connection over ${UDP_FAST_PPS}pps (burst ${UDP_FAST_BURST}) = AF11 while over and 5s after; EF, LE, CS1 and AF11 kept"
	fi
	echo "    Bulk and VidConf: Simple as port rules, Adaptive as its service map;"
	echo "    Advanced does not read them. Empty list = that class off."
	echo ""

	echo "--- Required Packages ---"
	local p
	if [ -z "$st_mgr" ]; then
		echo "  [--] no package manager found (apk / opkg)"
	else
		for p in $PKG_DEPS_BACKEND; do
			case " $st_missing " in
				*" $p "*) echo "  [--] $p" ;;
				*)        echo "  [ok] $p" ;;
			esac
		done
	fi
	[ -n "$st_missing" ] && echo "  ! Missing: $st_missing"
	echo ""

	echo "--- System Checks ---"
	[ "$st_hotplug" = 1 ] && echo "  [ok] Hotplug installed" || echo "  [--] Hotplug missing"
	if [ "$wan_match" = 0 ]; then
		echo "  [!!] WAN mismatch: $UCI_CFG.settings.wan is '$WAN', which carries no interface that is up;"
		echo "       the default route is via '$wan_live'. The ifup hook never fires for '$WAN' and"
		echo "       forwarded traffic never names it. If '$wan_live' is the line, run:"
		echo "       uci set $UCI_CFG.settings.wan='$wan_live'; uci commit $UCI_CFG; sh QoS-Ex.sh restart"
	elif [ "$wan_match" = 1 ]; then
		echo "  [ok] WAN '$WAN' carries an interface that is up"
		[ -n "$wan_live" ] && [ "$wan_live" != "$WAN" ] && \
			echo "       (the default route is via '$wan_live' - a VPN, tunnel or second line)"
	else
		echo "  [--] Live WAN device undetermined - cannot check $UCI_CFG.settings.wan='$WAN'"
	fi
	if [ "$st_off_sw" = 1 ] || [ "$st_off_hw" = 1 ]; then
		echo "  [!!] Flow offloading is ON (sw=$st_off_sw hw=$st_off_hw) - established"
		echo "       flows bypass nftables, so DSCP classification and every ct rule"
		echo "       stop working. Run: sh QoS-Ex.sh disable_offload"
	fi
	if [ "$_ct_acct_v" = "0" ]; then
		echo "  [!!] nf_conntrack_acct is off - ct bytes cannot be read, so the bulk"
		echo "       thresholds never match. Run: sh QoS-Ex.sh restart"
	fi
	if [ "$MSS_MODE" = "off" ]; then
		# Rate 0 = unshaped, not slow.
		if { [ "${MSS_RATE_UP:-0}" -ge 1 ] && [ "${MSS_RATE_UP:-0}" -lt "${MSS_GATE:-0}" ]; } 2>/dev/null || \
		   { [ "${MSS_RATE_DN:-0}" -ge 1 ] && [ "${MSS_RATE_DN:-0}" -lt "${MSS_GATE:-0}" ]; } 2>/dev/null; then
			echo "  [--] MSS clamp is off and a direction is below ${MSS_GATE} kbps -"
			echo "       set $UCI_CFG.settings.mss=auto to have it clamp that side only"
		fi
	fi
	# nft cannot fold a packet-derived value into part of the mark (the rhs
	# of | must be constant), so this is reported, not worked around.
	for _s in $_ctm; do
		echo "  [!!] $_s is enabled: QoS-Ex rewrites the whole conntrack mark on every"
		echo "       classified packet, which erases $_s's per-connection mark - its"
		echo "       routing choices will not hold while both run"
	done
	[ "$(_file_drift "/root/$SCRIPT_NAME.sh" "$QOS_EX_BIN")" = 1 ] && \
		echo "  [!!] /root/$SCRIPT_NAME.sh differs from $QOS_EX_BIN - reload/restart rebuild from the INSTALLED copy; run: sh QoS-Ex.sh install"
	[ "$(_file_drift "/root/$SCRIPT_NAME-PF.sh" "$PF_BIN")" = 1 ] && \
		echo "  [!!] /root/$SCRIPT_NAME-PF.sh differs from $PF_BIN - run: sh QoS-Ex-PF.sh install"
	if [ "$st_init" = 1 ]; then
		[ "$st_init_en" = 1 ] && echo "  [ok] Init enabled" || echo "  [ok] Init installed (not enabled)"
	else
		echo "  [--] Init missing"
	fi
	if [ "$st_nft" = 1 ]; then
		echo "  [ok] NFT table 'inet $nft_tbl' ($nft_chains chains, $nft_sets sets)"
	else
		echo "  [--] NFT table 'inet ${nft_tbl:-<none>}' not loaded"
	fi
	if [ "$SHAPE_UP" = 0 ]; then
		echo "  [ok] upload not shaped - no root qdisc on $WAN"
	else
		[ "$st_root"    = 1 ] && echo "  [ok] $WAN root qdisc active"    || echo "  [--] $WAN no root qdisc"
	fi
	if [ "$SHAPE_DN" = 0 ]; then
		echo "  [ok] download not shaped - no IFB, ingress or ctinfo"
	else
		[ "$st_ifb"     = 1 ] && echo "  [ok] $IFB present"              || echo "  [--] $IFB missing"
		if [ "$DL_LAN" = 1 ]; then
			[ "$st_ingress" = 1 ] && echo "  [ok] $IFB clsact (egress hook)" || echo "  [--] $IFB clsact missing"
		else
			[ "$st_ingress" = 1 ] && echo "  [ok] $WAN ingress qdisc"        || echo "  [--] $WAN ingress missing"
		fi
		[ "$st_ctinfo"  = 1 ] && echo "  [ok] ctinfo filter active"      || echo "  [--] ctinfo filter missing"
		# CAKE reads the DSCP itself: only HFSC / HTB classify on the IFB.
		if [ "$st_ifb" = 1 ] && [ "$QDISC" != cake ]; then
			[ "$ifb_filters" -gt 0 ] && echo "  [ok] $IFB filters: $ifb_filters" || echo "  [--] $IFB no filters"
		fi
	fi
	echo ""

	echo "--- Overall ---"
	if [ "$_RUN" = 1 ]; then
		echo "  [ok] $SCRIPT_NAME is RUNNING"
	else
		echo "  [--] $SCRIPT_NAME is NOT running"
	fi
	echo ""
	echo "For live traffic stats: $0 stats"
}

### The "Active ruleset" view: the forward chain and the chains it jumps to;
### setter / drop chains and set definitions are hidden (nftdump_full = all).
nft_filter_chains() {
	awk '
	BEGIN {
		# Every chain a builder emits that holds decisions (not the set_* /
		# to_* / s_* / a_* one-liners or the drop chains). Keep in step with
		# the builders: a key that matches nothing hides that stage.
		show["forward"]=1; show["classify"]=1; show["ack_rules"]=1
		show["mark_500ms"]=1; show["mark_10s"]=1
		show["meter_in"]=1; show["udp_dev"]=1; show["http"]=1; show["tcp_10s"]=1
		show["process_tcp"]=1; show["process_udp"]=1; show["done"]=1
		show["replay"]=1; show["down"]=1; show["decide"]=1; show["auto"]=1
		show["mark_bulk"]=1; show["guard"]=1; show["vguard"]=1
		skip=0; depth=0; inchain=0
	}
	/^table / { next }
	/^[ \t]*(set|map) [a-z0-9_]+ \{/ {
		o=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth=o-c
		skip=(depth > 0) ? 1 : 0
		next
	}
	/^[ \t]*chain [a-z0-9_]+ \{/ {
		name=$0; sub(/^[ \t]*chain /,"",name); sub(/ \{.*/,"",name)
		if (name in show) {
			skip=0; inchain=1
			line=$0; sub(/^\t/,"",line); print line   # dedent one level
		} else {
			o=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth=o-c
			skip=(depth > 0) ? 1 : 0
		}
		next
	}
	skip {
		o=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth += o - c
		if (depth <= 0) skip=0
		next
	}
	/^\}/ { next }
	inchain && /^[ \t]+\}/ { line=$0; sub(/^\t/,"",line); print line; inchain=0; next }
	inchain { line=$0; sub(/^\t/,"",line); print line; next }
	'
}

# Echoes the active table name when it is loaded; else prints why and returns
# 1 (unknown mode) or 2 (table absent).
_nft_ready() {
	# stdout is the table name: load_config's warnings must not join it.
	load_config >/dev/null 2>&1
	local tbl; tbl=$(_nft_table)
	[ -n "$tbl" ] || { echo "unknown nft_mode: $NFT_MODE"; return 1; }
	# The table list, not the table: no set elements to print and discard.
	if ! nft list tables inet 2>/dev/null | grep -qx "table inet $tbl"; then
		echo "(NFT table 'inet $tbl' is not loaded)"
		return 2
	fi
	echo "$tbl"
}

nftdump() {
	local tbl rc
	tbl=$(_nft_ready); rc=$?
	if [ "$rc" -ne 0 ]; then
		[ -n "$tbl" ] && echo "$tbl"
		[ "$rc" -eq 2 ] && return 0
		return 1
	fi
	nft list table inet "$tbl" 2>/dev/null | nft_filter_chains
}

nftdump_full() {
	local tbl rc
	tbl=$(_nft_ready); rc=$?
	if [ "$rc" -ne 0 ]; then
		[ -n "$tbl" ] && echo "$tbl"
		[ "$rc" -eq 2 ] && return 0
		return 1
	fi
	nft list table inet "$tbl" 2>/dev/null
}

nfterr() {
	if [ -f "$NFT_ERR" ]; then
		cat "$NFT_ERR"
	else
		echo "(no recent NFT load error)"
	fi
}

logdump() {
	if [ -f "$RUN_LOG" ]; then
		cat "$RUN_LOG"
	else
		echo "(log empty)"
	fi
}

# Conntrack rows from conntrack(8) or /proc (same key=value fields).
_ct_source() {
	if command -v conntrack >/dev/null 2>&1; then
		conntrack -L -o extended,id 2>/dev/null
	elif [ -r /proc/net/nf_conntrack ]; then
		cat /proc/net/nf_conntrack 2>/dev/null
	fi
}

# ct bytes / packets need the conntrack acct extension; without it they read
# 0 (ct bytes < N then always matches). The kernel turns acct on when such a
# rule loads, but only conntracks created after that carry it, so it is set
# before the ruleset loads.
_ct_acct() {
	local p=/proc/sys/net/netfilter/nf_conntrack_acct
	[ -r "$p" ] || { echo "-"; return 0; }
	cat "$p" 2>/dev/null
}

_ct_acct_on() {
	local p=/proc/sys/net/netfilter/nf_conntrack_acct
	[ -w "$p" ] || return 0
	[ "$(_ct_acct)" = "1" ] && return 0
	echo 1 > "$p" 2>/dev/null && msg "enabled nf_conntrack_acct (ct bytes needs it)"
	return 0
}

conntrack_table() {
	local max="${1:-200}"
	# Into `head -n`: a non-number errors, a negative means "all but N".
	_isnum "$max" && [ "$max" -ge 1 ] || max=200
	# The only verb outside start() that changes kernel state (log only:
	# stdout is the TSV the Flows tab parses).
	_ct_acct_on >/dev/null
	# The fast flags and sticky pairs, so Flows can say why a flow sits where
	# it does: only those sets, of the tables that are loaded (`list sets`
	# printed every element of every meter, megabytes on a busy router, on
	# each poll). awk switches at the marker. nft `ct id` = conntrack `id=`.
	local _tl _tb _s
	_tl=$(nft list tables inet 2>/dev/null)
	{
		for _tb in "$NFT_SIMPLE" "$NFT_ADVANCED" "$NFT_ADAPTIVE"; do
			case "$_tl" in *"table inet $_tb"*) ;; *) continue ;; esac
			# One call per set: nft 1.0.9 fails several `list set` in one.
			for _s in $(nft -t list sets table inet "$_tb" 2>/dev/null | awk '$1 == "set" { print $2 }'); do
				case "$_s" in fast|udp_fast|tcp_fast|bulk_src4|bulk_src6) nft list set inet "$_tb" "$_s" 2>/dev/null ;; esac
			done
		done
		echo '@@CT@@'
		_ct_source
	} | awk '
	BEGIN {
		DSCP[0]="cs0";       DSCP[1]="le";        DSCP[8]="cs1";       DSCP[16]="cs2"
		DSCP[24]="cs3";      DSCP[32]="cs4";      DSCP[40]="cs5"
		DSCP[48]="cs6";      DSCP[56]="cs7"
		DSCP[10]="af11";     DSCP[12]="af12";     DSCP[14]="af13"
		DSCP[18]="af21";     DSCP[20]="af22";     DSCP[22]="af23"
		DSCP[26]="af31";     DSCP[28]="af32";     DSCP[30]="af33"
		DSCP[34]="af41";     DSCP[36]="af42";     DSCP[38]="af43"
		DSCP[44]="voice-admit"
		DSCP[46]="ef"
	}
	!ct {
		if ($0 == "@@CT@@") { ct = 1; next }
		if ($1 == "set") { cur = $2; inel = 0; next }
		if (cur != "udp_fast" && cur != "tcp_fast" && cur != "fast" && cur != "bulk_src4" && cur != "bulk_src6") next
		line = $0
		if (!inel) {
			p = index(line, "elements = ")
			if (!p) next
			inel = 1; line = substr(line, p + 11)
		}
		# An element list wraps over several lines and ends at its brace.
		if (index(line, "}")) inel = 0
		gsub(/[{}]/, " ", line)
		n = split(line, el, ",")
		for (i = 1; i <= n; i++) {
			m = split(el[i], w)
			if (m >= 3 && w[2] == ".") BULK[w[1] " " w[3]] = 1
			else if (m >= 1 && w[1] ~ /^[0-9]+$/) FAST[w[1]] = 1
		}
		next
	}
	{
		fam=""; proto=""; src=""; sport=""; dst=""; dport=""; mark=0
		packets=0; bytes=0; rpackets=0; rbytes=0; np=0; nb=0
		rsrc=""; rdst=""; id=""; st="-"; tmo=0; off=0; unr=0
		if ($1 == "ipv4" || $1 == "ipv6") { fam=$1; proto=$3; tmo=$5; st=$6 }
		else { proto=$1; fam="ipv4"; tmo=$3; st=$4 }
		# TCP carries its state word after the timeout; UDP goes straight to src=.
		if (st !~ /^[A-Z_]+$/) st="-"
		for (i=1; i<=NF; i++) {
			if      ($i ~ /^src=/  && src=="")   { src=substr($i,5) }
			else if ($i ~ /^dst=/  && dst=="")   { dst=substr($i,5) }
			else if ($i ~ /^sport=/&& sport=="") { sport=substr($i,7) }
			else if ($i ~ /^dport=/&& dport=="") { dport=substr($i,7) }
			else if ($i ~ /^mark=/)              { mark=substr($i,6) }
			# Second src=/dst= = the REPLY tuple: reply src is where the flow
			# really lands (the LAN host behind a port forward), reply dst the address
			# it leaves as after masquerade.
			else if ($i ~ /^src=/)               { rsrc=substr($i,5) }
			else if ($i ~ /^dst=/)               { rdst=substr($i,5) }
			else if ($i ~ /^id=/)                { id=substr($i,4) }
			else if ($i == "[OFFLOAD]" || $i == "[HW_OFFLOAD]") { off=1 }
			else if ($i == "[UNREPLIED]")        { unr=1 }
			# A conntrack line carries TWO packets=/bytes= pairs: the original
			# tuple first, then the reply. Taking only the first reported the
			# LAN-to-WAN side, which on a download is the pure-ACK stream --
			# 52 bytes a packet, so a 50 GB film showed as ~1 MiB and the
			# rate column and the bps sort both ranked downloads last. Sum
			# them, which is also what nft ct bytes does with no direction.
			else if ($i ~ /^packets=/) { np++
				if (np==1) packets=substr($i,9)+0; else rpackets=substr($i,9)+0 }
			else if ($i ~ /^bytes=/)   { nb++
				if (nb==1) bytes=substr($i,7)+0;   else rbytes=substr($i,7)+0 }
		}
		if (src ~ /:/) fam="ipv6"
		if (proto=="6")  proto="tcp"
		if (proto=="17") proto="udp"
		if (proto=="1")  proto="icmp"
		if (proto=="58") proto="icmpv6"
		m = 0
		if (mark ~ /^0x/ || mark ~ /^0X/) {
			s = tolower(substr(mark, 3))
			for (j = 1; j <= length(s); j++) {
				c = substr(s, j, 1)
				v = index("0123456789abcdef", c) - 1
				if (v < 0) { m = 0; break }
				m = m * 16 + v
			}
		} else {
			m = mark + 0
		}
		dscp_val = m % 64
		dscp_name = (dscp_val in DSCP) ? DSCP[dscp_val] : ("dscp" dscp_val)
		if (proto=="tcp" || proto=="udp") {
			# Prepend cumulative packets as a sort key so the busiest flows
			# survive the top-N cap below. The live game UDP flow is a single
			# entry among hundreds; emitting in conntrack hash order dropped
			# it past the cap on a busy table (PingFilter never saw this - the
			# pf_flow_counters scan reads every line for the server IP, no cap).
			# sort|head keeps the highest-packet flows; cut strips the key so
			# the 9-field client contract is unchanged.
			# Fields 1-9 of the emitted row are the long-standing client
			# contract and keep their meaning: totals across BOTH directions,
			# same as nft ct bytes with no direction qualifier. Fields 10-11
			# append the ORIGINAL direction alone, which for a LAN-initiated
			# flow is the upload; the client derives download as total minus
			# original. Appending rather than inserting means a client that
			# only knows the 9-field shape still parses correctly.
			# Fields 12-16, appended the same way: reply src, reply dst, TCP
			# state (- for UDP), timeout in seconds, and flag letters (- for
			# none): o offloaded, u unreplied, f in @udp_fast/@tcp_fast,
			# b its address pair is in @bulk_src4/6 (TCP only).
			tot_p = packets + rpackets; tot_b = bytes + rbytes
			fl = ""
			if (off) fl = fl "o"
			if (unr) fl = fl "u"
			if (id != "" && (id in FAST)) fl = fl "f"
			if (proto == "tcp" && ((src " " dst) in BULK)) fl = fl "b"
			if (fl == "") fl = "-"
			if (rsrc == "") rsrc = "-"
			if (rdst == "") rdst = "-"
			# EF UDP (the game) ahead of every other flow: the Overview Gaming
			# traffic tile and game stream read the capped list, and a match
			# just begun has fewer packets than a long download. BusyBox sort
			# on OpenWrt ignores -k and reads the leading number as an int,
			# so the key stays under 2^31.
			key = tot_p; if (key > 999999999) key = 999999999
			if (proto == "udp" && dscp_val == 46) key += 1000000000
			printf "%.0f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", key, proto, src, sport, dst, dport, dscp_name, tot_p+0, tot_b+0, fam, packets+0, bytes+0, rsrc, rdst, st, tmo+0, fl
		}
	}' | sort -k1,1 -rn 2>/dev/null | head -n "$max" | cut -f2-
}

hr_bytes() {
	local b=$1
	if   [ "$b" -ge 1073741824 ] 2>/dev/null; then echo "$((b/1073741824)).$((b%1073741824/107374182))G"
	elif [ "$b" -ge 1048576 ]    2>/dev/null; then echo "$((b/1048576)).$((b%1048576/104858))M"
	elif [ "$b" -ge 1024 ]       2>/dev/null; then echo "$((b/1024))K"
	else echo "${b}B"; fi
}

stats_class_table() {
	local dev=$1 dir=$2
	local names="10:Gaming 11:Voice 12:Video 13:Default 14:Low 15:Bulk"
	echo "=== $dir ($dev) ==="
	printf "%-8s %10s %10s %8s %8s | %-8s %6s %8s | %s\n" \
	       "Class" "Sent" "Packets" "Dropped" "Overlim" "Qdisc" "Qdrop" "Backlog" "Shape"
	local entry cid cname cline bytes pkts drop over qline qtype qdrop back dline curve rt ls sc htbr
	for entry in $names; do
		cid=${entry%%:*}; cname=${entry#*:}
		cline=$(tc -s class show dev "$dev" classid "1:$cid" 2>/dev/null | tr '\n' ' ')
		[ -z "$cline" ] && continue
		bytes=$(echo "$cline" | sed -n 's/.*Sent \([0-9]*\) bytes.*/\1/p')
		pkts=$(echo  "$cline" | sed -n 's/.*bytes \([0-9]*\) pkt.*/\1/p')
		drop=$(echo  "$cline" | sed -n 's/.*dropped \([0-9]*\),.*/\1/p')
		over=$(echo  "$cline" | sed -n 's/.*overlimits \([0-9]*\) .*/\1/p')
		qline=$(tc -s qdisc show dev "$dev" parent "1:$cid" 2>/dev/null | tr '\n' ' ')
		qtype=$(echo "$qline" | sed -n 's/qdisc \([^ ]*\) .*/\1/p')
		qdrop=$(echo "$qline" | sed -n 's/.*dropped \([0-9]*\),.*/\1/p')
		# tc prints whole units as 13Kb / 2Mb, else bytes as 1514b.
		back=$(echo  "$qline" | sed -n 's/.*backlog \([0-9.]*[KMG]\{0,1\}b\).*/\1/p')
		dline=$(tc -d class show dev "$dev" classid "1:$cid" 2>/dev/null | tr '\n' ' ')
		curve=""
		rt=$(echo "$dline" | sed -n 's/.*\(rt m1 [^ ]* d [^ ]* m2 [^ ]*\).*/\1/p')
		ls=$(echo "$dline" | sed -n 's/.*\(ls m1 [^ ]* d [^ ]* m2 [^ ]*\).*/\1/p')
		# tc prints one `sc` curve when rt and ls are equal (Voice, 1:11).
		sc=$(echo "$dline" | sed -n 's/.*\(sc m1 [^ ]* d [^ ]* m2 [^ ]*\).*/\1/p')
		htbr=$(echo "$dline" | sed -n 's/.*\(rate [^ ]* ceil [^ ]*\).*/\1/p')
		[ -n "$rt" ]   && curve="$rt"
		[ -n "$ls" ]   && curve="${curve:+$curve  }$ls"
		[ -n "$sc" ]   && curve="$sc"
		[ -n "$htbr" ] && curve="$htbr"
		printf "%-8s %10s %10s %8s %8s | %-8s %6s %8s | %s\n" \
		       "$cname" "$(hr_bytes "${bytes:-0}")" "${pkts:-0}" "${drop:-0}" "${over:-0}" \
		       "${qtype:-?}" "${qdrop:-0}" "${back:-0b}" "${curve:--}"
	done
	echo ""
}

################################################################################
### MACHINE-READABLE COUNTERS (consumed by the LuCI Stats tab)               ###
################################################################################
# A fenced key=value section at the top of `stats` (as status()'s @@STATE@@),
# stripped by the UI: the graph and the text come from one sample.
#   r=<dir>,<bytes>,<pkts>,<drops>                          root qdisc totals
#   c=<dir>,<classid>,<name>,<bytes>,<pkts>,<drops>,<over>,<backlog>,<blpkts>,
#     <qdrop>,<ecn>,<leaf>                                  hfsc/htb classes
#     qdrop/ecn/leaf are the leaf qdisc's: fq_codel drops at dequeue never
#     reach the class counter. <ecn> empty for a leaf that does not mark;
#     sfq RED marks = prob_mark + forced_mark (+ _head).
#   t=<dir>,<tin>,<bytes>,<pkts>,<drops>,<backlog>          cake tins
# <dir> = up (WAN) or down (IFB). Cumulative; the UI differentiates samples.

# tc prints sizes with a unit near a multiple of 1024 ("13Kb", "1.5Mb"),
# exactly when the queue is non-empty, so never assume a bare integer.
#   sz("1514b") -> 1514   sz("13Kb") -> 13312   sz("0b") -> 0
### LIVE BEGIN: install slices this block, to the END marker, into
### /usr/lib/qos-ex/live.sh for the rpcd shim's `live` method: tc + awk only,
### reading QDISC CAKE_PRIO WAN IFB DL_ON UPLOAD_KBPS DOWNLOAD_KBPS SHAPE_UP
### from the start stamp, so a Stats poll parses no script.
_COUNTERS_SZ='function sz(s,   n, u) {
		n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
		if      (u ~ /^[Kk]/) n *= 1024
		else if (u ~ /^[Mm]/) n *= 1048576
		else if (u ~ /^[Gg]/) n *= 1073741824
		return int(n + 0.5)
	}'

_counters_root() {
	local dev="$1" dir="$2" line
	# Only the FIRST qdisc stanza: one tc, one awk (polled path).
	line=$(tc -s qdisc show dev "$dev" root 2>/dev/null | awk -v dir="$dir" '
		/^qdisc /  { if (n++) exit; kind = $2 }
		$1 == "Sent" {
			b = $2 + 0; p = $4 + 0
			d = $7 + 0
			found = 1
		}
		END {
			if (found) printf "r=%s,%.0f,%.0f,%.0f\n", dir, b, p, d
			if (kind != "") printf "qd_%s=%s\n", dir, kind
		}')
	[ -z "$line" ] && return 0
	echo "$line"
}

# Two tc calls (classes, leaf qdiscs) and one awk pass for the whole tree; a
# leaf is matched to its class by `parent 1:NN`. Class stanzas:
#   class htb 1:10 parent 1:1 prio 0 rate 10Mbit ...
#    Sent 12345 bytes 67 pkt (dropped 0, overlimits 0 requeues 0)
#    backlog 1514b 1p requeues 0
_counters_class() {
	local dev="$1" dir="$2"
	{ tc -s class show dev "$dev"; echo "@@Q"; tc -s qdisc show dev "$dev"; } 2>/dev/null |
	awk -v dir="$dir" "$_COUNTERS_SZ"'
		BEGIN { split("10:Gaming 11:Voice 12:Video 13:Default 14:Low 15:Bulk", W, " ") }
		$1 == "@@Q"   { inq = 1; cur = ""; next }
		inq && /^qdisc / {
			cur = ""
			for (i = 4; i < NF; i++) if ($i == "parent") { cur = $(i + 1); break }
			if (cur != "") lk[cur] = $2
			next
		}
		inq {
			if (cur == "") next
			if ($1 == "Sent") qd[cur] = $7 + 0
			for (i = 1; i < NF; i++) {
				if ($i == "ecn_mark") ec[cur] = $(i + 1) + 0
				else if ($i ~ /^(prob|forced)_mark(_head)?$/) ec[cur] += $(i + 1)
			}
			next
		}
		/^class /     { cur = $3; seen[cur] = 1; next }
		cur == ""     { next }
		$1 == "Sent"  { by[cur] = $2 + 0; pk[cur] = $4 + 0
		                dr[cur] = $7 + 0; ov[cur] = $9 + 0; next }
		$1 == "backlog" { bl[cur] = sz($2); bp[cur] = $3 + 0; next }
		END {
			for (i = 1; i in W; i++) {
				n = index(W[i], ":")
				id = "1:" substr(W[i], 1, n - 1)
				if (!(id in seen)) continue
				printf "c=%s,%s,%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%s,%s\n", dir, id,
					substr(W[i], n + 1), by[id], pk[id], dr[id],
					ov[id], bl[id], bp[id], qd[id],
					(id in ec) ? ec[id] : "", lk[id]
			}
		}'
}

# CAKE tins are a column table. Names come from cake_prio in the UI, not the
# header ("Best Effort" has a space). Only rows after `thresh` are read, so
# the qdisc-level backlog line is not taken for the tin row. Counters add up
# across stanzas (an mq root with a cake per queue).
_counters_cake() {
	local dev="$1" dir="$2"
	tc -s qdisc show dev "$dev" 2>/dev/null | awk -v dir="$dir" "$_COUNTERS_SZ"'
		/^qdisc /   { inc = ($0 ~ /^qdisc cake /); intin = 0; next }
		!inc        { next }
		$1 == "thresh" { intin = 1; if (NF - 1 > nt) nt = NF - 1; next }
		!intin      { next }
		$1 == "pkts"    { for (i = 2; i <= NF; i++) pk[i-2] += $i + 0; next }
		$1 == "bytes"   { for (i = 2; i <= NF; i++) by[i-2] += $i + 0; next }
		$1 == "drops"   { for (i = 2; i <= NF; i++) dr[i-2] += $i + 0; next }
		$1 == "backlog" { for (i = 2; i <= NF; i++) bl[i-2] += sz($i); next }
		END {
			for (i = 0; i < nt; i++)
				printf "t=%s,%d,%.0f,%.0f,%.0f,%.0f\n", dir, i, by[i], pk[i], dr[i], bl[i]
		}'
}

stats_counters() {
	local dev dir
	echo "@@COUNTERS@@"
	echo "ts=$(date +%s)"
	echo "qdisc=$QDISC"
	echo "cake_prio=$CAKE_PRIO"
	echo "wan=$WAN"
	echo "ifb=$IFB"
	echo "download_on=$DL_ON"
	echo "ul_kbps=$UPLOAD_KBPS"
	echo "dl_kbps=$DOWNLOAD_KBPS"
	for dev in "$WAN" "$IFB"; do
		ip link show "$dev" >/dev/null 2>&1 || continue
		if [ "$dev" = "$WAN" ]; then dir=up; else dir=down; fi
		[ "$dir" = up ] && [ "$SHAPE_UP" = 0 ] && continue
		_counters_root "$dev" "$dir"
		case "$QDISC" in
			cake) _counters_cake  "$dev" "$dir" ;;
			*)    _counters_class "$dev" "$dir" ;;
		esac
	done
	echo "@@COUNTERS_END@@"
}
### LIVE END

# Counters only, for the Stats graphs: stats() adds a report that costs ~30
# forks per device on HFSC/HTB.
counters() {
	_LOG_QUIET=1
	load_config
	calc_bandwidth
	stats_counters
}

stats() {
	_LOG_QUIET=1
	load_config
	calc_bandwidth   # derive GAME_UP/GAME_DN from the loaded rates
	stats_counters
	echo "=== $SCRIPT_NAME v$VERSION — stats (qdisc=$QDISC) ==="
	echo ""
	local active=0
	tc qdisc show dev "$WAN" 2>/dev/null | grep -qE 'cake|hfsc|htb' && active=1
	[ "$SHAPE_UP" = 0 ] && tc qdisc show dev "$IFB" 2>/dev/null | grep -qE 'cake|hfsc|htb' && active=1
	if [ "$active" = "0" ]; then
		echo "QoS-Ex is not running. Turn the Shaper on in the Overview (Restart if it is on) or run: $QOS_EX_BIN enable"
		return 0
	fi
	case "$QDISC" in
		hfsc|htb)
			local _qdesc=""
			case "$HFSC_GAMEQ" in
				pfifo)    _qdesc="min=${HFSC_PFMIN}p pkt=${HFSC_PKTSZ}B delay=${HFSC_MAXDLY}ms" ;;
				bfifo)    _qdesc="min=${HFSC_BF_MIN}B delay=${HFSC_MAXDLY}ms × rate" ;;
				sfq)      _qdesc="perturb=${HFSC_SFQ_PERTURB}s quantum=${HFSC_SFQ_QUANTUM}B" ;;
				fq_codel) _qdesc="limit=${HFSC_FQ_LIMIT} flows=${HFSC_FQ_FLOWS} q=${HFSC_FQ_QUANTUM} tgt=${HFSC_FQ_TARGET}ms ivl=${HFSC_FQ_INTERVAL}ms" ;;
			esac
			echo "  Gaming RT class:    ${GAME_UP}/${GAME_DN} kbps up/down  |  ${HFSC_GAMEQ} (${_qdesc})"

			for dev in "$WAN" "$IFB"; do
				ip link show "$dev" >/dev/null 2>&1 || continue
				local qstats
				qstats=$(tc -s qdisc show dev "$dev" parent 1:10 2>/dev/null)
				[ -z "$qstats" ] && continue
				local qtype
				qtype=$(echo "$qstats" | head -1 | sed 's/qdisc \([^ ]*\) .*/\1/')
				local qconf
				qconf=$(echo "$qstats" | head -1 | sed 's/.*parent 1:10 //')
				qconf=$(echo "$qconf" | grep -oE 'limit [0-9]+[pb]?' | head -1)
				local sent_b
				sent_b=$(echo "$qstats" | grep -oE 'Sent [0-9]+ bytes' | grep -oE '[0-9]+' | head -1)
				local sent_p
				sent_p=$(echo "$qstats" | grep -oE '[0-9]+ pkt' | grep -oE '[0-9]+' | head -1)
				local drop
				drop=$(echo "$qstats"   | grep -oE 'dropped [0-9]+'    | grep -oE '[0-9]+' | head -1)
				local over
				over=$(echo "$qstats"   | grep -oE 'overlimits [0-9]+' | grep -oE '[0-9]+' | head -1)
				printf "    %-15s %-8s %-15s  Sent: %sB %sp (drop=%s over=%s)\n" \
					"${dev}:" "$qtype" "${qconf:--}" \
					"${sent_b:-0}" "${sent_p:-0}" "${drop:-0}" "${over:-0}"
			done
			echo ""

			[ "$SHAPE_UP" = 1 ] && stats_class_table "$WAN" "UPLOAD"
			ip link show "$IFB" >/dev/null 2>&1 && stats_class_table "$IFB" "DOWNLOAD"

			# Gaming class first, then the default leaves: what tc holds, not
			# what the config asked for (Auto differs per direction).
			local _ddesc=""
			if [ "${DEF_TUNE_MODE:-auto}" != "manual" ]; then
				_ddesc="auto-tuned from link rate"
			else
			case "${DEFAULT_QDISC:-fq_codel}" in
				sfq)
					_ddesc="limit=${DEF_SFQ_LIMIT} depth=${DEF_SFQ_DEPTH} divisor=${DEF_SFQ_DIVISOR}"
					_ddesc="$_ddesc flows=${DEF_SFQ_FLOWS} q=${DEF_SFQ_QUANTUM}B perturb=${DEF_SFQ_PERTURB}s"
					[ "${DEF_SFQ_HEADDROP:-no}" = "yes" ] && _ddesc="$_ddesc headdrop"
					;;
				fq_codel|*)
					_ddesc="limit=${DEF_FQ_LIMIT} flows=${DEF_FQ_FLOWS} q=${DEF_FQ_QUANTUM}B"
					_ddesc="$_ddesc tgt=${DEF_FQ_TARGET}ms ivl=${DEF_FQ_INTERVAL}ms mem=${DEF_FQ_MEMORY_MB}mb ${DEF_FQ_ECN:-ecn}"
					;;
			esac
			fi
			echo "  Default classes:    1:11-1:15  |  ${DEFAULT_QDISC:-fq_codel} (${_ddesc})"
			for dev in "$WAN" "$IFB"; do
				ip link show "$dev" >/dev/null 2>&1 || continue
				local dline
				dline=$(_leaf_lines "$dev")
				[ -n "$dline" ] || continue
				echo "    ${dev}:"
				echo "$dline" | awk '
					BEGIN { N[11] = "Voice"; N[12] = "Video"; N[13] = "Default"; N[14] = "Low"; N[15] = "Bulk" }
					{ c = $1; sub(/^[0-9]+ /, ""); printf "      1:%-3s %-8s %s\n", c, N[c], $0 }'
			done
			echo ""
			;;
		cake|*)
			# Only the `qdisc cake` stanza, no clsact / ingress.
			if [ "$SHAPE_UP" = 1 ]; then
				echo "--- Egress ($WAN) ---"
				tc -s qdisc show dev "$WAN" 2>/dev/null | awk '/^qdisc /{p=($0 ~ /^qdisc cake /)} p'
				echo ""
			fi
			if ip link show "$IFB" >/dev/null 2>&1; then
				echo "--- Ingress ($IFB) ---"
				tc -s qdisc show dev "$IFB" 2>/dev/null | awk '/^qdisc /{p=($0 ~ /^qdisc cake /)} p'
				echo ""
			fi
			;;
	esac
}

################################################################################
### PACKAGES — the install code itself is in lib/install.sh                  ###
################################################################################
# Runtime dependencies: with _pkg_have() and install_pkgs() the only
# package-manager surface. The Makefile reads this list for DEPENDS: keep it
# one quoted line.
PKG_DEPS_BACKEND="tc-full kmod-sched kmod-sched-cake kmod-sched-ctinfo kmod-ifb ip-full conntrack coreutils-timeout tcpdump-mini"

# apk first: some 25.12+ builds also ship an opkg shim.
# A package that stands in for a dependency, as "dep:other": full tcpdump
# ships the same binary and conflicts with tcpdump-mini.
PKG_ALT="tcpdump-mini:tcpdump"
_pkg_have() {   # $1 = apk|opkg   $2 = package
	local _p _a
	for _a in "$2:$2" $PKG_ALT; do
		[ "${_a%%:*}" = "$2" ] || continue
		_p=${_a#*:}
		case "$1" in
			opkg) opkg list-installed 2>/dev/null | grep -q "^$_p " && return 0 ;;
			apk)  apk info -e "$_p" >/dev/null 2>&1 && return 0 ;;
		esac
	done
	return 1
}

# The missing PKG_DEPS_BACKEND entries, space separated, from ONE
# package-manager call (status() is polled).
# shellcheck disable=SC2086  # PKG_DEPS_BACKEND is a constant word list: argv
_pkg_missing() {   # $1 = apk|opkg
	local _have
	case "$1" in
		opkg) _have=$(opkg list-installed 2>/dev/null | awk '{ print $1 }') ;;
		apk)  _have=$(apk info -e $PKG_DEPS_BACKEND ${PKG_ALT##*:} 2>/dev/null) ;;
		*)    return 1 ;;
	esac
	printf '%s\n' "$_have" | awk -v want="$PKG_DEPS_BACKEND" -v alt="$PKG_ALT" '
		{ H[$1] = 1 }
		END {
			m = split(alt, P, " ")
			for (i = 1; i <= m; i++) { split(P[i], q, ":"); if (q[2] in H) H[q[1]] = 1 }
			n = split(want, W, " "); o = ""
			for (i = 1; i <= n; i++) if (!(W[i] in H)) o = o (o == "" ? "" : " ") W[i]
			print o
		}'
}

_pkg_mgr() {
	if   command -v apk  >/dev/null 2>&1; then echo apk
	elif command -v opkg >/dev/null 2>&1; then echo opkg
	else echo ""; return 1; fi
}

resolve_self_path() {
	local s="$0" r=""
	r="$(readlink -f "$s" 2>/dev/null)"
	if [ -n "$r" ] && [ -f "$r" ]; then echo "$r"; return 0; fi
	case "$s" in
		/*) [ -f "$s" ] && { echo "$s"; return 0; } ;;
		*)  # relative — anchor to CWD
		    r="$(pwd)/$s"
		    [ -f "$r" ] && { echo "$r"; return 0; } ;;
	esac
	# Last resort when $0 resolves to nothing. Never CWD: the result is
	# chmod'd by install_all and removed by uninstall.
	for r in "$QOS_EX_BIN" "/root/QoS-Ex.sh"; do
		[ -f "$r" ] && { echo "$r"; return 0; }
	done
	echo "$s"
	return 1
}

# lib/install.sh: install, uninstall, migrate, autostart and the emitters,
# loaded only by the verbs that use them, so the polled verbs never parse it.
# The installed backend reads $QX_LIB; a copy run from /root or a checkout
# reads the lib/ beside it, never an older installed one. $1 = fetch: a
# QoS-Ex-install.sh from before lib/ fetched the scripts only; the new one it
# left beside us fetches the lot (-n: download only, installs nothing).
QX_LIB="/usr/lib/qos-ex/install.sh"
# The live counters block (### LIVE markers above), sliced here at install
# for the rpcd shim (lib/install.sh writes and removes it).
# shellcheck disable=SC2034
QX_LIVE="/usr/lib/qos-ex/live.sh"
_lib_install() {
	local s d
	s=$(resolve_self_path); d=${s%/*}
	_QX_LIB="$d/lib/install.sh"
	[ "$s" = "$QOS_EX_BIN" ] && _QX_LIB="$QX_LIB"
	[ ! -f "$_QX_LIB" ] && [ "${1:-}" = fetch ] && [ -f "$d/QoS-Ex-install.sh" ] &&
		sh "$d/QoS-Ex-install.sh" -n </dev/null >/dev/null 2>&1
	[ -f "$_QX_LIB" ] || { err "$_QX_LIB missing - run: sh /root/QoS-Ex-install.sh"; return 1; }
	. "$_QX_LIB"
}

################################################################################
### PING FILTER DELEGATION                                                   ###
################################################################################
# The Ping Filter is its own backend at $PF_BIN. The shaper only delegates
# lifecycle calls; without it everything here is a silent no-op.
PF_BIN="/usr/sbin/qos-ex-pf.sh"

_pf_delegate() {
	[ -x "$PF_BIN" ] || return 0
	# fd 9 / 8 closed: a daemon forked here must not hold the lifecycle or
	# the master lock.
	"$PF_BIN" "$@" 9>&- 8>&-
}

pf_start() {
	[ -x "$PF_BIN" ] || return 0
	[ "$(uci -q get "$UCI_CFG.pingfilter.enabled")" = "1" ] || return 0
	mkdir -p "$PF_RUN_DIR" 2>/dev/null
	_pf_delegate start
}
pf_stop()   { _pf_delegate stop; }
pf_reload() { _pf_delegate reload; }

# Every Save & Apply reaches reload(), and a PF reload re-grades every cached
# server (can cut one that is not being played). So PF is reloaded only when
# what it reads moved: its section, the device lists, the master switch or
# the WAN. PF's own verbs reload it themselves. Left out: the whitelist /
# blacklist (only PF's verbs and its daemon's auto-pin write them, and apply
# them as they do).
PF_SIG="/var/run/qos-ex-pf.sig"
_pf_sig() {
	{
		uci -q show "$UCI_CFG.pingfilter" | grep -vE '^[^=]*\.(whitelist|blacklist)='
		uci -q show "$UCI_CFG.ips"
		echo "$ENABLED|$WAN"
	} 2>/dev/null | _hash_short
}
_pf_sync() {
	local _sig _was=""
	if [ "$(uci -q get "$UCI_CFG.pingfilter.enabled")" != "1" ]; then
		rm -f "$PF_SIG" 2>/dev/null
		pf_stop   # disabled: tear the daemon + rules down on reload too
		return 0
	fi
	_sig=$(_pf_sig)
	[ -r "$PF_SIG" ] && read -r _was < "$PF_SIG"
	if [ -n "$_sig" ] && [ "$_sig" = "$_was" ] && [ -s "$PF_PID_FILE" ]; then
		log "PingFilter settings unchanged - left running"
		return 0
	fi
	pf_reload
	# Taken again: a reload can itself commit (PF turned off when a device or
	# the home is missing), and the next reload must not see that as a
	# change.
	_pf_sig > "$PF_SIG" 2>/dev/null
	return 0
}

################################################################################
### DIAGNOSTICS: flow-offload guard + debug report                           ###
################################################################################
# Flow offloading bypasses conntrack / nftables for established flows: DSCP
# classification and Ping Filter discovery break.

_fw_reload() {
	if [ -x /etc/init.d/firewall ]; then
		/etc/init.d/firewall reload >/dev/null 2>&1
	elif command -v fw4 >/dev/null 2>&1; then
		fw4 reload >/dev/null 2>&1
	fi
}

# The offload switches as found, so disable and uninstall can put them back.
# Written once, on the first change.
OFFLOAD_PREV="/etc/qos-ex/offload.prev"

# Both offloads off, then reload the firewall. Called by enable, not install.
qos_ex_disable_offload() {
	local _sw _hw
	_sw=$(uci -q get firewall.@defaults[0].flow_offloading)
	_hw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
	if [ "$_sw" != "1" ] && [ "$_hw" != "1" ]; then
		msg "flow offloading already off"
		return 0
	fi
	mkdir -p "${OFFLOAD_PREV%/*}" 2>/dev/null
	[ -f "$OFFLOAD_PREV" ] || echo "${_sw:-0} ${_hw:-0}" > "$OFFLOAD_PREV" 2>/dev/null
	uci -q set firewall.@defaults[0].flow_offloading=0
	uci -q set firewall.@defaults[0].flow_offloading_hw=0
	uci -q commit firewall
	_fw_reload
	msg "flow offloading disabled (software + hardware) and firewall reloaded"
}

# Put offloading back as found. Nothing recorded = nothing to do.
qos_ex_restore_offload() {
	local _sw="" _hw=""
	[ -r "$OFFLOAD_PREV" ] || return 0
	read -r _sw _hw < "$OFFLOAD_PREV"
	rm -f "$OFFLOAD_PREV" 2>/dev/null
	[ "$_sw" = 1 ] || [ "$_hw" = 1 ] || return 0
	[ "$_sw" = 1 ] && uci -q set firewall.@defaults[0].flow_offloading=1
	[ "$_hw" = 1 ] && uci -q set firewall.@defaults[0].flow_offloading_hw=1
	uci -q commit firewall
	_fw_reload
	msg "flow offloading restored (software=${_sw:-0} hardware=${_hw:-0})"
}

# One forum-pasteable debug report. Changes nothing. Scrubbed before printing:
#   - home_lat / home_lon and the home location line
#   - geoip_api (an endpoint of your own may carry a key)
#   - this router's public IPv4s -> <wan-ip>
#   - RFC1918 / CGNAT / ULA / link-local -> <lan-ip> / <cgnat-ip> /
#     <ula-ip6> / <ll-ip6>
#   - public gaming / low-priority device IPv4s -> <device-ip>
#   - the hostname (unless it is the stock OpenWrt, or holds a character
#     no hostname can: anything but A-Z a-z 0-9 . _ -) -> <hostname>
#   - every address in this router's global IPv6 /48s and the device IPv6
#     entries -> <ip6>
#   - MAC addresses (colon, dash or dot form) -> <mac>
# NOT redacted: the remote (non-RFC1918) end of every conntrack row.
_argc() { echo $#; }

# The settings part of the report: the six that frame it (on/off, WAN, queue
# type, rule set, both rates) and PF on/off always; any other option only when
# it differs from emit_uci_config's default AND its section is in use:
#   cake = CAKE; hfsc = HFSC and HTB (leaf queues); htb = HTB; advanced /
#   simple = that rule set; pingfilter = PF on; settings, ports, ips = always.
# The closing line counts what was left out.
debug_settings() {
	local d q n pf
	d=$(mktemp -d /tmp/qos-ex-dbg.XXXXXX 2>/dev/null) || { uci show "$UCI_CFG" 2>/dev/null; return; }
	emit_uci_config > "$d/$UCI_CFG" 2>/dev/null
	uci -q -c "$d" show "$UCI_CFG" > "$d/def" 2>/dev/null
	q=$(uci -q get "$UCI_CFG.settings.qdisc")
	n=$(uci -q get "$UCI_CFG.settings.nft_mode")
	pf=$(uci -q get "$UCI_CFG.pingfilter.enabled")
	uci show "$UCI_CFG" 2>/dev/null | awk -v df="$d/def" -v q="${q:-cake}" -v n="${n:-adaptive}" -v pf="${pf:-0}" '
	BEGIN {
		while ((getline l < df) > 0) D[l] = 1
		m = split("settings.enabled settings.wan settings.qdisc settings.nft_mode settings.upload_kbps settings.download_kbps pingfilter.enabled", a, " ")
		for (i = 1; i <= m; i++) K[a[i]] = 1
		U["settings"] = 1; U["ports"] = 1; U["ips"] = 1
		if (q == "cake") U["cake"] = 1; else U["hfsc"] = 1
		if (n == "simple") U["simple"] = 1; else U["advanced"] = 1
		if (n == "adaptive") U["adaptive"] = 1
		if (pf == "1") U["pingfilter"] = 1
		shown = 0; same = 0; off = 0
	}
	{
		k = $0; sub(/=.*/, "", k); sub(/^[^.]*\./, "", k)
		s = k; sub(/\..*/, "", s)
		if (k == s) next
		if (k in K) { print; shown++; next }
		if (!(s in U)) { if (!($0 in D)) off++; next }
		if ($0 in D) same++; else { print; shown++ }
	}
	END {
		printf "(%d shown; %d more in use are at their defaults", shown, same
		if (off) printf "; %d changed in parts that are switched off", off
		print ")"
	}'
	rm -rf "$d"
}

qos_ex_debug() {
	load_config 2>/dev/null
	calc_bandwidth 2>/dev/null
	local _a _h _x _rx
	# argv, not a string split at the pipe: expressions contain spaces. ERE
	# only: musl's regcomp has no \| or \b, so every address pattern carries
	# its own boundaries (\1 ... \2) and runs twice: neighbours share one.
	set --
	# This router's public IPv4s: every global one, not only $WAN's (MAP-E, a
	# second line, a routed block). Private and CGNAT ones are left to the
	# range patterns below.
	for _a in $(ip -4 addr show scope global 2>/dev/null | awk '$1 == "inet" { sub(/\/.*/, "", $2); print $2 }'); do
		case "$_a" in
			''|*[!0-9.]*|10.*|192.168.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) continue ;;
		esac
		_x=$(echo "$_a" | sed 's/\./\\./g')
		_rx="s/(^|[^0-9.])$_x([^0-9]|\$)/\\1<wan-ip>\\2/g"
		set -- "$@" -e "$_rx" -e "$_rx"
	done
	set -- "$@" -e 's/(home_lat=).*/\1<redacted>/' \
	            -e 's/(home_lon=).*/\1<redacted>/' \
	            -e 's/(geoip_api=).*/\1<redacted>/' \
	            -e 's/(home location:).*/\1 <redacted>/' \
	            -e 's/([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/<mac>/g' \
	            -e 's/([0-9A-Fa-f]{4}\.){2}[0-9A-Fa-f]{4}/<mac>/g'
	for _rx in \
		's/(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)/\1<lan-ip>\2/g' \
		's/(^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)/\1<lan-ip>\2/g' \
		's/(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)/\1<lan-ip>\3/g' \
		's/(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)/\1<cgnat-ip>\3/g'; do
		set -- "$@" -e "$_rx" -e "$_rx"
	done
	set -- "$@" -e 's/(^|[^0-9a-fA-F:])[fF][cCdD][0-9a-fA-F]{2}:[0-9a-fA-F:]*/\1<ula-ip6>/g' \
	            -e 's/(^|[^0-9a-fA-F:])[fF][eE]80:[0-9a-fA-F:]*/\1<ll-ip6>/g'
	# A public address entered as a gaming / low-priority device.
	for _a in $GAMING_IP4 $LOWPRIO_IP4; do
		_a=${_a%%/*}
		case "$_a" in ''|*[!0-9.]*) continue ;; esac
		_x=$(echo "$_a" | sed 's/\./\\./g')
		_rx="s/(^|[^0-9.])$_x([^0-9]|\$)/\\1<device-ip>\\2/g"
		set -- "$@" -e "$_rx" -e "$_rx"
	done
	# The hostname: a safety net (uname -srvm and the log lines leave it out).
	# The stock "OpenWrt" names no one.
	_h=$(cat /proc/sys/kernel/hostname 2>/dev/null)
	case "$_h" in
		''|OpenWrt|*[!A-Za-z0-9._-]*) ;;
		*) _x=$(echo "$_h" | sed 's/\./\\./g')
		   _rx="s/(^|[^A-Za-z0-9_-])$_x([^A-Za-z0-9_-]|\$)/\\1<hostname>\\2/g"
		   set -- "$@" -e "$_rx" -e "$_rx" ;;
	esac
	# Global IPv6: each held address's /48 (first three groups when written
	# out, else the address), so LAN devices in any of the delegated /64s are
	# covered, plus the configured device addresses.
	local _p6
	for _p6 in $(ip -6 addr show scope global 2>/dev/null | awk '
			$1 == "inet6" { sub(/\/.*/, "", $2); n = split($2, g, ":")
				if ($2 ~ /^[fF][cCdD]/) next
				if (n >= 4 && g[1] != "" && g[2] != "" && g[3] != "")
					print g[1] ":" g[2] ":" g[3] ":"
				else print $2 }' | sort -u) $GAMING_IP6 $LOWPRIO_IP6; do
		_p6=${_p6%%/*}
		case "$_p6" in ''|*[!0-9A-Fa-f:]*) continue ;; esac
		set -- "$@" -e "s/${_p6}[0-9a-fA-F:]*/<ip6>/g"
	done
	{
	echo "=================================================================="
	echo " $SCRIPT_NAME debug report — $(date)"
	echo "=================================================================="
	# By module: LuCI app (1.x), Ping Filter (2.x), shaper (3.x).
	echo "--- versions ---"
	_t=$(sed -n '1s/.*qos-ex-luci \(v[0-9.]*\).*/\1/p' /www/luci-static/resources/qos-ex/qos-ex.css 2>/dev/null)
	echo "LuCI app: ${_t:-(not installed)}"
	[ -x "$PF_BIN" ] && echo "PingFilter: $("$PF_BIN" version 2>/dev/null)"
	echo "QoS-Ex: v$VERSION"
	echo "--- system ---"
	echo "model: $(cat /tmp/sysinfo/model 2>/dev/null)"
	grep -E 'DISTRIB_(DESCRIPTION|RELEASE|ARCH)' /etc/openwrt_release 2>/dev/null
	# -srvm: everything -a prints except the hostname.
	uname -srvm 2>/dev/null
	# Addresses and MACs are scrubbed below, so say how many there are.
	echo "--- gaming devices ---"
	echo "$(_argc $GAMING_MAC) by MAC, $(_argc $GAMING_IP4) by IPv4, $(_argc $GAMING_IP6) by IPv6"
	echo "--- low-priority devices ---"
	echo "$(_argc $LOWPRIO_MAC) by MAC, $(_argc $LOWPRIO_IP4) by IPv4, $(_argc $LOWPRIO_IP6) by IPv6"
	echo "--- settings (changed from the defaults, parts in use; home location redacted) ---"
	debug_settings
	echo "--- flow offloading ---"
	echo "software: $(uci -q get firewall.@defaults[0].flow_offloading || echo 0)  hardware: $(uci -q get firewall.@defaults[0].flow_offloading_hw || echo 0)"
	echo "--- tc qdisc ($WAN + $IFB) ---"
	tc -s qdisc show dev "$WAN" 2>/dev/null
	tc -s qdisc show dev "$IFB" 2>/dev/null
	echo "--- tc ingress filter ($WAN, ctinfo restore stats) ---"
	_t=$(tc -s filter show dev "$WAN" parent ffff: 2>/dev/null)
	[ -n "$_t" ] && echo "$_t" || echo "(no ingress filter)"
	echo "--- conntrack (top 30 by packets) ---"
	# conntrack_table parses the fields properly (raw sort keys shift).
	# conntrack_table's status is cut's: test the source instead.
	if command -v conntrack >/dev/null 2>&1 || [ -r /proc/net/nf_conntrack ]; then
		conntrack_table 30 2>/dev/null
	else
		echo "(conntrack not readable)"
	fi
	echo "--- pingfilter status ---"
	[ -x "$PF_BIN" ] && "$PF_BIN" status 2>/dev/null || echo "(pingfilter not installed)"
	echo "--- $RUN_LOG (last 40) ---"
	tail -40 "$RUN_LOG" 2>/dev/null || echo "(empty)"
	echo "--- nft errors ---"
	tail -10 "$NFT_ERR" 2>/dev/null
	tail -10 "$PF_NFT_ERR" 2>/dev/null
	echo "=================================================================="
	echo " end of report — paste this whole block into the Debug report box"
	echo " of a GitHub issue: https://github.com/choppyc79/QoS-Ex/issues/new/choose"
	echo "=================================================================="
	} | sed -E "$@"
}


################################################################################
### MAIN                                                                     ###
################################################################################
case "${1:-help}" in
	start)     start ;;
	stop)      stop ;;
	enable)    _lib_install && master_enable ;;
	disable)   _lib_install && master_disable ;;
	# stop's status is ignored (nothing to tear down is fine); start's is not.
	restart)   stop; _init_owns || sleep 1; start || exit 1 ;;
	reload)    reload ;;
	status)    status ;;
	state)     state ;;
	stats)     stats ;;
	counters)  counters ;;
	nftdump)   nftdump ;;
	nftdump_full) nftdump_full ;;
	nfterr)    nfterr ;;
	logdump)   logdump ;;
	conntrack) conntrack_table "${2:-200}" ;;
	debug)     _lib_install && qos_ex_debug ;;
	disable_offload) qos_ex_disable_offload ;;
	pingfilter|pf)
		shift
		[ -x "$PF_BIN" ] && exec "$PF_BIN" "$@"
		err "PingFilter backend not installed — run: sh QoS-Ex-PF.sh install"
		exit 1
		;;
	install)   _lib_install fetch && install_all ;;
	install_uci) _lib_install && install_uci ;;
	migrate)   load_config || exit 1; _lib_install && uci_migrate ;;
	install_hotplug)   _lib_install && install_hotplug ;;
	remove_hotplug)    _lib_install && remove_hotplug ;;
	enable_autostart)  _lib_install && enable_autostart ;;
	disable_autostart) _lib_install && disable_autostart ;;
	uninstall) _lib_install && uninstall_all "${2:-}" ;;
	autosetup) shift; _lib_install && autosetup_main "$@" ;;
	tcplan)    tcplan ;;
	version)   echo "$SCRIPT_NAME v$VERSION" ;;
	*)
		cat <<EOF
$SCRIPT_NAME v$VERSION — QoS-Ex Unified Shaper (CAKE / HFSC / HTB)
Usage: $0 {start|stop|restart|reload|enable|disable|status|stats|install|uninstall|version}

Installed by running this script over SSH, or from the package (docs/BUILD.md).
Keep all three scripts (QoS-Ex.sh, QoS-Ex-PF.sh, QoS-Ex-luci-app.sh),
lib/install.sh and qos-ex-luci.tar.gz (the LuCI app's files) in /root:
'sh QoS-Ex.sh install' pulls in the other two automatically;
'sh /root/QoS-Ex-install.sh' fetches them all.

Configuration lives in UCI: /etc/config/$UCI_CFG
Edit directly, via 'uci set', or via the LuCI web app.

Commands:
  install    Install/refresh everything: deps (apk/opkg), config, procd init,
             hotplug, PingFilter and the LuCI app. Safe to re-run to upgrade.
  migrate    Add any config key added since your install, without touching
             values you set (run after upgrading the script)
  uninstall  Removes QoS-Ex: files, config, caches, logs, firewall rules;
             installed packages stay, flow offloading goes back as it was,
             and a copy of the config stays in /tmp/$UCI_CFG.bak until reboot
             (uninstall keep: leave the settings and server history in place)
  start      Apply QoS-Ex shaping using current UCI config (only if enabled=1)
  stop       Tear down all qdiscs, filters, and nft tables
  enable     Master ON: set enabled=1, wire autostart, flow offloading off,
             start (incl. PingFilter, if it is switched on)
  disable    Master OFF: set enabled=0, stop everything, PingFilter switched
             off too, remove autostart, flow offloading back as it was
  restart    Stop + start
  reload     Rebuild nft rules; full restart if a shaping setting changed
  status     Show config + runtime health checks
  stats      Show tc qdisc and class counters (nft counters: nftdump)
  enable_autostart   Enable init.d autostart + install hotplug
  disable_autostart  Disable init.d autostart + remove hotplug
  install_hotplug    Install the hotplug (ifup) hook only
  remove_hotplug     Remove the hotplug (ifup) hook only
  install_uci        Write the default config if there is none, else migrate
  autosetup ...      Router check, line speed test and suggested settings
                     (qos-ex.sh autosetup for its commands)

Diagnostics and UI feeds:
  state      Running state as key=value lines (the LuCI pages poll it)
  counters   Counters only, as stats prints them (the Stats graphs' poll)
  debug      One pasteable report (location, hostname, this router's
             IPv4s and IPv6s, LAN and CGNAT addresses and MACs redacted;
             remote addresses are not)
  tcplan     The tc / ip commands start would run, without running them
  nftdump    Active classification chains  |  nftdump_full  Whole table
  nfterr     Last nft load failure         |  logdump       $RUN_LOG
  conntrack [N]      Top N flows by packets, with the DSCP each carries
  disable_offload    Turn flow offloading off (it bypasses classification)
  pingfilter|pf ...  Pass the rest through to $PF_BIN

Supported qdiscs:    cake (default) | hfsc | htb
Supported NFT modes: adaptive (default) | advanced | simple
EOF
		;;
esac
