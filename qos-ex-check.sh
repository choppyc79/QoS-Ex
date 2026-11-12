#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# QoS-Ex check: does what is installed work as this version should?
# QoS-Ex-install.sh keeps this file as /root/qos-ex-check.sh, fetched with the
# scripts it checks. Run as root on the router:
#
#   sh /root/qos-ex-check.sh            read-only report: changes nothing
#   sh /root/qos-ex-check.sh match      the same, plus the game flows and the Ping Filter's
#                                       played server: run it while a match is on
#   sh /root/qos-ex-check.sh TEST ...   also runs the tests named; each one CHANGES something:
#     reload    a reload with nothing changed                no shaping gap
#     burst     three reloads at once                        no shaping gap
#     restart   stop, check nothing is left, start           shaping + Ping Filter off ~10 s
#     ifb       stop, rmmod ifb, start                       shaping off ~10 s
#     branch    update_branch unset, then put back           a settings change, undone
#     redial    ifup wan                                     the internet drops a few seconds
#     rules     Adaptive for a moment, then back             a settings change, undone (two reloads)
#     queue     HTB for a moment, then back                  a settings change, undone; shaping off ~10 s twice
#     update    two Update now at once                       runs the updater: installs what changed, if anything
#     debug     the sanitized debug report at the end        read-only
#
# Each result line starts PASS, FAIL, INFO or SKIP. Everything is also saved to
# /tmp/qos-ex-check.txt (until a reboot). The report holds LAN and game-server
# addresses and log lines: read it before you post it.

OUT=/tmp/qos-ex-check.txt
Q=/usr/sbin/qos-ex.sh PFB=/usr/sbin/qos-ex-pf.sh INIT=/etc/init.d/QoS-Ex
STAMP=/var/run/qos-ex-started PFR=/var/run/qos-ex-pingfilter
HOOK=/etc/hotplug.d/iface/99-QoS-Ex LOCK=/var/run/QoS-Ex-hotplug.lock
NP=0 NF=0

pass() { NP=$((NP + 1)); echo "PASS $*"; }
fail() { NF=$((NF + 1)); echo "FAIL $*"; }
info() { echo "INFO $*"; }
skip() { echo "SKIP $*"; }
sec()  { echo; echo "== $*"; }
ind()  { sed 's/^/     /'; }
# A key from a saved @@STATE@@ block: kv FILE KEY
kv()   { sed -n "/^@@STATE@@/,/^@@STATE_END@@/s/^$2=//p" "$1" | head -n 1; }
st()   { kv "$T/status" "$1"; }
pfk()  { kv "$T/pf" "$1"; }
ver()  { sed -n 's/^VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n 1; }
now()  { cut -d. -f1 /proc/uptime; }
sv()   { sed -n "s/^$1=//p" "$STAMP" 2>/dev/null | head -n 1; }
rootkind()      { tc qdisc show dev "$1" root 2>/dev/null | awk 'NR == 1 { print $2 }'; }
shaper_tables() { nft list tables 2>/dev/null | grep -cE '^table inet qos_ex_(simple|advanced|adaptive)$'; }
txq()  { ls -d /sys/class/net/"$1"/queues/tx-* 2>/dev/null | wc -l; }
lines() { echo $(($(cat "$1" 2>/dev/null | wc -l) + 0)); }
ifbs() { for _d in /sys/class/net/ifb*; do [ -e "$_d" ] && printf '%s ' "${_d##*/}"; done; }
cs()   { read -r _u _ < /proc/uptime; echo "${_u%.*}${_u#*.}"; }   # uptime in hundredths
hp()   { logread -e QoS-Ex-hotplug 2>/dev/null | grep -c "$1"; }
# The service through procd when it runs; the backend itself otherwise.
svc()  {
	if [ -x "$INIT" ] && ubus list service >/dev/null 2>&1; then "$INIT" "$@"
	else QOS_EX_SUPERVISED=1 "$Q" "$@"; fi
}
running() { "$Q" state > "$T/state" 2>/dev/null; [ "$(kv "$T/state" running)" = 1 ]; }
wait_running() {
	_i=0
	while [ "$_i" -lt "$1" ]; do running && return 0; sleep 1; _i=$((_i + 1)); done
	return 1
}

# An installed part against the copy QoS-Ex-install.sh keeps in /root:
# part NAME INSTALLED COPY
part() {
	v=$(ver "$2")
	if [ ! -f "$2" ]; then fail "$1 missing ($2)"
	elif [ ! -f "$3" ]; then info "$1${v:+ $v} (no $3 to compare with)"
	elif cmp -s "$2" "$3"; then pass "$1${v:+ $v}, the same as $3"
	else w=$(ver "$3"); fail "$1${v:+ $v} differs from $3${w:+ ($w)} - run: sh /root/QoS-Ex-install.sh"; fi
}

versions() {
	sec "Versions"
	info "router: $(cat /tmp/sysinfo/model 2>/dev/null), $(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_DESCRIPTION"), kernel $(uname -r), up $(($(now) / 60)) min"
	part "shaper" "$Q" /root/QoS-Ex.sh
	part "shaper library" /usr/lib/qos-ex/install.sh /root/lib/install.sh
	part "Ping Filter" "$PFB" /root/QoS-Ex-PF.sh
	# The app's stylesheet names the installer that wrote it: version and sha256.
	css=/www/luci-static/resources/qos-ex/qos-ex.css
	v=$(sed -n '1s/.*qos-ex-luci v\([0-9][0-9.]*\).*/\1/p' "$css" 2>/dev/null)
	h=$(sed -n '1s/.*qos-ex-luci v[0-9.]* #\([0-9a-f]*\).*/\1/p' "$css" 2>/dev/null)
	if [ -z "$v" ]; then fail "LuCI app missing"
	elif [ ! -f /root/QoS-Ex-luci-app.sh ]; then info "LuCI app $v (no /root/QoS-Ex-luci-app.sh to compare with)"
	elif [ "$h" = "$(sha256sum /root/QoS-Ex-luci-app.sh | cut -c1-10)" ]; then pass "LuCI app $v, installed by /root/QoS-Ex-luci-app.sh"
	else fail "LuCI app $v was not installed by /root/QoS-Ex-luci-app.sh ($(ver /root/QoS-Ex-luci-app.sh)) - run: sh /root/QoS-Ex-install.sh"; fi
	[ -f /usr/lib/qos-ex/live.sh ] && pass "/usr/lib/qos-ex/live.sh present (light counters)" || fail "/usr/lib/qos-ex/live.sh missing"
	info "update_branch=$(uci -q get qos-ex.settings.update_branch || echo unset), installed-ref=$(cat /etc/qos-ex/installed-ref 2>/dev/null || echo none)"
	if r=$(ubus call qos-ex update_check 2>/dev/null); then
		info "update check: branch=$(jsonfilter -s "$r" -e '@.branch' 2>/dev/null) installed=$(jsonfilter -s "$r" -e '@.installed' 2>/dev/null)" \
			"latest luci=$(jsonfilter -s "$r" -e '@.luci' 2>/dev/null) pf=$(jsonfilter -s "$r" -e '@.pf' 2>/dev/null)" \
			"shaper=$(jsonfilter -s "$r" -e '@.shaper' 2>/dev/null) $(jsonfilter -s "$r" -e '@.error' 2>/dev/null)"
	else
		info "ubus call qos-ex update_check failed (rpcd)"
	fi
}

