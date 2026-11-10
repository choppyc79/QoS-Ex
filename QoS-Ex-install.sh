#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# QoS-Ex bootstrap: fetch the scripts and the LuCI app's files from GitHub
# into /root and run the installer. Safe to re-run to upgrade; also works
# piped (wget ... | sh).
# Source order: private (a token, when there is one), then public, then
# install. The result -- and why, when it fails -- goes to the QoS-Ex log
# (/var/log/qos-ex.log, the app's Logs page) and to syslog.
#
# One-line install/upgrade over SSH: see README.md. After the first run this
# file is kept as /root/QoS-Ex-install.sh, so later upgrades are just:
#   sh /root/QoS-Ex-install.sh
#
# It was called install.sh until LuCI app 1.2.7.4; run under either name it
# leaves only QoS-Ex-install.sh in /root. The repo has no install.sh any more:
# a router still on that name updates with this file (see README.md).
#
# Everything runs from main(), called on the last line: when piped, sh has
# the whole script before anything executes.

usage() {
	cat <<'EOF'
sh QoS-Ex-install.sh [-t TOKEN] [-b REF] [-n] [-a] [-h]
  -t TOKEN  GitHub token (fine-grained, Contents: read on this repo). Also
            read from $GH_TOKEN, then /etc/qos-ex/gh-token. A token is tried
            first; without one, or if it is refused, the repo is tried as
            public; if that fails too, a token is asked for on the terminal.
            Saved (once it works) to /etc/qos-ex/gh-token (0600, kept over
            sysupgrade).
  -b REF    branch/tag/commit (default: the update branch set on
            System -> Maintenance, main or dev; unset, the branch
            installed; else main). -b main or -b dev also makes it the
            update branch.
  -n        download only, do not install
  -a        reinstall all three (default: only the parts whose file on
            GitHub differs from the installed one)
  -h        this help
EOF
}

REPO="choppyc79/QoS-Ex"
REF=""
FILES="QoS-Ex.sh QoS-Ex-PF.sh QoS-Ex-luci-app.sh QoS-Ex-install.sh"
# The LuCI app's files: QoS-Ex-luci-app.sh installs from this tarball and
# names it by sha256 (LUCI_TAR_SHA). Fetched and checked with the scripts.
LUCI_TAR="qos-ex-luci.tar.gz"
DEST="/root"
TOKEN_FILE="/etc/qos-ex/gh-token"
LOG="/var/log/qos-ex.log"

# $1 level (INFO / "ERR "), $2 text: the shaper's log line format.
_log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] update: $2" 2>/dev/null >> "$LOG"
	logger -t QoS-Ex "update: $2" 2>/dev/null
	return 0
}
# One line per step, as the installers it runs print them: ok, .. (a note),
# !! (a warning), XX (an error). Colour only on a terminal.
_B=""; _D=""; _G=""; _Y=""; _R=""; _0=""
if [ -t 1 ] && [ "${QOS_EX_NO_COLOR:-0}" != 1 ]; then
	_B=$(printf '\033[1m'); _D=$(printf '\033[2m'); _G=$(printf '\033[32m')
	_Y=$(printf '\033[33m'); _R=$(printf '\033[31m'); _0=$(printf '\033[0m')
