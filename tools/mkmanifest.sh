#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Writes SHA256SUMS, the release manifest QoS-Ex-install.sh and the app's update
# check read: one "#v" line with the release and the three versions, then a
# checksum per file. Run from the repo root after the scripts are final;
# commit it last. The LuCI tarball must already be packed from luci/
# (sh tools/mkluci.sh).
#
#   sh tools/mkmanifest.sh          keeps the release number SHA256SUMS has
#   sh tools/mkmanifest.sh X.Y.Z    sets it: before a release's PR, the number
#                                   that release will have
#
# The release number (the GitHub release's tag without its v) is what the
# banner shows: QoS-Ex-install.sh keeps the one it installed. On dev it is
# the last release, until the next one's PR sets the next.
# Nothing is written for a set a router would refuse or choke on: a script
# with a CR byte (a Windows checkout) or a syntax error, a missing version or
# release number, or a checksum line not in the "<sha256>  <name>" form the
# readers take.
set -e
R=${1:-}
sh tools/mkluci.sh check
set -- QoS-Ex.sh lib/install.sh QoS-Ex-PF.sh QoS-Ex-luci-app.sh QoS-Ex-install.sh qos-ex-check.sh qos-ex-luci.tar.gz
ver() { sed -n 's/^VERSION="\([0-9.]*\)".*/\1/p' "$1" | head -n 1; }
no() { echo "mkmanifest: $* - SHA256SUMS not written" >&2; exit 1; }
for f in "$@"; do
	[ -f "$f" ] || no "$f is missing"
	case "$f" in *.sh) ;; *) continue ;; esac
	[ "$(tr -dc '\r' < "$f" | wc -c)" -eq 0 ] || no "$f has CR bytes"
	sh -n "$f" || no "$f fails sh -n"
done
L=$(ver QoS-Ex-luci-app.sh) P=$(ver QoS-Ex-PF.sh) S=$(ver QoS-Ex.sh)
[ -n "$L" ] && [ -n "$P" ] && [ -n "$S" ] || no "a VERSION= line is missing"
if [ -z "$R" ] && [ -f SHA256SUMS ]; then R=$(sed -n '1s/.* release=\([0-9][0-9.]*\).*/\1/p' SHA256SUMS); fi
[ -n "$R" ] || no "no release number in SHA256SUMS - give it: sh tools/mkmanifest.sh X.Y.Z"
case "$R" in
	*[!0-9.]*|.*|*.|*..*|*.*.*.*) no "release number '$R' is not X.Y.Z" ;;
	*.*.*) ;;
	*) no "release number '$R' is not X.Y.Z" ;;
esac
{
	# The release, then by module: LuCI app (1.x), Ping Filter (2.x),
	# shaper (3.x). Readers take each by its key (every router's update
	# check since the first public release), so the order is only for people.
	printf '#v release=%s luci=%s pf=%s shaper=%s\n' "$R" "$L" "$P" "$S"
	# Every reader takes the name as the second field: two spaces, never
	# the " *name" of binary mode (sha256sum on Git for Windows).
	sha256sum "$@" | sed 's/^\([0-9a-f]\{64\}\) [ *]/\1  /'
} > SHA256SUMS.tmp
awk -v n=$# 'NR > 1 && !(length($1) == 64 && $1 !~ /[^0-9a-f]/ && substr($0, 65, 2) == "  " && substr($0, 67, 1) != "*") { bad = 1 }
	END { exit (bad || NR != n + 1) }' SHA256SUMS.tmp \
	|| { rm -f SHA256SUMS.tmp; no "a checksum line is not in the form the readers take"; }
mv SHA256SUMS.tmp SHA256SUMS
cat SHA256SUMS
