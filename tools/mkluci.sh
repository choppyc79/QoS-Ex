#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Packs the LuCI app's files (luci/usr, luci/www) into qos-ex-luci.tar.gz and
# writes that tarball's sha256 into QoS-Ex-luci-app.sh (LUCI_TAR_SHA), which
# installs from it. Run from the repo root after editing anything in luci/,
# then commit the tarball and the installer together.
#
#   sh tools/mkluci.sh          pack (only if luci/ changed) and stamp
#   sh tools/mkluci.sh check    exit 1 unless the tarball holds exactly the
#                               files in luci/usr and luci/www and the
#                               installer names it
set -e

TAR=qos-ex-luci.tar.gz
INST=QoS-Ex-luci-app.sh
[ -d luci/www ] && [ -f "$INST" ] || { echo "mkluci: run from the repo root" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

sha() { sha256sum "$1" | cut -d' ' -f1; }
stamped() { sed -n 's/^LUCI_TAR_SHA="\([0-9a-f]*\)"$/\1/p' "$INST" | head -n 1; }
# Does the tarball hold exactly luci/usr and luci/www?
same() {
	[ -s "$TAR" ] || return 1
	rm -rf "$T/x"; mkdir "$T/x"
	tar -xzf "$TAR" -C "$T/x" 2>/dev/null || return 1
	diff -r luci/usr "$T/x/usr" >/dev/null 2>&1 && diff -r luci/www "$T/x/www" >/dev/null 2>&1 &&
		[ "$(ls "$T/x" | tr '\n' ' ')" = "usr www " ]
}

case "${1:-build}" in
build)
	if same; then
		echo "mkluci: $TAR already holds luci/"
	else
		# Sorted names fix the order. tar still records mtimes and
		# owners, so a repack elsewhere can hash differently: hence
		# repacking only when same() fails.
		( cd luci && find usr www -type f | LC_ALL=C sort ) > "$T/list"
		tar -C luci -cf - -T "$T/list" | gzip -n -9 > "$T/new.tar.gz"
		mv "$T/new.tar.gz" "$TAR"
		chmod 644 "$TAR"
		echo "mkluci: packed $(wc -l < "$T/list" | tr -d ' ') files into $TAR"
	fi
	h=$(sha "$TAR")
	if [ "$(stamped)" != "$h" ]; then
		grep -q '^LUCI_TAR_SHA="[0-9a-f]*"$' "$INST" || { echo "mkluci: no LUCI_TAR_SHA line in $INST" >&2; exit 1; }
		sed "s/^LUCI_TAR_SHA=\"[0-9a-f]*\"\$/LUCI_TAR_SHA=\"$h\"/" "$INST" > "$T/inst"
		sh -n "$T/inst"
		cat "$T/inst" > "$INST"
		echo "mkluci: $INST now names $h"
	fi
	;;
check)
	same || { echo "mkluci: $TAR does not hold what is in luci/ - run: sh tools/mkluci.sh" >&2; exit 1; }
	[ "$(stamped)" = "$(sha "$TAR")" ] || { echo "mkluci: $INST does not name this $TAR - run: sh tools/mkluci.sh" >&2; exit 1; }
	echo "mkluci: $TAR holds luci/ and $INST names it"
	;;
*)
	echo "usage: sh tools/mkluci.sh [build|check]" >&2
	exit 1
	;;
esac