fi
_ok()   { printf '  %sok%s  %s\n' "$_G" "$_0" "$*"; }
_info() { printf '  %s..  %s%s\n' "$_D" "$*" "$_0"; }
_warn() { printf '  %s!!%s  %s\n' "$_Y" "$_0" "$*"; }
die() { printf '  %sXX%s  %s\n' "$_R" "$_0" "$*" >&2; _log "ERR " "FAILED - $*"; exit 1; }
# VERSION= of a script (first 40 lines), empty if absent.
_ver() { head -n 40 "$1" 2>/dev/null | sed -n 's/^VERSION="\([0-9][0-9.]*\)".*/\1/p' | head -n 1; }
# "v1 -> v2"; the one version when there was none before, or the same.
_vv() { if [ -n "$1" ] && [ "$1" != "$2" ]; then echo "v$1 -> v$2"; else echo "v$2"; fi; }
# The versions by module (LuCI app 1.x, Ping Filter 2.x, shaper 3.x): of the
# scripts in $1, or with no $1 of what is installed.
_vl() {
	if [ -n "$1" ]; then
		echo "app v$(_ver "$1/QoS-Ex-luci-app.sh") · PF v$(_ver "$1/QoS-Ex-PF.sh") · shaper v$(_ver "$1/QoS-Ex.sh")"
	else
		echo "app v$(sed -n '1s/.*qos-ex-luci v\([0-9][0-9.]*\).*/\1/p' "$_css" 2>/dev/null) · PF v$(_ver /usr/sbin/qos-ex-pf.sh) · shaper v$(_ver /usr/sbin/qos-ex.sh)"
	fi
}
# A child installer as one ok line: on success only its problem lines (!!,
# XX, ERROR, warning) are shown, on failure all of it (the shaper's _ui_run).
_run() {
	_lbl="$1"; shift
	"$@" > "$TMP/.run" 2>&1; _rc=$?
	if [ "$_rc" = 0 ]; then
		_ok "$_lbl"
		grep -E '!!|XX|ERROR|[Ww]arn' "$TMP/.run" | sed 's/^[[:space:]]*/      /'
		return 0
	fi
	printf '  %sXX%s  %s (exit %s)\n' "$_R" "$_0" "$_lbl" "$_rc" >&2
	sed 's/^[[:space:]]*/      /' "$TMP/.run" >&2
	return "$_rc"
}

# $1 url, $2 out. wget first (uclient-fetch, BusyBox or GNU), then curl, as
# the app's update check does: each is tried in turn, so a downloader without
# TLS still falls through to the other. The token goes to them as a header
# argument (uclient-fetch cannot read one from a file), so it shows in the
# process list while a download runs. The Contents API (raw media type)
# serves private repos and, unlike raw.githubusercontent.com, is not
# CDN-cached for ~5 min after a push.
# uclient-fetch has --header since 2024-04 (OpenWrt 24.10+).
# $3 = attempts (default 2). On failure GET_ERR is the downloader's last
# line ("HTTP error 404", "Connection error: ...") -- what tells a bad token
# from a private repo from no network. wget is not run quiet for that.
_get() {
	_acc="Accept: application/vnd.github.raw"; GET_ERR=""; _try=0
	while [ "$_try" -lt "${3:-2}" ]; do
		[ "$_try" -gt 0 ] && sleep 2
		_try=$((_try + 1))
		if [ -n "$HAVE_WGET" ]; then
			wget -T 20 -O "$2" --header="$AUTH" \
				--header="$_acc" "$1" 2>"$TMP/.err" && return 0
		fi
		if [ -n "$HAVE_CURL" ]; then
			curl -fsSL --connect-timeout 10 --max-time 120 -o "$2" \
				-H "$AUTH" -H "$_acc" "$1" 2>"$TMP/.err" && return 0
		fi
	done
	GET_ERR=$(tail -n 1 "$TMP/.err" 2>/dev/null | tr -d '\r')
	return 1
}

# Is the repo readable at $REF with the current $AUTH?
_probe() {
	OLDNAME=0
	_get "$_pu/QoS-Ex-install.sh?ref=$REF" "$TMP/.probe" 1 && return 0
	_pe="$GET_ERR"
	_get "$_pu/install.sh?ref=$REF" "$TMP/.probe" 1 && { OLDNAME=1; return 0; }
	GET_ERR="$_pe"
	return 1
}