shaper() {
	sec "Shaper"
	"$Q" status > "$T/status" 2>&1
	s=""; for k in enabled running qdisc nft_mode wan wan_live ifb download_on shape_up shape_dn ul_kbps_eff dl_kbps_eff wash_down; do s="$s $k=$(st $k)"; done
	info "${s# }"
	[ "$(st running)" = 1 ] && pass "running" || fail "not running (enabled=$(st enabled))"
	for k in root_qdisc ingress_qdisc ifb_up ctinfo nft_table init hotplug; do
		off=0
		[ "$k" = root_qdisc ] && [ "$(st shape_up)" = 0 ] && off=1
		case "$k" in ingress_qdisc|ifb_up|ctinfo) [ "$(st shape_dn)" = 0 ] && off=1 ;; esac
		if [ "$off" = 1 ]; then info "$k: that direction is not shaped"
		elif [ "$(st $k)" = 1 ]; then pass "health $k"
		else fail "health $k=$(st $k)"; fi
	done
	case "$(st wan_match)" in
		1) pass "WAN $(st wan) is the internet line" ;;
		0) fail "WAN mismatch: set to $(st wan), the line is on $(st wan_live)" ;;
		*) info "wan_match=$(st wan_match)" ;;
	esac
	[ "$(st offload_sw)$(st offload_hw)" = 00 ] && pass "flow offloading off" || fail "flow offloading on (sw=$(st offload_sw) hw=$(st offload_hw))"
	[ "$(st ct_acct)" = 1 ] && pass "nf_conntrack_acct on" || fail "nf_conntrack_acct=$(st ct_acct)"
	[ -z "$(st pkg_missing)" ] && pass "no package missing" || fail "packages missing: $(st pkg_missing)"
	[ -n "$(st ct_mark_users)" ] && info "the conntrack mark is also used by: $(st ct_mark_users)"
	[ "$(st backend_stale)$(st pf_stale)" = 00 ] || info "a /root copy differs from the installed one (backend_stale=$(st backend_stale) pf_stale=$(st pf_stale))"
	# Multi-queue CAKE is gone (shaper 3.2.1.0): no status key, no setting.
	grep -q '^cake_mq=' "$T/status" && fail "status still reports cake_mq=$(st cake_mq)" || pass "no cake_mq in the status (multi-queue CAKE removed)"
	v=$(uci -q get qos-ex.cake.mq); [ -z "$v" ] && pass "cake.mq retired from the settings" || fail "cake.mq still set: $v"
	grep 'nat_ingress' "$T/status" | head -n 1 | sed 's/^ *//' | while read -r l; do info "$l"; done
}

nftables() {
	sec "nftables"
	n=$(shaper_tables)
	[ "$n" = 1 ] && pass "one shaper table ($(nft list tables 2>/dev/null | grep -oE 'qos_ex_(simple|advanced|adaptive)'))" || fail "$n shaper tables"
	nft list tables 2>/dev/null | grep -q 'qos_ex_pf$' && info "Ping Filter table qos_ex_pf loaded" || info "no Ping Filter table"
	[ -f /usr/share/nftables.d/ruleset-post/qos-ex.nft ] && pass "fw4 include present" || fail "fw4 include /usr/share/nftables.d/ruleset-post/qos-ex.nft missing"
	n=$(ls /var/run/qos-ex/qos_ex_*.nft 2>/dev/null | wc -l)
	[ "$n" = 1 ] && pass "one loaded rule-set file in /var/run/qos-ex" || fail "$n rule-set files in /var/run/qos-ex"
	for f in /var/run/qos-ex-nft.err /var/run/qos-ex-pingfilter-nft.err; do
		[ -s "$f" ] && { fail "nft error file $f:"; head -n 5 "$f" | ind; }
	done
}

