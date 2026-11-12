# SPDX-License-Identifier: GPL-3.0-or-later
#
# OpenWrt package for QoS-Ex: build it into your own firmware, or make an
# installable package with the SDK. How to use it: docs/BUILD.md.
#
# The package carries the three scripts, the shaper's lib/install.sh, the
# LuCI app's files (qos-ex-luci.tar.gz), QoS-Ex-install.sh and the check
# script (qos-ex-check.sh) in /usr/lib/qos-ex, plus a first-run
# script. That script copies them to /root and runs the
# normal installer (sh /root/QoS-Ex.sh install), so a packaged install ends
# up exactly like a script install.

include $(TOPDIR)/rules.mk

PKG_NAME:=qos-ex
# Version and dependencies are read from QoS-Ex.sh, so they cannot drift.
PKG_VERSION:=$(shell sed -n 's/^VERSION="\([0-9.]*\)".*/\1/p' $(CURDIR)/QoS-Ex.sh | head -n 1)
PKG_RELEASE:=1
# tcpdump-mini is left out: full tcpdump stands in for it (PKG_ALT in
# QoS-Ex.sh), and the two install the same file, so a hard dependency failed
# the install on a router that has full tcpdump. The first-run install adds
# tcpdump-mini when neither is there.
QOS_EX_DEPS:=$(filter-out tcpdump-mini,$(shell sed -n 's/^PKG_DEPS_BACKEND="\(.*\)"$$/\1/p' $(CURDIR)/QoS-Ex.sh))

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Ash Clarke <clarkeaj@hotmail.co.uk>

include $(INCLUDE_DIR)/package.mk

define Package/qos-ex
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Gaming traffic shaper and game-server ping filter
  URL:=https://github.com/choppyc79/QoS-Ex
  DEPENDS:=+firewall4 $(addprefix +,$(QOS_EX_DEPS))
  PKGARCH:=all
endef

define Package/qos-ex/description
  HFSC / HTB / CAKE shaping with a low-latency gaming class, a Ping Filter
  that grades and can block game servers, and a LuCI app (Network > QoS-Ex).
  Add the luci package to your build if you want the web app.
endef

# Shell scripts only: nothing to compile.
define Build/Compile
endef

define Package/qos-ex/install
	$(INSTALL_DIR) $(1)/usr/lib/qos-ex/lib $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./QoS-Ex.sh ./QoS-Ex-PF.sh ./QoS-Ex-luci-app.sh ./QoS-Ex-install.sh ./qos-ex-check.sh $(1)/usr/lib/qos-ex/
	$(INSTALL_DATA) ./qos-ex-luci.tar.gz $(1)/usr/lib/qos-ex/
	$(INSTALL_DATA) ./lib/install.sh $(1)/usr/lib/qos-ex/lib/
	$(INSTALL_BIN) ./files/qos-ex.defaults $(1)/etc/uci-defaults/90-qos-ex
endef

# Removing the package removes what its first-run install put in place
# (service, hooks, LuCI app, Ping Filter); the settings and server history
# stay, as with `qos-ex.sh uninstall keep`. Not on an upgrade: opkg runs the
# old package's prerm then too (PKG_UPGRADE=1), and the uninstall left the
# router unshaped and autostart reset until the new first-run install ran.
# apk runs pre-deinstall on removal only.
define Package/qos-ex/prerm
#!/bin/sh
[ "$${PKG_UPGRADE}" = 1 ] && exit 0
[ -n "$${IPKG_INSTROOT}" ] || { [ -x /usr/sbin/qos-ex.sh ] && /usr/sbin/qos-ex.sh uninstall keep >/dev/null 2>&1; }
true
endef

$(eval $(call BuildPackage,qos-ex))
