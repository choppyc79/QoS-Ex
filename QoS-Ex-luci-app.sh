#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# QoS-Ex LuCI app installer (client-side JS LuCI)
#
# Installs the app's files from qos-ex-luci.tar.gz, which QoS-Ex-install.sh keeps
# beside this script. Their source is luci/ in the repo (see luci/README.md).
#
# Every file below is written with plain redirection, so the mode comes
# from the ambient umask. rpcd execs $RPCD_DIR/qos-ex as root; a permissive
# umask inherited from a nested caller would make that shim group- or
# world-writable. Pin it before the first write.
umask 022

VERSION="1.3.9.9"
# The app's files, and the sha256 of the tarball this installer was released
# with. tools/mkluci.sh writes the hash. Besides these files, only Leaflet
# (the map library, install_leaflet) is installed.
LUCI_TAR="qos-ex-luci.tar.gz"
LUCI_TAR_SHA="9b17e7b92303316b142bfeb5fa921d45313d6ba6202094646ff6b78fd59180ac"
# $VERSION is spliced into sed replacements (qos-ex.css and every view) and into
# VTOK, which becomes part of every generated filename. A '/' would terminate
# the s-command and an '&' would expand to the whole match, so assert the
# character set once here rather than trusting it at each use site.
case "$VERSION" in
	''|*[!0-9.]*)
		printf 'QoS-Ex-luci: VERSION must be digits and dots only, got "%s"\n' "$VERSION" >&2
		exit 1
		;;
esac
# Version scheme: <module>.<major>.<minor>.<patch>. The leading digit is a
# fixed module id and never changes -- 3 = shaper, 2 = Ping Filter, 1 = LuCI
# app -- so a version string names its own script on sight. The three fields
# after it are the odometer: patch 10 -> minor+1, minor 10 -> major+1.
# Rendered as v$VERSION at every human-facing site.
# VTOK and __CACHEBUST__ consume $VERSION verbatim.
# App id. Drives the resource and view directories, and matches the
# menu/ACL filenames and the rpcd object name.
APP="qos-ex"
# The backend has exactly ONE installed location, and the rpcd shim in the
# tarball hardcodes it. The installer MUST name the same path:
# through 1.0.2.2 this probed /root and $0's directory too, so a backend left
# in /root satisfied pre-flight, got its +x bit set, and the operator was told
# the install was clean -- while the shim went on calling /usr/sbin/qos-ex.sh and
# every RPC in the dashboard failed. One path, asserted in one place.
QOS_EX_BIN="/usr/sbin/qos-ex.sh"
UCI_CFG="/etc/config/qos-ex"

MENU_DIR="/usr/share/luci/menu.d"
ACL_DIR="/usr/share/rpcd/acl.d"
RPCD_DIR="/usr/libexec/rpcd"
RES_DIR="/www/luci-static/resources/$APP"
TILE_DIR="/www/luci-static/resources/view/status/include"
TILE_FILE="35_qos-ex.js"
LEAFLET_KEEP="/var/run/qos-ex-leaflet"
VIEW_DIR="/www/luci-static/resources/view/$APP"
# Cache-bust token, derived from this file's own content in install_all.
# Declared here so the emitters that splice it into filenames and menu paths
# read a defined empty value rather than an unset one when called standalone.
VTOK=""
# Where the tarball is unpacked for this run (luci_src).
SRC=""
# First 10 hex of this file's sha256 (install_all): the token and the CSS stamp.
SELF_SHA=""
# View files install_views wrote; tokenize_views must rename as many.
N_VIEWS=0

################################################################################
### SSH CONSOLE OUTPUT                                                       ###
################################################################################
# This script is only ever run from a shell -- by hand, or nested inside
# `QoS-Ex.sh install`, which shows our output only when we warn or fail. Same
# flat vocabulary as the backend: one header, one line per outcome (ok / !!),
# one result line. Colour only when stdout is a TTY (QOS_EX_NO_COLOR=1 forces
# plain). Per-artefact lines are COUNTED, not printed; QOS_EX_VERBOSE=1 lists
# them for debugging a bad generate.
UI_B=""; UI_D=""; UI_G=""; UI_Y=""; UI_0=""
# One command substitution, not five: on an 880MHz MT7621 each subshell is
# real money and this runs before we even know the verb. Capture ESC once and
# assemble the sequences with parameter expansion. ($@ is left alone here --
# MAIN dispatches on "$1".)
if [ -t 1 ] && [ "${QOS_EX_NO_COLOR:-0}" != "1" ]; then
	UI_E=$(printf '\033')
	UI_B="${UI_E}[1m";  UI_D="${UI_E}[2m"
	UI_G="${UI_E}[32m"; UI_Y="${UI_E}[33m"
	UI_0="${UI_E}[0m"
fi
UI_FILES=0
UI_WARNS=0