queues() {
	sec "Queues (tc)"
	[ -s "$STAMP" ] || { fail "no start stamp: the shaper is not running"; return; }
	W=$(sv WAN) I=$(sv IFB) DLON=$(sv DLON) QD=$(st qdisc)
	if [ "$(st shape_up)" = 0 ]; then info "upload not shaped"
	else
		k=$(rootkind "$W")
		[ "$k" = "$QD" ] && pass "upload: $W root $k" || fail "upload: $W root ${k:-none} (want $QD)"
	fi
	if [ "$(st shape_dn)" = 0 ]; then info "download not shaped"
	else
		k=$(rootkind "$I")
		[ "$k" = "$QD" ] && pass "download: $I root $k" || fail "download: $I root ${k:-none} (want $QD)"
		if [ "$DLON" = lan ]; then
			tc qdisc show dev "$I" 2>/dev/null | grep -q clsact && pass "clsact on $I (download on the LAN device)" || fail "no clsact on $I"
			[ "$QD" = cake ] && { tc qdisc show dev "$I" root | grep -q nonat && pass "LAN-side CAKE runs nonat" || fail "LAN-side CAKE without nonat"; }
		else
			tc qdisc show dev "$W" 2>/dev/null | grep -q '^qdisc ingress' && pass "ingress qdisc on $W" || fail "no ingress qdisc on $W"
			info "$I: $(txq "$I") TX queue(s)"
		fi
	fi
	# Shaper 3.2.1.6: the fq_codel class queues get a whole MB, which tc
	# prints as "21Mb"; any other size it prints in bytes ("21756150b").
	case "$QD" in hfsc|htb)
		for d in "$W" "$I"; do
			m=$(tc qdisc show dev "$d" 2>/dev/null | sed -n 's/^qdisc fq_codel .* parent 1:1[1-5] .*memory_limit \([0-9]*[KMG]*b\) .*/\1/p' | sort -u | tr '\n' ' ')
			[ -n "$m" ] || continue
			case " $m" in
				*[0-9]b\ *) fail "$d fq_codel memory_limit ${m% } (want whole MB, e.g. 21Mb)" ;;
				*)          pass "$d fq_codel memory_limit ${m% }" ;;
			esac
		done ;;
	esac
	tc qdisc show dev "$W" root 2>/dev/null | head -n 1 | while read -r l; do info "WAN: $l"; done
	[ "$I" != "$W" ] && tc qdisc show dev "$I" root 2>/dev/null | head -n 1 | while read -r l; do info "download: $l"; done
	info "ifb devices: $(ifbs)"
}

# The download's ctinfo action follows the queue type and Wash DSCP Down
# (shaper 3.2.1.1; CAKE + wash without the state bit since 3.2.1.3).
dscp_restore() {
	sec "DSCP restore (shaper 3.2.1.1 - 3.2.1.3)"
	n=$(logread 2>/dev/null | grep -c 'cpmark refused')
	[ "$n" = 0 ] && pass "no 'cpmark refused' in the system log" || fail "$n 'cpmark refused' line(s) in the system log"
	tb=$(nft list tables 2>/dev/null | grep -oE 'qos_ex_(simple|advanced|adaptive)$' | head -n 1)
	if [ -n "$tb" ]; then
		n=$(nft list table inet "$tb" 2>/dev/null | grep -c 'chain set_')
		[ "$n" = 9 ] && pass "$tb: 9 DSCP setter chains" || fail "$tb: $n DSCP setter chains (want 9)"
	fi
	if [ "$tb" = qos_ex_adaptive ]; then
		n=$(nft list map inet qos_ex_adaptive dscp_of 2>/dev/null | grep -o 'jump set_' | wc -l)
		[ "$n" = 9 ] && pass "Adaptive dscp_of map: 9 marks" || fail "Adaptive dscp_of map: $n marks (want 9)"
	fi
	if [ "$(st shape_dn)" != 1 ] || [ ! -s "$STAMP" ]; then info "download not shaped: no restore"; return; fi
	W=$(sv WAN) I=$(sv IFB) QD=$(st qdisc) WD=$(st wash_down)
	if [ "$(sv DLON)" = lan ]; then
		cti() { tc -s filter show dev "$I" egress 2>/dev/null; }
	else
		cti() { tc -s filter show dev "$W" parent ffff: 2>/dev/null; }
		cti | grep -q "Redirect to device $I" && pass "$W ingress redirects to $I" || fail "no redirect to $I on $W ingress"
	fi
	l=$(cti | grep -E '(dscp|cpmark) 0x' | head -n 1)
	d=- c=-
	printf '%s\n' "$l" | grep -qE 'dscp 0x0*3f 0x0*80( |$)' && d=s
	printf '%s\n' "$l" | grep -qE 'dscp 0x0*3f (0x)?0+( |$)' && d=n
	printf '%s\n' "$l" | grep -qE 'cpmark 0x0*bf( |$)' && c=c
	case "$QD$WD" in
		cakeyes)        w=n- f="ctinfo dscp 63 (no state bit)" ;;
		cake*)          w=s- f="ctinfo dscp 63 128" ;;
		hfscyes|htbyes) w=-c f="ctinfo cpmark 0xbf (the mark only)" ;;
		*)              w=sc f="ctinfo dscp 63 128 cpmark 0xbf" ;;
	esac
	[ "$d$c" = "$w" ] && pass "$QD, wash_down=$WD: $f" || fail "$QD, wash_down=$WD: want $f"
	printf '%s\n' "$l" | sed 's/^[[:space:]]*//; s/ installed.*//' | ind
	a=$(cti | sed -n 's/.*\(DSCP set .*\)/\1/p' | head -n 1); sleep 3
	info "ctinfo $a; 3 s later: $(cti | sed -n 's/.*\(DSCP set .*\)/\1/p' | head -n 1)"
	case "$QD" in hfsc|htb)
		n=$(st ifb_filters)
		[ "$n" = 9 ] && pass "$I: 9 fw filters on the connmark" || fail "$I: $n classifying filters (want 9 fw)" ;;
	esac
	# CAKE shapes only its own device: with the download on the LAN device nft
	# washes what leaves by any other (shaper 3.2.1.2).
	if [ "$QD$WD" = cakeyes ] && [ "$(sv DLON)" = lan ]; then
		nft list table inet "$tb" 2>/dev/null | grep -q "oifname != \"$I\"" &&
			pass "WAN traffic that leaves by other devices is washed" || fail "no 'oifname != \"$I\"' wash rule"
	fi
}