main() {
	TOKEN="$GH_TOKEN"; NOINST=0; ALL=0
	while getopts "t:b:nah" o; do
		case "$o" in
		t) TOKEN="$OPTARG" ;;
		b) REF="$OPTARG" ;;
		n) NOINST=1 ;;
		a) ALL=1 ;;
		*) usage; exit 1 ;;
		esac
	done
	# No -b: the update branch (qos-ex.settings.update_branch); unset (Reset
	# to defaults, a settings file without it), the branch installed; else
	# main. The LuCI app's update check takes the same one.
	if [ -z "$REF" ]; then
		REF=$(uci -q get qos-ex.settings.update_branch 2>/dev/null)
		case "$REF" in main|dev) ;; *)
			REF=""; [ -r /etc/qos-ex/installed-ref ] && read -r REF < /etc/qos-ex/installed-ref
			case "$REF" in dev) ;; *) REF=main ;; esac ;;
		esac
	fi
	# A run handed over to the installer just fetched (QOS_EX_REEXEC) has had
	# its heading and source line from the first.
	if [ -z "$QOS_EX_REEXEC" ]; then
		case "$REF" in
		main) _rl="branch main" ;;
		dev)  _rl="branch dev (testing, not a release)" ;;
		*)    _rl="$REF (testing, not a release)" ;;
		esac
		printf '%sQoS-Ex installer · %s%s\n' "$_B" "$_rl" "$_0"
	fi

	[ "$(id -u)" = 0 ] || die "run as root"
	[ "$NOINST" = 1 ] || [ -f /etc/openwrt_release ] ||
		die "not OpenWrt (use -n to download only)"

	# One update at a time (SSH, Update now): flock on fd 8, dropped by the
	# kernel when this run ends or dies. The fetched installer run below
	# (QOS_EX_REEXEC) inherits it. Every child gets 8>&-: a daemon one starts
	# must not hold it.
	if [ -z "$QOS_EX_REEXEC" ] && command -v flock >/dev/null 2>&1; then
		exec 8>/var/run/qos-ex-update.lock
		flock -n 8 || die "an update is already running - try again when it has finished"
	fi

	command -v curl >/dev/null 2>&1 && HAVE_CURL=1
	command -v wget >/dev/null 2>&1 && HAVE_WGET=1
	[ -n "$HAVE_CURL$HAVE_WGET" ] || die "need wget (uclient-fetch) or curl"

	TMP="$(mktemp -d /tmp/qos-ex-dl.XXXXXX)" || die "mktemp failed"
	STAGE=""
	trap 'rm -rf "$TMP" $STAGE' EXIT
	trap 'exit 1' INT TERM

	# Private, then public, then install. Probe with the smallest file:
	#   1. a token (-t, $GH_TOKEN, the saved file), when there is one;
	#   2. no credentials (a dummy header keeps one code path) -- no token,
	#      or it was refused: an expired token is refused even on a public
	#      repo;
	#   3. both failed: ask on the terminal (works when piped - stdin is
	#      the script, /dev/tty is still the SSH session).
	# Each failure keeps its reason for the log.
	# A ref from before LuCI app 1.2.7.4 has this script as install.sh only
	# (-b to roll back): _probe finds which, and OLDNAME=1 fetches that set.
	_pu="https://api.github.com/repos/$REPO/contents"
	_saved=""; _src=""; _terr="none saved"; _aerr=""
	[ -r "$TOKEN_FILE" ] && read -r _saved < "$TOKEN_FILE"
	[ -n "$TOKEN" ] || TOKEN="$_saved"
	if [ -n "$TOKEN" ]; then
		AUTH="Authorization: Bearer $TOKEN"
		if _probe; then
			_src="private (token)"
		else
			_terr="${GET_ERR:-no reply}"
			_warn "GitHub token refused ($_terr) - trying the repo as public"
		fi
	fi
	if [ -z "$_src" ]; then
		AUTH="X-QoS-Ex: anon"
		if _probe; then
			_src="public"; TOKEN=""
		else
			_aerr="${GET_ERR:-no reply}"
		fi
	fi
	if [ -z "$_src" ] && (: </dev/tty) 2>/dev/null; then
		printf 'No access (token: %s; public: %s). GitHub token: ' "$_terr" "$_aerr" >/dev/tty
		# -s: typed hidden (BusyBox ash; OpenWrt has no stty).
		read -rs TOKEN </dev/tty
		echo >/dev/tty
		if [ -n "$TOKEN" ]; then
			AUTH="Authorization: Bearer $TOKEN"
			if _probe; then _src="private (token)"; else _terr="${GET_ERR:-no reply}"; fi
		fi
	fi
	[ -n "$_src" ] || die "no access to $REPO at '$REF' - token: $_terr; public: $_aerr. Private repo needs a valid token (-t TOKEN); else wrong ref or no network/HTTPS (need ca-bundle + libustream-mbedtls)"
	[ -n "$QOS_EX_REEXEC" ] || _ok "GitHub $REPO, $_src"
	[ "$OLDNAME" = 1 ] && FILES="QoS-Ex.sh QoS-Ex-PF.sh QoS-Ex-luci-app.sh install.sh"

	for f in $FILES; do
		_get "https://api.github.com/repos/$REPO/contents/$f?ref=$REF" "$TMP/$f" ||
			die "download failed: $f (${GET_ERR:-no reply}) - network dropped, or GitHub rate limit"
		read -r _l < "$TMP/$f"
		case "$_l" in '#!'*) ;; *) die "$f: not a script (bad token or ref?)" ;; esac
		sh -n "$TMP/$f" || die "$f: syntax check failed"
	done
	# The shaper's install half, from shaper 3.1.6.6 on (a ref before that
	# has none): /root/lib/install.sh, installed to /usr/lib/qos-ex.
	LIBS=""
	if grep -q '^_lib_install()' "$TMP/QoS-Ex.sh"; then
		LIBS="lib/install.sh"; mkdir -p "$TMP/lib"
		_get "https://api.github.com/repos/$REPO/contents/$LIBS?ref=$REF" "$TMP/$LIBS" ||
			die "download failed: $LIBS (${GET_ERR:-no reply}) - network dropped, or GitHub rate limit"
		read -r _l < "$TMP/$LIBS"
		case "$_l" in '#!'*) ;; *) die "$LIBS: not a script (bad token or ref?)" ;; esac
		sh -n "$TMP/$LIBS" || die "$LIBS: syntax check failed"
	fi
	# A ref from before LuCI app 1.2.7.3 has no tarball: its installer
	# carries the files itself and has no LUCI_TAR_SHA line.
	DATA=""
	_ts="$(sed -n 's/^LUCI_TAR_SHA="\([0-9a-f]*\)"$/\1/p' "$TMP/QoS-Ex-luci-app.sh" | head -n 1)"
	if [ -n "$_ts" ]; then
		DATA="$LUCI_TAR"
		_get "https://api.github.com/repos/$REPO/contents/$DATA?ref=$REF" "$TMP/$DATA" ||
			die "download failed: $DATA (${GET_ERR:-no reply}) - network dropped, or GitHub rate limit"
		[ "$(sha256sum "$TMP/$DATA" 2>/dev/null | cut -d' ' -f1)" = "$_ts" ] ||
			die "$DATA is not the one QoS-Ex-luci-app.sh names - an update is probably being published. Nothing installed; try again in a few minutes"
	fi

	# The release manifest lists the sha256 of every file and is committed
	# last, after all the files of an update. A set fetched while an update
	# is being pushed does not match it and is refused, so /root never gets
	# a mixed set. A ref from before the manifest existed has none: said,
	# and the files are used as they are.
	if _get "https://api.github.com/repos/$REPO/contents/SHA256SUMS?ref=$REF" "$TMP/SHA256SUMS"; then
		for f in $FILES $LIBS $DATA; do
			_want="$(awk -v f="$f" '$2 == f { print $1; exit }' "$TMP/SHA256SUMS")"
			_have="$(sha256sum "$TMP/$f" 2>/dev/null | cut -d' ' -f1)"
			[ -n "$_want" ] && [ "$_want" = "$_have" ] ||
				die "$f does not match the release manifest - an update is probably being published. Nothing installed; try again in a few minutes"
		done
	elif [ "$REF" = "main" ]; then
		die "could not fetch the release manifest SHA256SUMS (${GET_ERR:-no reply}) - nothing installed; try again"
	else
		# Only a ref that has none is let through unchecked.
		case "$GET_ERR" in
		*404*) _warn "no release manifest at $REF - files not checked against one" ;;
		*) die "could not fetch the release manifest SHA256SUMS (${GET_ERR:-no reply}) - nothing installed; try again" ;;
		esac
	fi

	# Run as a file (sh /root/QoS-Ex-install.sh), this is the installer of
	# the last update: hand over to the one just fetched, so a change in it
	# applies now, not one update later. Once only (QOS_EX_REEXEC); the token
	# goes in the environment, not on a command line.
	case "$0" in *install.sh)
		if [ -z "$QOS_EX_REEXEC" ] && [ "$OLDNAME" = 0 ] && [ -f "$0" ] &&
		   ! cmp -s "$0" "$TMP/QoS-Ex-install.sh"; then
			_info "the installer changed - running the new one"
			set -- -b "$REF"
			[ "$NOINST" = 1 ] && set -- "$@" -n
			[ "$ALL" = 1 ] && set -- "$@" -a
			GH_TOKEN="$TOKEN" QOS_EX_REEXEC=1 sh "$TMP/QoS-Ex-install.sh" "$@"
			exit $?
		fi ;;
	esac

	# Token proven good: keep it for later runs.
	if [ -n "$TOKEN" ] && [ "$TOKEN" != "$_saved" ]; then
		mkdir -p "${TOKEN_FILE%/*}"
		( umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE" ) && chmod 600 "$TOKEN_FILE"
	fi

	# All verified before any lands in /root: never a mixed set. $TMP is
	# tmpfs and /root the overlay, so a mv between them is a copy: the set is
	# copied beside /root first (room checked), then each file renamed into
	# place - a rename on one filesystem, so a full flash leaves /root as it
	# was, and a running /root/QoS-Ex-install.sh keeps its old inode.
	_need=$(du -sck "$TMP" 2>/dev/null | awk 'END { print $1 + 0 }')
	_free=$(df -kP "$DEST" 2>/dev/null | awk 'NR == 2 { print $4 }')
	case "$_free" in ''|*[!0-9]*) ;; *)
		[ "$_free" -ge $((_need + 64)) ] ||
			die "not enough free space in $DEST: ${_need} KB needed, ${_free} KB free - nothing changed; make room and run this again" ;;
	esac
	STAGE="$(mktemp -d "$DEST/.qos-ex-new.XXXXXX")" && mkdir -p "$STAGE/lib" "$DEST/lib" ||
		die "cannot write $DEST"
	for f in $FILES $LIBS $DATA; do
		cp "$TMP/$f" "$STAGE/$f" || die "cannot write $DEST (flash full?) - nothing changed"
	done
	for f in $FILES; do
		chmod 755 "$STAGE/$f" && mv -f "$STAGE/$f" "$DEST/$f" || die "cannot write $DEST/$f"
	done
	for f in $LIBS $DATA; do
		chmod 644 "$STAGE/$f" && mv -f "$STAGE/$f" "$DEST/$f" || die "cannot write $DEST/$f"
	done
	rm -rf "$STAGE"; STAGE=""
	# The old name, once this one is in place (a ref from before the rename
	# has no QoS-Ex-install.sh and never gets here).
	[ "$OLDNAME" = 1 ] || rm -f "$DEST/install.sh"
	_got=$(_vl "$DEST")
	_ok "downloaded and checked: $_got"

	[ "$NOINST" = 1 ] && { _info "download only (-n): the files are in $DEST, nothing installed"; exit 0; }

	# Install only the parts that changed, judged by content, not VERSION:
	# the shaper and PingFilter are installed as byte copies, the LuCI app
	# stamps its installer's sha256 in its stylesheet. A change pushed
	# without a version bump is then still installed, and /root never ends
	# up ahead of /usr/sbin. -a, or no backend yet, does all three.
	# s/p/u = shaper / PingFilter / LuCI app, 1 = install.
	_css=/www/luci-static/resources/qos-ex/qos-ex.css
	_ip="$(_ver /usr/sbin/qos-ex-pf.sh)"
	_il="$(sed -n '1s/.*qos-ex-luci v\([0-9][0-9.]*\).*/\1/p' "$_css" 2>/dev/null)"
	_ih="$(sed -n '1s/.*qos-ex-luci v[0-9.]* #\([0-9a-f]*\).*/\1/p' "$_css" 2>/dev/null)"
	_lh="$(sha256sum "$DEST/QoS-Ex-luci-app.sh" 2>/dev/null | cut -c1-10)"
	_s=1; _p=1; _u=1
	if [ "$ALL" = 0 ] && [ -x /usr/sbin/qos-ex.sh ]; then
		cmp -s "$DEST/QoS-Ex.sh" /usr/sbin/qos-ex.sh 2>/dev/null && _s=0
		[ -z "$LIBS" ] || cmp -s "$DEST/$LIBS" /usr/lib/qos-ex/install.sh 2>/dev/null || _s=1
		cmp -s "$DEST/QoS-Ex-PF.sh" /usr/sbin/qos-ex-pf.sh 2>/dev/null && _p=0
		[ -n "$_lh" ] && [ "$_lh" = "$_ih" ] && _u=0
	fi
	cd "$DEST" || die "cannot cd $DEST"
	# stdin from /dev/null throughout: when piped, nothing below may read
	# the pipe. An SSH session dropped mid-install must not kill it part-way:
	# this shell survives the hang-up (a trap, not an ignore, so the daemons
	# started below keep their own HUP handling) and each step runs in its
	# own session (setsid), out of the terminal's reach.
	trap ':' HUP
	_ss=""; command -v setsid >/dev/null 2>&1 && _ss=setsid
	case "$_s$_p$_u" in
	000)
		_ok "already up to date - nothing to install (-a reinstalls all three)"
		_log INFO "already up to date ($_src) - $_got"
		_ref_done
		exit 0 ;;
	1*)
		# The shaper installer runs the other two unless told they are
		# unchanged. It stops everything itself; the stop here only covers a
		# backend too old to be found by it (quiet: its report is not ours).
		_skip=""; [ "$_p" = 0 ] && _skip="pf"; [ "$_u" = 0 ] && _skip="$_skip luci"
		# A failed install leaves it stopped: what is installed is started
		# again if it was running, not left off until the next reboot.
		_was=0; [ -f /var/run/qos-ex-started ] && _was=1
		[ -x /usr/sbin/qos-ex.sh ] && $_ss /usr/sbin/qos-ex.sh stop >/dev/null 2>&1 </dev/null 8>&-
		# It prints the rest of the run, the result and the next step
		# included; QOS_EX_FETCHED: under this run's heading, not its own.
		QOS_EX_FETCHED=1 QOS_EX_SKIP="$_skip" $_ss sh QoS-Ex.sh install </dev/null 8>&- || {
			_rc=$?; _r=""
			if [ "$_was" = 1 ] && [ -x /usr/sbin/qos-ex.sh ]; then
				_r=" - QoS-Ex started again"
				$_ss /usr/sbin/qos-ex.sh start >/dev/null 2>&1 </dev/null 8>&- ||
					_r=" - QoS-Ex could not be started again"
			fi
			die "install failed - see the XX lines above (shaper installer, exit $_rc)$_r"
		}
		;;
	*)
		# Shaper unchanged: it keeps running, nothing is restarted but the
		# Ping Filter daemon (unless QoS-Ex is down or PF was stopped by hand).
		_info "shaper v$(_ver /usr/sbin/qos-ex.sh) unchanged"
		if [ "$_p" = 1 ]; then
			_l="Ping Filter $(_vv "$_ip" "$(_ver QoS-Ex-PF.sh)")"
			if [ -f /var/run/qos-ex-started ] && [ ! -f /var/run/qos-ex-pingfilter/.stopped ]; then
				_run "$_l, restarted" $_ss sh -c 'sh QoS-Ex-PF.sh install && /usr/sbin/qos-ex-pf.sh restart' </dev/null 8>&- ||
					die "Ping Filter install or restart failed - see the lines above"
			else
				_run "$_l" $_ss sh QoS-Ex-PF.sh install </dev/null 8>&- || die "Ping Filter install failed - see the lines above"
			fi
		else
			_info "Ping Filter v$_ip unchanged"
		fi
		if [ "$_u" = 1 ]; then
			_run "LuCI app $(_vv "$_il" "$(_ver QoS-Ex-luci-app.sh)")" $_ss sh QoS-Ex-luci-app.sh install </dev/null 8>&- ||
				die "LuCI app install failed - see the lines above"
		else
			_info "LuCI app v$_il unchanged"
		fi
		;;
	esac

	# The installers said yes: check what is installed IS what was fetched,
	# for each part installed this run.
	_bad=""
	[ "$_s" = 0 ] || cmp -s "$DEST/QoS-Ex.sh" /usr/sbin/qos-ex.sh || _bad="$_bad shaper"
	[ "$_s" = 0 ] || [ -z "$LIBS" ] || cmp -s "$DEST/$LIBS" /usr/lib/qos-ex/install.sh || _bad="$_bad shaper-lib"
	[ "$_p" = 0 ] || cmp -s "$DEST/QoS-Ex-PF.sh" /usr/sbin/qos-ex-pf.sh || _bad="$_bad PingFilter"
	[ "$_u" = 0 ] || [ "$(sed -n '1s/.*qos-ex-luci v[0-9.]* #\([0-9a-f]*\).*/\1/p' "$_css" 2>/dev/null)" = "$_lh" ] ||
		_bad="$_bad LuCI-app"
	[ -z "$_bad" ] || die "installed files do not match the download:$_bad - run: sh /root/QoS-Ex-install.sh -a"
	# The shaper's installer ends its run with the result; without it, this.
	if [ "$_s" = 0 ]; then
		printf '%sQoS-Ex updated: %s%s\n' "$_G" "$(_vl)" "$_0"
		[ "$_u" = 1 ] && echo "  Next: log in to LuCI again - the app was reinstalled."
	fi
	# By module: LuCI app (1.x), Ping Filter (2.x), shaper (3.x).
	_log INFO "OK ($_src) - installed:$( [ "$_u" = 1 ] && echo " LuCI app v$(_ver "$DEST/QoS-Ex-luci-app.sh")")$( [ "$_p" = 1 ] && echo " PingFilter v$(_ver /usr/sbin/qos-ex-pf.sh)")$( [ "$_s" = 1 ] && echo " shaper v$(_ver /usr/sbin/qos-ex.sh)")"
	_ref_done
	exit 0
}

# What is installed came from $REF: the Maintenance tab reads it to tell a
# branch switch from an update. A branch (main, dev) is also the one
# updates follow from now on, as if picked on System -> Maintenance, so an
# install with -b from SSH does not leave LuCI on the other one.
_ref_done() {
	mkdir -p /etc/qos-ex 2>/dev/null
	echo "$REF" > /etc/qos-ex/installed-ref 2>/dev/null
	case "$REF" in main|dev)
		[ -f /etc/config/qos-ex ] && [ "$(uci -q get qos-ex.settings.update_branch)" != "$REF" ] &&
			uci -q set qos-ex.settings.update_branch="$REF" && uci -q commit qos-ex ;;
	esac
	return 0
}

main "$@"