ui_head() {   # $1 = verb
	UI_FILES=0; UI_WARNS=0
	printf '%sQoS-Ex-luci v%s %s%s\n' "$UI_B" "$VERSION" "$1" "$UI_0"
}
ui_ok()   { printf '  %sok%s  %s\n' "$UI_G" "$UI_0" "$*"; }
ui_warn() { UI_WARNS=$((UI_WARNS + 1)); printf '  %s!!%s  %s\n' "$UI_Y" "$UI_0" "$*"; }
# One generated artefact. Counted always, printed only under QOS_EX_VERBOSE=1.
ui_file() {
	UI_FILES=$((UI_FILES + 1))
	[ "${QOS_EX_VERBOSE:-0}" = "1" ] && printf '  %s..  + %s%s\n' "$UI_D" "$*" "$UI_0"
	return 0
}

################################################################################
### LuCI cache flush                                                         ###
################################################################################
flush_luci() {
	# Clear LuCI's code/template caches so the new views load.
	#
	# rpcd is RELOADED, not restarted -- the step luci.mk's postinst runs for
	# every LuCI package. reload is SIGHUP: rpcd freezes its sessions, re-execs
	# itself (rescanning /usr/libexec/rpcd/* and the ACL files, so the new shim
	# and ACL are seen) and thaws them again. Through 1.0.8.9 this was a
	# restart, which dropped every LuCI session and logged the operator out on
	# each install.
	#
	# The web server is NOT restarted. Nothing we write is read by uhttpd at
	# start: the views and CSS live under /www and are served from disk per
	# request, the menu JSON is covered by the indexcache sweep below, and the
	# ACL is rpcd's. Through 1.0.2.2 this restarted uhttpd anyway, and the only
	# things it bought were a dropped session and 502s on whatever requests
	# were in flight.
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* \
	       /tmp/luci-templatecache* /tmp/luci-store* 2>/dev/null
	rm -f  /tmp/.luci-* 2>/dev/null
	[ -x /etc/init.d/rpcd ] || return 0
	# Non-zero when rpcd did not reload or did not come back with the app:
	# the callers used to print "rpcd reloaded" whatever happened here.
	_fl=0
	/etc/init.d/rpcd reload >/dev/null 2>&1 || _fl=1
	# Block on the object actually registering rather than sleeping a guess:
	# on a loaded MT7621 the old flat 1s was both too long in the common case
	# and, occasionally, too short. Only meaningful after install -- on
	# uninstall the shim is gone and the object is never coming back.
	if [ "${1:-install}" = "install" ]; then
		ubus -t 5 wait_for "$APP" >/dev/null 2>&1 || _fl=1
	fi
	# Log every LuCI session out (1.1.0.2) so the next click lands on the
	# login page and the fresh load pulls the new menu, ACL and views -- no
	# manual cache clear or private window. After an uninstall too (1.2.7.5):
	# the browser keeps the menu for the session, so QoS-Ex stayed under
	# Network and opened a 404. Done through rpcd's own session
	# object: the reload above stays (a restart would also 502 in-flight
	# requests). The all-zero id is rpcd's anonymous session, never ours.
	# An update from the Maintenance tab (QOS_EX_KEEP_SESSIONS=1) leaves
	# that to its job, which logs out once the update has ended, so the page
	# can follow it to the end.
	if [ "${QOS_EX_KEEP_SESSIONS:-0}" = 1 ] && [ "${1:-install}" = install ]; then
		: > /var/run/qos-ex-logout
		return "$_fl"
	fi
	ubus -t 5 wait_for session >/dev/null 2>&1
	ubus call session list 2>/dev/null \
		| sed -n 's/.*"ubus_rpc_session": *"\([0-9a-f]\{32\}\)".*/\1/p' \
		| while read -r sid; do
			[ "$sid" = "00000000000000000000000000000000" ] && continue
			ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1
		done
	return "$_fl"
}

################################################################################
### The app's files (qos-ex-luci.tar.gz)                                     ###
################################################################################
# LUCI_TAR_SHA pins the tarball this installer was released with: anything
# else is refused, so a part-fetched or older set is never installed.
luci_tar_ok() {
	[ -n "$LUCI_TAR_SHA" ] && [ -s "$1" ] &&
		[ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$LUCI_TAR_SHA" ]
}

# Unpack the tarball to $SRC (in /tmp, removed at the end of install_all).
# It is looked for beside this script, then in /root.
luci_src() {
	local here t r tried="" tar=""
	here="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"
	for t in "$here/$LUCI_TAR" "/root/$LUCI_TAR"; do
		luci_tar_ok "$t" && { tar="$t"; break; }
	done
	if [ -z "$tar" ]; then
		# Not there, or not this release's: this script arrived without it
		# (fetched by an install.sh from before 1.2.7.3, or copied by hand).
		# QoS-Ex-install.sh -n downloads the whole set into /root and installs
		# nothing (install.sh is its name before 1.2.7.4). Tried more than
		# once: an old one fetches the current
		# one first.
		for t in "$here/QoS-Ex-install.sh" /root/QoS-Ex-install.sh "$here/install.sh" /root/install.sh; do
			[ -f "$t" ] || continue
			# Run from /root, $here and /root name the same file: once each.
			r="$(readlink -f "$t" 2>/dev/null || echo "$t")"
			case " $tried " in *" $r "*) continue ;; esac
			tried="$tried $r"
			printf '  %s..  %s not found - downloading the release files with %s -n%s\n' "$UI_D" "$LUCI_TAR" "$t" "$UI_0"
			sh "$t" -n >/dev/null 2>&1 </dev/null
			luci_tar_ok "/root/$LUCI_TAR" && { tar="/root/$LUCI_TAR"; break; }
		done
	fi
	[ -n "$tar" ] || {
		ui_warn "$LUCI_TAR (the app's files) is missing or is not this version's - run: sh /root/QoS-Ex-install.sh"
		return 1
	}
	SRC="$(mktemp -d /tmp/qos-ex-luci.XXXXXX)" || { SRC=""; ui_warn "mktemp failed"; return 1; }
	tar -xzf "$tar" -C "$SRC" 2>/dev/null && [ -s "$SRC/usr/libexec/rpcd/qos-ex" ] || {
		ui_warn "could not unpack $tar (/tmp full?)"
		rm -rf "$SRC"; SRC=""
		return 1
	}
	return 0
}

