#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Writes SHA256SUMS, the release manifest QoS-Ex-install.sh and the app's update
# check read: one "#v" line with the three versions, then a checksum per
# file. Run from the repo root after the scripts are final; commit it last.
# The LuCI tarball must already be packed from luci/ (sh tools/mkluci.sh).
set -e
sh tools/mkluci.sh check
ver() { sed -n 's/^VERSION="\([0-9.]*\)".*/\1/p' "$1" | head -n 1; }
{
	# By module: LuCI app (1.x), Ping Filter (2.x), shaper (3.x). Readers
	# take each by its key, so the order is only for people.
	printf '#v luci=%s pf=%s shaper=%s\n' "$(ver QoS-Ex-luci-app.sh)" "$(ver QoS-Ex-PF.sh)" "$(ver QoS-Ex.sh)"
	sha256sum QoS-Ex.sh lib/install.sh QoS-Ex-PF.sh QoS-Ex-luci-app.sh QoS-Ex-install.sh qos-ex-luci.tar.gz
} > SHA256SUMS.tmp
mv SHA256SUMS.tmp SHA256SUMS
cat SHA256SUMS