# The EF check fixes (shaper 3.2.1.4 / 3.2.1.5): Gaming leaf sfq, Adaptive's
# byte guard, video-call UDP AF41 under CAKE.
ef_fixes() {
	sec "EF fixes (shaper 3.2.1.4 / 3.2.1.5)"
	v=$(st game_qdisc)
	case "$v" in
		sfq)   pass "Gaming leaf qdisc sfq" ;;
		pfifo) fail "Gaming leaf qdisc pfifo: an update from 3.2.1.4 or older moves it to sfq once (picked again since?)" ;;
		*)     info "Gaming leaf qdisc ${v:-unset} (picked by hand)" ;;
	esac
	grep -h 'game_qdisc' /var/log/qos-ex-update.log 2>/dev/null | tail -n 2 | ind
	QD=$(st qdisc)
	case "$QD" in hfsc|htb)
		for d in "$(sv WAN)" "$(sv IFB)"; do
			k=$(tc qdisc show dev "$d" parent 1:10 2>/dev/null | awk 'NR == 1 { print $2 }')
			[ -n "$k" ] || continue
			[ "$k" = "$v" ] && pass "$d 1:10 leaf $k" || fail "$d 1:10 leaf $k (want $v)"
		done ;;
	esac
	if ! nft list table inet qos_ex_adaptive >/dev/null 2>&1; then
		info "rule set $(st nft_mode): the guard and video-call checks need Adaptive (test 'rules')"; return
	fi
	r=$(nft list chain inet qos_ex_adaptive guard 2>/dev/null | grep '@guard_bytes')
	[ -n "$r" ] && pass "Adaptive gaming guard meters bytes too" || fail "Adaptive guard without @guard_bytes"
	printf '%s\n' "$r" | sed 's/^[[:space:]]*//' | ind
	mk=$(nft list chain inet qos_ex_adaptive s_call 2>/dev/null | sed -n 's/.*ct mark set \(0x[0-9a-f]*\).*/\1/p' | head -n 1)
	w=32 nm=CS4; [ "$QD" = cake ] && w=34 nm=AF41
	[ -n "$mk" ] && [ $((mk & 63)) = "$w" ] && pass "video-call UDP $nm under $QD" || fail "video-call UDP mark ${mk:-none} (want DSCP $w, $nm)"
}

hook() {
	sec "ifup hook (shaper 3.2.0.8)"
	[ -f "$HOOK" ] || { fail "$HOOK missing"; return; }
	n=$(grep -c hp_again "$HOOK")
	[ "$n" = 3 ] && pass "the 3.2.0.8 hook (replays an ifup that comes during a restart)" || fail "hook without the 3.2.0.8 replay (hp_again x$n)"
	if [ -d "$LOCK" ]; then info "hotplug lock held ($(($(now) - $(cat "$LOCK/ts" 2>/dev/null || echo 0))) s old)"
	else pass "no hotplug lock held"; fi
	logread -e QoS-Ex-hotplug 2>/dev/null | tail -n 4 | ind
}

counters() {
	sec "Counters for the Status tile (LuCI 1.3.8.8)"
	r=$(ubus call qos-ex counters 2>/dev/null) || { fail "ubus call qos-ex counters failed"; return; }
	o=$(jsonfilter -s "$r" -e '@.output' 2>/dev/null) || { fail "the counters reply is not JSON"; return; }
	case "$o" in *@@COUNTERS@@*) pass "the counters reply carries the @@COUNTERS@@ block" ;; *) fail "no @@COUNTERS@@ block in the reply" ;; esac
	info "counters: $(printf '%s\n' "$o" | grep -E '^(qdisc|wan|ifb|ul_kbps|dl_kbps|qd_up|qd_down)=' | tr '\n' ' ')"
	# 10 calls in hundredths of a second = the average call in ms.
	a=$(cs); i=0; while [ $i -lt 10 ]; do ubus call qos-ex counters >/dev/null 2>&1; i=$((i + 1)); done
	b=$(cs); i=0; while [ $i -lt 10 ]; do "$Q" counters >/dev/null 2>&1; i=$((i + 1)); done
	c=$(cs)
	info "counters, average of 10 calls: $((b - a)) ms through rpcd (the light way), $((c - b)) ms through the whole backend"
}