################################################################################
### Menu (luci-app-qos-ex.json)                                              ###
################################################################################
# wrote <path> -- assert an installed file actually landed, and only then
# count it. Every write here is a plain redirection into /usr/share or /www;
# on a 16MB MT7621 with a full overlay those fail, cat spills to stderr, and
# through 1.0.2.2 the installer went on to print a success banner over a
# half-installed app. ui_file used to run BEFORE the write, so the closing
# "N files generated" line counted attempts, not files.
wrote() {
	if [ -s "$1" ]; then
		ui_file "$1"
		return 0
	fi
	ui_warn "write failed (disk full? read-only?): $1"
	return 1
}

install_menu() {
	mkdir -p "$MENU_DIR"
	cat "$SRC/usr/share/luci/menu.d/luci-app-qos-ex.json" > "$MENU_DIR/luci-app-qos-ex.json"
	wrote "$MENU_DIR/luci-app-qos-ex.json" || return 1

	# Suffix $VTOK onto every view module path (the leaf after qos-ex/...), so
	# the menu points LuCI at the tokened JS filenames written by
	# tokenize_views. Only "type": "view" entries carry a "path": "qos-ex/...
	# value, so matching that prefix alone is both sufficient and independent
	# of key order -- the old pattern spelled out `"type": "view", "path": "`
	# and would have silently stopped cache-busting if the file were ever
	# reformatted. "firstchild" nodes and the route keys are left alone, so
	# existing bookmarks keep working.
	[ -n "$VTOK" ] || return 0
	# $VTOK is spliced unescaped into the replacement below. It is folded to
	# [0-9A-Za-z_] where it is built, in install_all, and nothing else asserts
	# it. Assert it here, next to the use.
	case "$VTOK" in
		*[!0-9A-Za-z_]*|'')
			ui_warn "cache-bust token is not alphanumeric ('$VTOK') - menu left untokened"
			return 1
			;;
	esac
	sed -i \
		"s#\(\"path\": \"qos-ex/[^\"]*\)\"#\1_${VTOK}\"#g" \
		"$MENU_DIR/luci-app-qos-ex.json"
	grep -q "_${VTOK}\"" "$MENU_DIR/luci-app-qos-ex.json" || {
		ui_warn "cache-bust not applied to the menu - views will 404"
		return 1
	}
	return 0
}
################################################################################
### ACL (luci-app-qos-ex.json)                                               ###
################################################################################
# The read section grants exactly one file entry: list on /sys/class/net, which
# the Setup view's Line tab needs for the WAN selector. Nothing else goes
# through the ubus "file" object at all -- the logs arrive via the shim's
# logdump/nfterr methods and conntrack via its conntrack method -- so through
# 1.0.2.2 the four read.file paths granted here, /proc/net/nf_conntrack
# included, were a root-side read of the whole connection table handed to
# every holder of this ACL for nothing. A blanket ubus file:[list,read,stat]
# would be worse still: that is an unrestricted read of any path on the box.
#
# The qos-ex methods are enumerated rather than "*" so that a method added to
# the shim later is not auto-granted, and so the reporting half cannot be
# used to act: everything that changes state -- action, pf_action, pf_run,
# pf_set_home, cfg_import, update_cfg, update_run and
# uninstall_run -- lives only under write. No luci.* methods are granted: no
# view calls getInitList or setInitAction, and setInitAction acts on ANY init
# script, which is far wider than this app needs (service control goes through
# the shim's action method). Keep this list
# in step with the shim's `list` output; anything missing here is a silent
# "Access denied" in the browser console.
#
# No ubus "uci" methods are granted here: Save & Apply uses the ones luci-base
# gives every LuCI login (set, apply, confirm ...), and the uci scope below is
# what limits them to this config. Through 1.2.1.0 this file also granted
# apply and commit; nothing calls commit, and it skipped the apply rollback.
#
# UCI read is qos-ex only. Through 1.0.8.9 it also granted "network", which
# no view loads -- and which holds PPPoE passwords and WireGuard private
# keys, readable by anyone this ACL was delegated to.
install_acl() {
	mkdir -p "$ACL_DIR"
	cat "$SRC/usr/share/rpcd/acl.d/luci-app-qos-ex.json" > "$ACL_DIR/luci-app-qos-ex.json"
	wrote "$ACL_DIR/luci-app-qos-ex.json" || return 1
	return 0
}