# LuCI app 1.4.0.1: the lighter page calls. Read-only (a peek asks the Ping
# Filter for its list once, as LuCI's Status box does).
app_calls() {
	sec "Page calls (LuCI app 1.4.0.1)"
	r=$(ubus call qos-ex logs '{"shaper":5,"pf":5,"update":5}' 2>/dev/null)
	if [ -n "$(jsonfilter -s "$r" -e '@.shaper.output' 2>/dev/null)" ] && [ -n "$(jsonfilter -s "$r" -e '@.nft.output' 2>/dev/null)" ]; then
		pass "logs answers the three logs and the nft errors in one call"
	else
		fail "ubus call qos-ex logs: no shaper / nft part in the reply"
	fi
	# 10 rounds in hundredths of a second = the average round in ms.
	a=$(cs); i=0; while [ $i -lt 10 ]; do ubus call qos-ex logs '{"shaper":50,"pf":50,"update":50}' >/dev/null 2>&1; i=$((i + 1)); done
	b=$(cs); i=0
	while [ $i -lt 10 ]; do
		for s in shaper pf update; do ubus call qos-ex logdump "{\"lines\":50,\"src\":\"$s\"}" >/dev/null 2>&1; done
		ubus call qos-ex nfterr >/dev/null 2>&1; ubus call qos-ex pf_text '{"verb":"nfterr","ip":""}' >/dev/null 2>&1
		i=$((i + 1))
	done
	c=$(cs)
	info "System > Logs, one refresh, average of 10: $((b - a)) ms in one call, $((c - b)) ms as the five calls before"
	# The played server's telemetry: read by the shim, and through the Ping Filter script.
	ip=$(awk -F'\t' 'NR == 1 { print $1 }' "$PFR/live.tsv" 2>/dev/null); [ -n "$ip" ] || ip=192.0.2.1
	a=$(cs); i=0; while [ $i -lt 10 ]; do ubus call qos-ex pf_telemetry "{\"ip\":\"$ip\"}" >/dev/null 2>&1; i=$((i + 1)); done
	b=$(cs); i=0; while [ $i -lt 10 ]; do "$PFB" telemetry "$ip" >/dev/null 2>&1; i=$((i + 1)); done
	c=$(cs)
	info "pf_telemetry for $ip, average of 10: $((b - a)) ms through rpcd (read by the shim), $((c - b)) ms through the Ping Filter script"
	x=$(ubus call qos-ex pf_telemetry "{\"ip\":\"$ip\"}" 2>/dev/null | jsonfilter -e '@.samples[*]' 2>/dev/null | wc -l)
	y=$("$PFB" telemetry "$ip" 2>/dev/null | jsonfilter -e '@.samples[*]' 2>/dev/null | wc -l)
	[ "$x" = "$y" ] && pass "pf_telemetry: the shim and the Ping Filter script give the same $x sample(s)" \
		|| info "pf_telemetry: $x sample(s) by the shim, $y by the Ping Filter script (a sample can land between the two calls: run it again)"
	if [ -d "$PFR" ] && [ ! -e "$PFR/.viewer" ]; then
		ubus call qos-ex pf_servers '{"peek":true}' >/dev/null 2>&1
		[ -e "$PFR/.viewer" ] && info "the page-is-watching mark appeared after a peek: a QoS-Ex page open in a browser leaves it too - close it and run again" \
			|| pass "pf_servers with peek leaves no page-is-watching mark"
	else
		skip "peek: the mark is there now (a QoS-Ex page is open), or the Ping Filter has no run directory"
	fi
	# What one poll costs: the banner asks state, the Flows page conntrack.
	a=$(cs); i=0; while [ $i -lt 10 ]; do "$Q" state >/dev/null 2>&1; i=$((i + 1)); done
	b=$(cs); i=0; while [ $i -lt 10 ]; do "$Q" conntrack 50 >/dev/null 2>&1; i=$((i + 1)); done
	c=$(cs)
	info "backend calls, average of 10: state $((b - a)) ms, conntrack 50 $((c - b)) ms"
}

gameflows() {
	sec "Game flows (shaper 3.2.0.7)"
	"$Q" conntrack 50 > "$T/ct" 2>/dev/null
	n=$(lines "$T/ct"); e=$(($(awk -F'\t' '$1 == "udp" && $6 == "ef"' "$T/ct" | wc -l) + 0))
	info "$n flows listed (cap 50), $e EF UDP"
	if [ "$e" -gt 0 ]; then
		f=$(head -n "$e" "$T/ct" | awk -F'\t' '$1 == "udp" && $6 == "ef"' | wc -l)
		[ "$f" = "$e" ] && pass "the $e EF UDP flow(s) come first" || fail "EF UDP flows not first ($f of the first $e rows)"
	else
		info "no EF UDP flow now (run with 'match' while a game is on)"
	fi
	head -n "${1:-3}" "$T/ct" | cut -f1-8 | tr '\t' ' ' | ind
}

pingfilter() {
	sec "Ping Filter"
	"$PFB" status > "$T/pf" 2>&1
	s=""; for k in enabled master_enabled running activity block_mode threshold_ms ping_catch_ms hold_active lite offload total allowed blocked whitelist blacklist prereq_ok; do s="$s $k=$(pfk $k)"; done
	info "${s# }"
	if [ "$(pfk enabled)" = 1 ] && [ "$(pfk master_enabled)" = 1 ]; then
		[ "$(pfk running)" = 1 ] && pass "daemon running" || fail "on, but the daemon is not running"
		r=$(nft list chain inet qos_ex_pf enforce 2>/dev/null | sed -n '/hook forward/{n;s/^[[:space:]]*//;p;q}')
		[ "$r" = "meta l4proto != udp return" ] && pass "enforce starts with the UDP gate (2.0.9.0)" || fail "enforce starts with: ${r:-nothing}"
	else
		info "Ping Filter off"
	fi
	m=$(uci -q get qos-ex.pingfilter.max_servers); m=${m:-250}
	n=$(lines "$PFR/prefix.tsv")
	[ "$n" -le 2000 ] && pass "/24 memory: $n rows (at most 2000)" || fail "/24 memory: $n rows (more than 2000)"
	n=$(lines "$PFR/telemetry-hist.tsv")
	[ "$n" -le $((m + 50)) ] && pass "play history: $n rows (at most $((m + 50)))" || fail "play history: $n rows (more than $((m + 50)))"
	j=$("$PFB" matchmaking 2>/dev/null)
	jsonfilter -s "$j" -e '@.servers' >/dev/null 2>&1 && pass "matchmaking prints valid JSON (2.0.9.3)" || fail "matchmaking output is not JSON"
	n=$(logread 2>/dev/null | grep -c 'Terminated')
	[ "$n" = 0 ] && pass "no 'Terminated' in the system log" || fail "$n 'Terminated' line(s) in the system log"
	[ -f "$PFR/status" ] && info "PF status file present (a Dashboard is open)" || info "no PF status file (no Dashboard open)"
	info "server list: $(lines "$PFR/servers.tsv") rows live, $(lines /etc/qos-ex/pf-cache/servers.tsv) on flash"
	tail -n 5 /var/log/qos-ex-pf-daemon.log 2>/dev/null | ind
}

logs() {
	sec "Logs"
	tail -n 12 /var/log/qos-ex.log 2>/dev/null | ind
	n=$(logread 2>/dev/null | grep -i 'qos-ex' | grep -ciE 'error|fail')
	info "$n system-log line(s) from QoS-Ex with error or fail"
	logread 2>/dev/null | grep -i 'qos-ex' | grep -iE 'error|fail' | tail -n 5 | ind
}

match() {
	sec "During a match"
	info "Ping Filter activity=$(pfk activity) (in a match: active)"
	gameflows 10
	for f in "$PFR"/.play-*; do
		[ -e "$f" ] || { info "no server in session"; break; }
		ip=${f##*.play-}
		nft get element inet qos_ex_pf ping_allowed "{ $ip }" >/dev/null 2>&1 &&
			pass "played server $ip is in @ping_allowed" || fail "played server $ip is not in @ping_allowed"
	done
	ls "$PFR"/.due-* >/dev/null 2>&1 && info "blocks waiting for the game to end: $(ls "$PFR"/.due-* | sed 's/.*\.due-//' | tr '\n' ' ')"
	if [ "$(pfk hold_active)" = 1 ]; then
		nft list chain inet qos_ex_pf enforce 2>/dev/null | grep -q 'ct original packets' &&
			pass "new-server hold lets the first packets pass (ct original packets)" || info "new-server hold: full hold"
	fi
	W=$(sv WAN)
	[ -n "$W" ] && tc -s qdisc show dev "$W" root 2>/dev/null | grep -E '^ +(Sent|backlog|pk_delay|av_delay|drops|marks) ' | ind
	info "Overview: does Gaming traffic read '↓ x · ↑ y · EF' and match the Gaming flow rows?"
}

test_reload() {
	sec "TEST reload (no shaping gap)"
	u=$(sv UPT); o=$(svc reload 2>&1); sleep 2
	printf '%s\n' "$o" | tail -n 3 | ind
	case "$o" in *"unchanged - kept"*) pass "rule set unchanged - kept" ;; *) info "no 'unchanged - kept' in the reload output" ;; esac
	[ "$(sv UPT)" = "$u" ] && pass "no restart (start stamp kept)" || fail "the shaper restarted (stamp $u -> $(sv UPT))"
	[ "$(shaper_tables)" = 1 ] && pass "one shaper table" || fail "$(shaper_tables) shaper tables"
}

test_burst() {
	sec "TEST burst: three reloads at once (no shaping gap)"
	u=$(sv UPT)
	for i in 1 2 3; do svc reload >/dev/null 2>&1 & done
	wait; sleep 2
	[ "$(shaper_tables)" = 1 ] && pass "one shaper table" || fail "$(shaper_tables) shaper tables"
	k=$(rootkind "$(sv WAN)"); case "$k" in cake|hfsc|htb) pass "WAN root $k" ;; *) fail "WAN root ${k:-none}" ;; esac
	[ "$(sv UPT)" = "$u" ] && pass "no restart" || info "the shaper restarted (stamp $u -> $(sv UPT))"
}