################################################################################
### ubus shim (/usr/libexec/rpcd/qos-ex)                                     ###
################################################################################
install_rpcd_shim() {
	mkdir -p "$RPCD_DIR"
	cat "$SRC/usr/libexec/rpcd/qos-ex" > "$RPCD_DIR/qos-ex"
	wrote "$RPCD_DIR/qos-ex" || return 1
	chmod 0755 "$RPCD_DIR/qos-ex"
	return 0
}

################################################################################
### Static CSS                                                               ###
################################################################################
install_css() {
	mkdir -p "$RES_DIR"
	# Line 1 carries the version and this installer's sha256 (10 hex):
	# QoS-Ex-install.sh reads the hash to tell whether the app needs reinstalling.
	sed "1s/__VERSION__/v$VERSION #$SELF_SHA/; s/__VERSION__/v$VERSION/g" \
		"$SRC/www/luci-static/resources/qos-ex/qos-ex.css" > "$RES_DIR/qos-ex.css"
	wrote "$RES_DIR/qos-ex.css" || return 1
}

################################################################################
### Views (shared helpers + 11 pages)                                        ###
################################################################################
# Every .js under the tarball's view/qos-ex/, written under the same name.
# __CACHEBUST__ (the qos-ex.css link in _helpers.js) and __VERSION__ are
# filled in on the way to disk. The cache-bust value is the shared install
# token ($VTOK), so CSS and view JS bust together; the fallback is $VERSION,
# not an epoch, which would re-fetch the CSS on every run.
# Returns the number of files that did not write.
install_views() {
	local v="www/luci-static/resources/view/$APP" cb="${VTOK:-$VERSION}" f d bad=0
	N_VIEWS=0
	mkdir -p "$VIEW_DIR/pingfilter"
	for f in "$SRC/$v"/*.js "$SRC/$v"/pingfilter/*.js; do
		[ -f "$f" ] || continue
		d="$VIEW_DIR/${f#"$SRC/$v/"}"
		sed -e "s/__CACHEBUST__/$cb/g" -e "s/__VERSION__/v$VERSION/g" "$f" > "$d"
		if wrote "$d"; then N_VIEWS=$((N_VIEWS + 1)); else bad=$((bad + 1)); fi
	done
	return "$bad"
}

# Leaflet for the map page, fetched once and checked against the published
# 1.9.4 hashes. Best effort: with no internet at install the map falls back
# to the same pinned copy from the CDN.
install_leaflet() {
	local f sum want
	for f in js:db49d009c841f5ca34a888c96511ae936fd9f5533e90d8b2c4d57596f4e5641a \
	         css:a7837102824184820dfa198d1ebcd109ff6d0ff9a2672a074b9a1b4d147d04c6; do
		want=${f#*:}; f="leaflet.${f%%:*}"
		if [ -s "$LEAFLET_KEEP/$f" ]; then cp "$LEAFLET_KEEP/$f" "$RES_DIR/$f.tmp"
		else wget -q -T 10 -O "$RES_DIR/$f.tmp" "https://unpkg.com/leaflet@1.9.4/dist/$f" 2>/dev/null; fi
		sum=$(sha256sum "$RES_DIR/$f.tmp" 2>/dev/null | cut -d' ' -f1)
		# Both or neither: the script without its stylesheet was reported
		# as "not downloaded" while leaflet.js stayed on the router.
		[ "$sum" = "$want" ] || { rm -f "$RES_DIR"/leaflet.js.tmp "$RES_DIR"/leaflet.css.tmp; return 1; }
	done
	mv -f "$RES_DIR/leaflet.js.tmp" "$RES_DIR/leaflet.js" &&
		mv -f "$RES_DIR/leaflet.css.tmp" "$RES_DIR/leaflet.css" ||
		{ rm -f "$RES_DIR"/leaflet.js* "$RES_DIR"/leaflet.css*; return 1; }
}

# A QoS-Ex box on LuCI's own Status -> Overview page.
install_status_tile() {
	local dst="$TILE_DIR/${TILE_FILE%.js}${VTOK:+_$VTOK}.js"
	mkdir -p "$TILE_DIR" 2>/dev/null || return 1
	# The file name carries the token as the views do (1.2.8.4). LuCI lists
	# this directory and requires whatever .js it finds, with ONE failed
	# require failing the whole Status page -- and under a fixed name the
	# browser kept the previous release's tile (uhttpd sends no
	# Cache-Control), which then asked for a helpers module that this
	# install had just deleted.
	rm -f "$TILE_DIR/${TILE_FILE%.js}"*.js 2>/dev/null
	# The tile lives outside $VIEW_DIR, so tokenize_views never sees it: its
	# helpers require is pointed at the tokened module here (1.2.6.5 left
	# the plain name and the Status page failed with a 404 on _helpers.js).
	sed "s#view\.qos-ex\._helpers as h#view.qos-ex._helpers${VTOK:+_$VTOK} as h#" \
		"$SRC/www/luci-static/resources/view/status/include/$TILE_FILE" > "$dst"
	wrote "$dst" || return 1
}

################################################################################
### TOP-LEVEL                                                                ###
################################################################################
# Append $VTOK to every view JS filename and rewrite the shared-helpers require
# so each view resolves the tokened helpers module. Run AFTER install_views
# (views are written to plain names first, then renamed here). install_all wipes
# $VIEW_DIR at the start, so old tokened files never accumulate.
tokenize_views() {
	[ -n "$VTOK" ] || return 0
	[ -d "$VIEW_DIR" ] || return 0

	# 1. Point every view's `require view.qos-ex._helpers` at the tokened module.
	#    (_helpers.js itself has no such require, so skip it.)
	for f in "$VIEW_DIR"/*.js "$VIEW_DIR"/pingfilter/*.js; do
		[ -f "$f" ] || continue
		case "$f" in */_helpers.js) continue ;; esac
		sed -i "s#view\.qos-ex\._helpers as h#view.qos-ex._helpers_${VTOK} as h#g" "$f" || return 1
	done

	# 2. Rename the shared helpers baseclass first.
	if [ -f "$VIEW_DIR/_helpers.js" ]; then
		mv "$VIEW_DIR/_helpers.js" "$VIEW_DIR/_helpers_${VTOK}.js" || return 1
	fi

	# 3. Rename every remaining view, preserving its subdirectory.
	for f in "$VIEW_DIR"/*.js "$VIEW_DIR"/pingfilter/*.js; do
		[ -f "$f" ] || continue
		d=$(dirname "$f"); b=$(basename "$f" .js)
		case "$b" in _helpers_*) continue ;; esac   # already tokened in step 2
		mv "$f" "$d/${b}_${VTOK}.js" || return 1
	done

	# 4. Count what landed: every file install_views wrote must carry the
	#    token, and the menu must name one tokened view per file bar the
	#    helpers module -- a partial rename leaves the menu naming files
	#    that are not there. Both numbers are measured (a fixed 15 through
	#    1.2.8.3 made a new view an install failure).
	_ntok=0
	for f in "$VIEW_DIR"/*_"$VTOK".js "$VIEW_DIR"/pingfilter/*_"$VTOK".js; do
		[ -f "$f" ] && _ntok=$((_ntok + 1))
	done
	[ "$_ntok" -gt 0 ] && [ "$_ntok" -eq "$N_VIEWS" ] || {
		ui_warn "tokenised $_ntok view files, expected $N_VIEWS - views will 404"
		return 1
	}
	_nmenu=$(grep -c "\"path\": \"qos-ex/[^\"]*_${VTOK}\"" "$MENU_DIR/luci-app-qos-ex.json" 2>/dev/null)
	[ "$((${_nmenu:-0} + 1))" -eq "$_ntok" ] || {
		ui_warn "menu names ${_nmenu:-0} tokenised views, $((_ntok - 1)) are on disk - views will 404"
		return 1
	}
	return 0
}

install_all() {
	ui_head "install"

	# The rpcd shim execs the backend directly, so it MUST be executable.
	# File transfers (web download, copy-paste) routinely drop the +x bit,
	# producing "Permission denied" at rpcd call time. Fixed here, at install,
	# rather than at parse time: `uninstall`, `version` and `help` have no
	# business touching the filesystem. Absolute mode, not +x, so the result
	# does not depend on the caller's umask.
	[ -f "$QOS_EX_BIN" ] && chmod 0755 "$QOS_EX_BIN" 2>/dev/null
	[ -f "$0" ]       && chmod 0755 "$0"       2>/dev/null

	# This file's own hash names the release: it is the cache-bust token and
	# the stamp QoS-Ex-install.sh reads back from the stylesheet. Piped in
	# (sh -s install <file) there is no file to hash, and the app went in
	# untokened with an empty stamp, to be reinstalled on every later run.
	SELF_SHA=$(sha256sum "$0" 2>/dev/null | cut -c1-10)
	case "$SELF_SHA" in
		[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
		*)
			ui_warn "cannot read this installer as a file - run it by path: sh /root/QoS-Ex-luci-app.sh install"
			printf '%sQoS-Ex-luci v%s NOT installed: nothing was changed%s\n' "$UI_Y" "$VERSION" "$UI_0" >&2
			return 1
			;;
	esac

	# The files to install, BEFORE anything installed is removed: without
	# them the app that is there now stays as it is.
	luci_src || {
		printf '%sQoS-Ex-luci v%s NOT installed: nothing was changed%s\n' "$UI_Y" "$VERSION" "$UI_0" >&2
		return 1
	}
	# The fetcher was install.sh until 1.2.7.4. A current copy that an older
	# one saved under that name takes its new name.
	[ -f /root/install.sh ] && grep -q 'QoS-Ex-install\.sh' /root/install.sh 2>/dev/null &&
		mv -f /root/install.sh /root/QoS-Ex-install.sh 2>/dev/null

	# Room for the new files, checked BEFORE the old ones are removed: on a
	# full overlay the old app was deleted first and the new one then failed
	# part-way, leaving neither. Needed = the new copies of the three big
	# items; there = free space on the filesystem holding /www plus what
	# removing the old copies of the same three gives back (so a reinstall
	# needs next to nothing). A df that cannot be read is no reason to refuse.
	_need=$(du -sck "$SRC/www/luci-static/resources/$APP" "$SRC/www/luci-static/resources/view/$APP" \
		"$SRC/usr/libexec/rpcd/qos-ex" 2>/dev/null | awk 'END { print $1 + 0 }')
	_free=$(df -kP "${RES_DIR%/luci-static/*}" 2>/dev/null | awk 'NR == 2 { print $4 }')
	_old=$(du -sck "$RES_DIR" "$VIEW_DIR" "$RPCD_DIR/qos-ex" 2>/dev/null | awk 'END { print $1 + 0 }')
	case "$_need$_free" in
		''|*[!0-9]*) ;;
		*)
			if [ -n "$_need" ] && [ -n "$_free" ] && [ "$((_free + ${_old:-0}))" -lt "$((_need + 16))" ]; then
				ui_warn "not enough free space: the app needs ${_need} KB, $((_free + ${_old:-0})) KB would be free - make room and run this again"
				rm -rf "$SRC"; SRC=""
				printf '%sQoS-Ex-luci v%s NOT installed: nothing was changed%s\n' "$UI_Y" "$VERSION" "$UI_0" >&2
				return 1
			fi
			;;
	esac

	# Cache-bust token. It is suffixed onto every view JS filename and onto the
	# matching menu "path" values (see tokenize_views and install_menu), because
	# LuCI's own resource_version only moves when luci-base is upgraded and so
	# never busts a same-version app reinstall.
	# The token is derived from the CONTENT of this installer, which names
	# the tarball by its hash, so the same release always yields the same
	# filenames -- a reinstall is then idempotent instead of churning the whole
	# view tree and invalidating every bookmarked URL -- while ANY edit, a
	# version bump or a hand-patch alike, yields a new token and forces every
	# browser to refetch. Epoch+PID (used through 1.0.2.0) could not do that:
	# it changed on every run whether or not a single byte had.
	# The token is spliced into view filenames and into the dotted
	# view.qos-ex._helpers_<tok> require path, where a dot is a separator, so
	# it is folded to alphanumerics and underscores only.
	VTOK="$(echo "$VERSION" | sed 's/[^0-9A-Za-z]/_/g')"
	VTOK="${VTOK}_${SELF_SHA}"
	# Validate once, here, rather than trusting the fold above: install_menu
	# and tokenize_views must make the SAME decision, or the menu names files
	# that are not on disk. An unusable token degrades both to "no tokenising"
	# instead of tokenising one half.
	case "$VTOK" in
		*[!0-9A-Za-z_]*|'')
			ui_warn "unusable cache-bust token ('$VTOK') - installing untokened"
			VTOK=""
			;;
	esac
	[ -f "$QOS_EX_BIN" ] || ui_warn "$QOS_EX_BIN not found - install the backend first (QoS-Ex.sh install)"
	[ -f "$UCI_CFG" ] || ui_warn "$UCI_CFG missing - run '$QOS_EX_BIN install' to seed it"
	[ -f "${RES_DIR%/"$APP"}/luci.js" ] || ui_warn "LuCI (luci-base) not found - the app is written but cannot load without it"

	rm -f  "$MENU_DIR/luci-app-qos-ex.json" 2>/dev/null
	rm -f  "$ACL_DIR/luci-app-qos-ex.json"  2>/dev/null
	rm -f  "$RPCD_DIR/qos-ex"               2>/dev/null
	rm -rf "$VIEW_DIR"                   2>/dev/null
	rm -rf "$LEAFLET_KEEP"; mkdir -p "$LEAFLET_KEEP"
	cp "$RES_DIR"/leaflet.js "$RES_DIR"/leaflet.css "$LEAFLET_KEEP"/ 2>/dev/null
	rm -rf "$RES_DIR"                    2>/dev/null
	rm -f  /usr/libexec/qos-ex-menu-refresh /tmp/qos-ex-menu-refresh.log 2>/dev/null
	rm -rf /tmp/luci-modulecache* /tmp/luci-indexcache* \
	       /tmp/luci-templatecache* 2>/dev/null

	_fail=0
	install_menu       || _fail=$((_fail + 1))
	install_acl        || _fail=$((_fail + 1))
	install_rpcd_shim  || _fail=$((_fail + 1))
	install_css        || _fail=$((_fail + 1))
	[ "$_fail" -eq 0 ] || ui_warn "$_fail of 4 framework files did not write - see above"

	# install_views returns how many files did not land (disk full,
	# read-only overlay). Through 1.0.2.2 the ok lines below printed
	# regardless, so a half-installed app still ended on a green banner.
	install_views; _vfail=$?
	[ "$_vfail" -eq 0 ] || ui_warn "$_vfail view files did not write - the app will be incomplete"
	_fail=$((_fail + _vfail))
	# UI_FILES counts every artefact written since ui_head, framework included.
	install_status_tile || _fail=$((_fail + 1))
	[ "$_fail" -eq 0 ] && ui_ok "menu, ACL, rpcd shim, CSS + $N_VIEWS view files + Status tile ($UI_FILES files)"
	if install_leaflet; then ui_ok "map library stored on the router"
	else ui_warn "map library not downloaded - the map page loads it from the internet instead"; fi
	rm -rf "$LEAFLET_KEEP" "$SRC"; SRC=""

	# install_menu tokenised the menu first; tokenize_views renames the JS
	# here. If the two halves disagree -- a failed rename, a partial run,
	# a token rejected by one and not the other -- every page in the app is a
	# blank panel with a 404 in the console, and through 1.0.2.2 the installer
	# reported success anyway. tokenize_views now counts what it renamed and
	# returns non-zero on a mismatch.
	tokenize_views || _fail=$((_fail + 1))

	if flush_luci install; then
		if [ "${QOS_EX_KEEP_SESSIONS:-0}" = 1 ]; then
			ui_ok "rpcd reloaded, LuCI caches flushed, LuCI sessions logged out when the update ends"
		else
			ui_ok "rpcd reloaded, LuCI caches flushed, LuCI sessions logged out"
		fi
	else
		ui_warn "rpcd did not come back with the app - run: /etc/init.d/rpcd restart, then log in to LuCI again"
		_fail=$((_fail + 1))
	fi

	logger -t QoS-Ex-luci "LuCI app installed v$VERSION (JS framework)"
	if [ "$_fail" -eq 0 ]; then
		printf '%sQoS-Ex-luci v%s installed - log in to LuCI again: Network > QoS-Ex%s\n' "$UI_G" "$VERSION" "$UI_0"
	else
		printf '%sQoS-Ex-luci v%s install INCOMPLETE: %s artefact(s) failed%s\n' \
			"$UI_Y" "$VERSION" "$_fail" "$UI_0" >&2
	fi
	[ "$_fail" -eq 0 ]
}

install_uninstall_stub() {
	mkdir -p "$MENU_DIR"
	cat > "$MENU_DIR/luci-app-qos-ex.json" <<'STUBEOF'
{
	"admin/network/qos-ex":                       { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/autosetup":             { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/overview":              { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/shaper":                { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/rules":                 { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/settings":              { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/qdisc":                 { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/classification":        { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/nft":                   { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/status":                { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/stats":                 { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/flows":                 { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/connections":           { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/advanced":              { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/advanced/status":       { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/advanced/logs":         { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/advanced/maintenance":  { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/pingfilter":            { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/pingfilter/dashboard":  { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/pingfilter/settings":   { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/pingfilter/map":        { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/pingfilter/serverlist": { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/pingfilter/lists":      { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/pingfilter/advanced":   { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/pingfilter/servers":    { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/live":                  { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/live/stats":            { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/live/flows":            { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/setup":                 { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/setup/shaper":          { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/setup/rules":           { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/system":                { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/system/status":         { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/system/logs":           { "action": { "type": "alias", "path": "admin/status/overview" } },
	"admin/network/qos-ex/system/maintenance":    { "action": { "type": "alias", "path": "admin/status/overview" } }
}
STUBEOF
	wrote "$MENU_DIR/luci-app-qos-ex.json" || return 1
}

uninstall_all() {
	ui_head "uninstall"

	# The only unrecoverable operation in this file is the rm -rf below, and
	# both its targets are built from $APP. Assert the shape rather than trust
	# it: an empty or unexpected $APP would make these /www/luci-static/
	# resources/ and .../resources/view/ wholesale.
	if [ -z "$APP" ] ||
	   [ "$RES_DIR"  != "/www/luci-static/resources/$APP" ] ||
	   [ "$VIEW_DIR" != "/www/luci-static/resources/view/$APP" ]; then
		case "${QOS_EX_ALLOW_ODD_PATHS:-0}" in
			1) ;;
			*) ui_warn "RES_DIR/VIEW_DIR are not the expected qos-ex paths - aborting"
			   return 1 ;;
		esac
	fi

	rm -f  "$ACL_DIR/luci-app-qos-ex.json"
	rm -f  "$RPCD_DIR/qos-ex"
	rm -f  /usr/libexec/qos-ex-menu-refresh /tmp/qos-ex-menu-refresh.log
	rm -f  /var/run/qos-ex-update.json /var/log/qos-ex-update.log /var/log/qos-ex-uninstall.log \
	       /tmp/qos-ex-update.json /tmp/qos-ex-update.log
	rm -rf "$RES_DIR"
	rm -rf "$VIEW_DIR"
	rm -f  "$TILE_DIR/${TILE_FILE%.js}"*.js

	# Menu entries are cached in the browser; without a stub every bookmarked
	# /admin/network/qos-ex/* URL 404s instead of landing somewhere sane.
	install_uninstall_stub
	ui_ok "ACL, rpcd shim, CSS, views removed (menu stub redirects old URLs)"

	if flush_luci uninstall; then
		ui_ok "rpcd reloaded, LuCI caches flushed, LuCI sessions logged out"
	else
		ui_warn "rpcd did not reload - run: /etc/init.d/rpcd restart"
	fi

	logger -t QoS-Ex-luci "LuCI app removed (redirect stub left at $MENU_DIR/luci-app-qos-ex.json)"
	printf '%sQoS-Ex-luci v%s removed%s - backend + config untouched\n' "$UI_G" "$VERSION" "$UI_0"
	return 0
}

################################################################################
### MAIN                                                                     ###
################################################################################
# Single-instance guard for the two mutating verbs. install writes about 20
# files across four shared registries, so a hand-run overlapping the nested
# `QoS-Ex.sh install` call would interleave a sweep with a generate. FD 9,
# non-blocking, released on exit.
# Not taken for version/help, which touch nothing.
qos_ex_lock() {
	# "Could not lock" and "got the lock" must not be the same outcome: a
	# failure warns rather than proceeding unguarded in silence. /var/run,
	# not /tmp or /var/lock: both are world-writable on OpenWrt, so another
	# user could hold the lock file there.
	# The path is probed in a subshell, never on `exec` itself: redirections
	# on a bare exec are permanent, so `exec 9>file 2>/dev/null` left stderr
	# on /dev/null for the rest of the run ("already running" and "install
	# INCOMPLETE" never reached the terminal), and a failed open ended the
	# shell before the fallback could run.
	_lk=/var/run/qos-ex-luci.lock
	mkdir -p /var/run 2>/dev/null
	( : >>"$_lk" ) 2>/dev/null || {
		printf 'QoS-Ex-luci: cannot create a lock file - running unguarded\n' >&2
		return 0
	}
	exec 9>>"$_lk"
	command -v flock >/dev/null 2>&1 || {
		printf 'QoS-Ex-luci: flock not available - running unguarded\n' >&2
		return 0
	}
	flock -n 9 2>/dev/null || {
		printf 'QoS-Ex-luci: another install/uninstall is already running\n' >&2
		exit 1
	}
}

case "${1:-help}" in
	install)   qos_ex_lock; install_all ;;
	uninstall) qos_ex_lock; uninstall_all ;;
	version)   printf 'QoS-Ex-luci v%s (JS framework)\n' "$VERSION" ;;
	*)
		cat <<EOF
QoS-Ex-luci v$VERSION — installer (JS framework) for $QOS_EX_BIN
Usage: $0 {install|uninstall|version}

Installs from $LUCI_TAR, kept beside this script (sh /root/QoS-Ex-install.sh
fetches both).

Files installed:
  $MENU_DIR/luci-app-qos-ex.json        (menu tree)
  $ACL_DIR/luci-app-qos-ex.json         (rpcd ACL)
  $RPCD_DIR/qos-ex                      (ubus shim → qos-ex.sh)
  $RES_DIR/qos-ex.css                   (shared stylesheet)
  $RES_DIR/leaflet.{js,css}             (map library, best effort)
  $TILE_DIR/${TILE_FILE%.js}_<token>.js  (box on Status > Overview)

Every view ships with a cache-bust token appended to its filename, so the
names on disk are _helpers_<token>.js, overview_<token>.js and so on. The
token (QOS_EX_VERBOSE=1 install lists the files) is derived from this file's
contents, so it only changes with a new release.

  $VIEW_DIR/_helpers_<token>.js      (RPC declarations + parsers)
  $VIEW_DIR/{overview,setup,stats,flows,status,logs,maintenance}_<token>.js
  $VIEW_DIR/pingfilter/{dashboard,map,servers,settings}_<token>.js

Pages (Network -> QoS-Ex):
  Overview · Ping Filter · Live · Setup · System
  └─ Ping Filter: Dashboard · Map · Servers · Settings
  └─ Live: Stats · Flows
  └─ System: Status · Logs · Maintenance

Uninstall behaviour:
  Leaves a tiny redirect stub at $MENU_DIR/luci-app-qos-ex.json so that stale
  /admin/network/qos-ex/* URLs alias to /admin/status/overview instead of
  returning 404. To purge: rm $MENU_DIR/luci-app-qos-ex.json /tmp/luci-indexcache*
EOF
		case "${1:-help}" in help|-h|--help) ;; *) exit 1 ;; esac
		;;
esac