test_restart() {
	sec "TEST restart (shaping and Ping Filter off ~10 s)"
	W=$(sv WAN) I=$(sv IFB) DLON=$(sv DLON)
	svc stop >/dev/null 2>&1; sleep 2
	[ "$(shaper_tables)" = 0 ] && pass "stopped: no shaper table" || fail "stopped: $(shaper_tables) shaper table(s) left"
	k=$(rootkind "$W"); case "$k" in cake|cake_mq|hfsc|htb) fail "stopped: $W still has a $k root" ;; *) pass "stopped: $W root back to ${k:-none}" ;; esac
	if [ "$DLON" = lan ]; then
		tc qdisc show dev "$I" 2>/dev/null | grep -q clsact && fail "stopped: clsact left on $I" || pass "stopped: clsact gone from $I"
	elif [ -n "$I" ]; then
		ip link show "$I" >/dev/null 2>&1 && fail "stopped: $I still there" || pass "stopped: $I removed"
	fi
	[ -f "$STAMP" ] && fail "stopped: start stamp left" || pass "stopped: start stamp removed"
	n=$(ls /var/run/qos-ex/qos_ex_*.nft 2>/dev/null | wc -l)
	[ "$n" = 0 ] && pass "stopped: no rule-set file" || fail "stopped: $n rule-set file(s) left"
	t=$(now); svc start >/dev/null 2>&1
	# 3.2.1.7: once the init script has returned, nothing holds procd's QoS-Ex
	# lock (before, the Ping Filter's location check kept it up to 25 s).
	h=""
	for p in /proc/[0-9]*; do
		case "$(readlink "$p/fd/1000" 2>/dev/null)" in *procd_QoS-Ex.lock) h="$h $(cat "$p/comm" 2>/dev/null)/${p#/proc/}" ;; esac
	done
	[ -z "$h" ] && pass "started: procd's QoS-Ex lock free once the init script returned" || fail "started: procd's QoS-Ex lock still held by$h"
	wait_running 30 && pass "started: running again after $(($(now) - t)) s" || fail "started: not running after 30 s"
}

test_ifb() {
	sec "TEST ifb (shaping off ~10 s)"
	if [ "$(sv DLON)" = lan ] || [ "$(st shape_dn)" = 0 ]; then skip "the download is not on an IFB"; return; fi
	I=$(sv IFB)
	svc stop >/dev/null 2>&1; sleep 1
	rmmod ifb 2>/dev/null && info "ifb module unloaded" || info "rmmod ifb refused (still in use?)"
	svc start >/dev/null 2>&1
	wait_running 30 || fail "not running 30 s after the start"
	l=$(ifbs)
	[ "$l" = "$I " ] && pass "only $I exists (no ifb0 / ifb1)" || fail "ifb devices: $l(want only $I)"
}

test_branch() {
	sec "TEST branch (update_branch unset, then put back)"
	o=$(uci -q get qos-ex.settings.update_branch) ref=$(cat /etc/qos-ex/installed-ref 2>/dev/null)
	uci -q delete qos-ex.settings.update_branch; uci commit qos-ex
	b=$(jsonfilter -s "$(ubus call qos-ex update_check 2>/dev/null)" -e '@.branch' 2>/dev/null)
	case "$ref" in
		main|dev) [ "$b" = "$ref" ] && pass "unset follows the branch installed ($b)" || fail "unset: updates follow '$b', installed '$ref'" ;;
		*) info "installed-ref '$ref', updates follow '$b'" ;;
	esac
	[ -n "$o" ] && uci set qos-ex.settings.update_branch="$o"
	uci commit qos-ex
	info "update_branch back to ${o:-unset}"
}

# Two Update now at once (LuCI app 1.4.0.0): one starts, the other is refused
# and nothing of it reaches the update log. Runs the updater for real: it
# installs only what changed (nothing on an up-to-date router); an update of
# the app logs LuCI out.
test_update() {
	sec "TEST update (two Update now at once)"
	ubus call qos-ex update_run > "$T/u1" 2>&1 &
	ubus call qos-ex update_run > "$T/u2" 2>&1
	wait
	ok=$(cat "$T/u1" "$T/u2" | grep -c '"ok": true') no=$(cat "$T/u1" "$T/u2" | grep -c 'already running')
	[ "$ok" = 1 ] && [ "$no" = 1 ] && pass "one started, one refused" || { fail "started $ok, refused $no (want 1 and 1)"; cat "$T/u1" "$T/u2" | ind; }
	[ "$ok" = 0 ] && return
	r=$(jsonfilter -s "$(ubus call qos-ex update_log 2>/dev/null)" -e '@.running' 2>/dev/null)
	[ "$r" = true ] && pass "update_log reads running while it works" || info "update_log running=$r (it may have ended already)"
	i=0
	while [ "$(jsonfilter -s "$(ubus call qos-ex update_log 2>/dev/null)" -e '@.running' 2>/dev/null)" = true ] && [ $i -lt 180 ]; do sleep 2; i=$((i + 2)); done
	L=/var/log/qos-ex-update.log
	rc=$(grep -c '^@@RC=' "$L" 2>/dev/null) bad=$(grep -c 'already running' "$L" 2>/dev/null)
	if [ "$rc" = 1 ] && [ "$bad" = 0 ] && grep -q '^@@RC=0' "$L"; then pass "the update log holds one run, ended @@RC=0, after $i s"
	else fail "update log: ${rc:-0} end marker(s), ${bad:-0} 'already running' line(s)"; tail -n 8 "$L" 2>/dev/null | ind; fi
	[ -e /var/run/qos-ex-update-run.lock ] && pass "the start lock exists (/var/run/qos-ex-update-run.lock)" || fail "no /var/run/qos-ex-update-run.lock"
}

# Adaptive for a moment (for a router on another rule set), then the rule set back.
test_rules() {
	sec "TEST rules: Adaptive for a moment, then back"
	rm0=$(st nft_mode) ro=$(uci -q get qos-ex.settings.nft_mode)
	[ "$rm0" = adaptive ] && { info "already Adaptive: the sections above cover it"; return; }
	uci set qos-ex.settings.nft_mode=adaptive; uci commit qos-ex
	svc reload >/dev/null 2>&1; sleep 2
	"$Q" status > "$T/status" 2>&1
	[ "$(st nft_mode)" = adaptive ] && [ "$(shaper_tables)" = 1 ] && pass "Adaptive loaded, one shaper table" || fail "nft_mode=$(st nft_mode), $(shaper_tables) shaper table(s)"
	dscp_restore; ef_fixes
	if [ -n "$ro" ]; then uci set qos-ex.settings.nft_mode="$ro"; else uci -q delete qos-ex.settings.nft_mode; fi
	uci commit qos-ex; svc reload >/dev/null 2>&1; sleep 2
	"$Q" status > "$T/status" 2>&1
	[ "$(st nft_mode)" = "$rm0" ] && [ "$(shaper_tables)" = 1 ] && pass "rule set back to $rm0" || fail "rule set $(st nft_mode), want $rm0"
}

# HTB for a moment (for a router on CAKE), then the queue type back. Each
# switch is a full restart: shaping off ~10 s.
test_queue() {
	sec "TEST queue: HTB for a moment, then back"
	q0=$(st qdisc) qo=$(uci -q get qos-ex.settings.qdisc)
	case "$q0" in hfsc|htb) info "already $q0: the sections above cover it"; return ;; esac
	uci set qos-ex.settings.qdisc=htb; uci commit qos-ex
	t0=$(now); svc reload >/dev/null 2>&1
	wait_running 30 && pass "HTB running after $(($(now) - t0)) s" || fail "HTB not running after 30 s"
	"$Q" status > "$T/status" 2>&1
	queues; dscp_restore; ef_fixes
	if [ -n "$qo" ]; then uci set qos-ex.settings.qdisc="$qo"; else uci -q delete qos-ex.settings.qdisc; fi
	uci commit qos-ex
	t0=$(now); svc reload >/dev/null 2>&1
	wait_running 30 && pass "running again after $(($(now) - t0)) s" || fail "not running 30 s after the switch back"
	"$Q" status > "$T/status" 2>&1
	[ "$(st qdisc)" = "$q0" ] && pass "queue type back to $q0" || fail "queue type $(st qdisc), want $q0"
}

test_redial() {
	sec "TEST redial (the internet drops a few seconds)"
	ubus call network.interface.wan status >/dev/null 2>&1 || { skip "no network interface 'wan' (netifd)"; return; }
	W=$(sv WAN) QD=$(st qdisc)
	r0=$(hp 'restarting QoS-Ex') a0=$(hp 'already shaping')
	t=$(now); ifup wan; ok=0; i=0
	while [ $i -lt 60 ]; do
		sleep 2; i=$((i + 2))
		# A restart (PPPoE: the device is new), or "already shaping" (a WAN
		# device that stayed, e.g. DHCP on a port).
		if { [ "$(hp 'restarting QoS-Ex')" -gt "$r0" ] || [ "$(hp 'already shaping')" -gt "$a0" ]; } && [ ! -d "$LOCK" ]; then
			[ "$(rootkind "$W")" = "$QD" ] && { ok=1; break; }
		fi
	done
	[ "$ok" = 1 ] && pass "shaped again $(($(now) - t)) s after ifup ($W root $(rootkind "$W"))" || fail "not shaped 60 s after ifup ($W root $(rootkind "$W"))"
	sleep 8
	r=$(hp 'restarting QoS-Ex') a=$(hp 'already shaping')
	[ $((r - r0)) = 1 ] && pass "one restart for the redial" || info "$((r - r0)) restarts for one redial"
	info "$((a - a0)) 'already shaping' answer(s) (wan6 after wan, or a WAN device that stayed)"
	logread -e QoS-Ex-hotplug 2>/dev/null | tail -n 4 | ind
	ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && info "internet back (ping 1.1.1.1)" || info "no reply from 1.1.1.1 yet"
}

main() {
	echo "QoS-Ex check $(date '+%Y-%m-%d %H:%M:%S'), script #$(sha256sum "$0" 2>/dev/null | cut -c1-10), arguments: ${*:-none}"
	versions; shaper; nftables; queues; dscp_restore; ef_fixes; hook; counters; app_calls; gameflows; pingfilter; logs
	for a in "$@"; do
		case "$a" in
			match) match ;;
			reload|burst|restart|ifb|branch|redial|rules|queue|update) "test_$a" ;;
			debug) sec "Debug report (sanitized)"; "$Q" debug 2>&1 ;;
			*) sec "Unknown argument: $a" ;;
		esac
	done
	sec "Summary: $NP PASS, $NF FAIL"
}

[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }
# The work files and the report sit in a mktemp directory, and the report is
# then renamed into place: a fixed /tmp name is anyone's to plant. A run
# that is interrupted keeps what it had written.
T=$(mktemp -d /tmp/qos-ex-check.XXXXXX) || { echo "mktemp failed"; exit 1; }
trap 'mv -f "$T/report" "$OUT" 2>/dev/null; rm -rf "$T"' EXIT
trap 'exit 1' INT TERM
main "$@" 2>&1 | tee "$T/report"
mv -f "$T/report" "$OUT" && { echo; echo "Saved to $OUT"; }
