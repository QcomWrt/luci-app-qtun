include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-qtun
PKG_VERSION:=1.0.3
PKG_RELEASE:=1

PKG_MAINTAINER:=Azy <azyanggara2707@gmail.com>
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-qtun
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI interface for Q-Tunneling
  URL:=https://github.com/QcomWrt/luci-app-qtun
  # Tambahkan luci-compat agar jalan di OpenWrt 21, 22, 23
  DEPENDS:=+bash +curl +ca-bundle +ca-certificates +jq +luci-compat
  # JANGAN gunakan PKGARCH:=all karena ada binary di dalamnya
endef

define Package/luci-app-qtun/description
  Universal LuCI interface for Q-Tunneling with multi-core support.
endef

# Mapping ARCH untuk download core
# SDK OpenWrt biasanya mengirimkan ARCH seperti x86_64, aarch64, atau arm
ifneq ($(findstring x86_64,$(ARCH)),)
  M_ARCH:=amd64-compatible
  Q_ARCH:=amd64
  Z_ARCH:=amd64
else ifneq ($(findstring aarch64,$(ARCH)),)
  M_ARCH:=arm64
  Q_ARCH:=arm64
  Z_ARCH:=arm64
else ifneq ($(findstring arm,$(ARCH)),)
  M_ARCH:=armv7
  Q_ARCH:=armv7
  Z_ARCH:=arm
else
  M_ARCH:=amd64
  Q_ARCH:=amd64
  Z_ARCH:=amd64
endif

MIHOMO_VER:=v1.19.9
QLOAD_VER:=v1.0.0
ZIVPN_VER:=udp-zivpn_1.4.9
QSSH_VER:=v0.1.0

YACD_VER:=gh-pages
METACUBEXD_VER:=gh-pages

GEOIP_VER:=latest
GEOSITE_VER:=latest
MMDB_URL:=https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb
GEOIP_URL:=https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat
GEOSITE_URL:=https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat

define Build/Prepare
	$(call Build/Prepare/Default)
	mkdir -p $(PKG_BUILD_DIR)/cores
	mkdir -p $(PKG_BUILD_DIR)/ui/yacd
	mkdir -p $(PKG_BUILD_DIR)/ui/metacubexd
	mkdir -p $(PKG_BUILD_DIR)/data
	
	# Download Cores secara dinamis saat build
	curl -fL https://github.com/MetaCubeX/Mihomo/releases/download/$(MIHOMO_VER)/mihomo-linux-$(M_ARCH)-$(MIHOMO_VER).gz -o $(PKG_BUILD_DIR)/cores/clash.gz
	gunzip -f $(PKG_BUILD_DIR)/cores/clash.gz
	mv $(PKG_BUILD_DIR)/cores/clash $(PKG_BUILD_DIR)/cores/clash_core

	curl -fL https://github.com/QcomWrt/Q-load/releases/download/$(QLOAD_VER)/q-load-linux-$(Q_ARCH) -o $(PKG_BUILD_DIR)/cores/q-load
	curl -fL https://github.com/zahidbd2/udp-zivpn/releases/download/$(ZIVPN_VER)/udp-zivpn-linux-$(Z_ARCH) -o $(PKG_BUILD_DIR)/cores/zivpn
	curl -fL https://github.com/QcomWrt/Q-SSH-WORKER/releases/download/$(QSSH_VER)/Q-SSH-WORKER-linux-$(Q_ARCH) -o $(PKG_BUILD_DIR)/cores/Q-SSH-WORKER

	curl -fL https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/$(YACD_VER).tar.gz -o $(PKG_BUILD_DIR)/yacd.tar.gz
	tar -xzf $(PKG_BUILD_DIR)/yacd.tar.gz -C $(PKG_BUILD_DIR)
	cp -r $(PKG_BUILD_DIR)/Yacd-meta-$(YACD_VER)/* $(PKG_BUILD_DIR)/ui/yacd/

	curl -fL https://github.com/MetaCubeX/metacubexd/archive/refs/heads/$(METACUBEXD_VER).tar.gz -o $(PKG_BUILD_DIR)/metacubexd.tar.gz
	tar -xzf $(PKG_BUILD_DIR)/metacubexd.tar.gz -C $(PKG_BUILD_DIR)
	cp -r $(PKG_BUILD_DIR)/metacubexd-$(METACUBEXD_VER)/* $(PKG_BUILD_DIR)/ui/metacubexd/

	curl -fL $(MMDB_URL) -o $(PKG_BUILD_DIR)/data/geoip.metadb
	curl -fL $(GEOIP_URL) -o $(PKG_BUILD_DIR)/data/geoip.dat
	curl -fL $(GEOSITE_URL) -o $(PKG_BUILD_DIR)/data/geosite.dat
	
	chmod +x $(PKG_BUILD_DIR)/cores/*
endef

define Build/Compile
	true
endef

define Package/luci-app-qtun/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./etc/config/qtun $(1)/etc/config/qtun

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./etc/init.d/qtun_autoboot $(1)/etc/init.d/qtun_autoboot

	$(INSTALL_DIR) $(1)/etc/qtun/action
	$(INSTALL_BIN) ./etc/qtun/action/*.sh $(1)/etc/qtun/action/

	$(INSTALL_DIR) $(1)/etc/qtun/core
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/cores/clash_core $(1)/etc/qtun/core/clash
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/cores/q-load $(1)/etc/qtun/core/q-load
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/cores/zivpn $(1)/etc/qtun/core/zivpn
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/cores/Q-SSH-WORKER $(1)/etc/qtun/core/Q-SSH-WORKER

	$(INSTALL_DIR) $(1)/etc/qtun/config/clash/ui/yacd
	$(CP) $(PKG_BUILD_DIR)/ui/yacd/* $(1)/etc/qtun/config/clash/ui/yacd/

	$(INSTALL_DIR) $(1)/etc/qtun/config/clash/ui/metacubexd
	$(CP) $(PKG_BUILD_DIR)/ui/metacubexd/* $(1)/etc/qtun/config/clash/ui/metacubexd/

	$(INSTALL_DIR) $(1)/etc/qtun/config/clash
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/data/geoip.metadb $(1)/etc/qtun/config/clash/geoip.metadb
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/data/geoip.dat $(1)/etc/qtun/config/clash/geoip.dat
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/data/geosite.dat $(1)/etc/qtun/config/clash/geosite.dat

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci
	$(CP) ./usr/lib/lua/luci/* $(1)/usr/lib/lua/luci/
	
	# Copy sisa folder config dsb
	$(CP) ./etc/qtun/config $(1)/etc/qtun/
endef

$(eval $(call BuildPackage,luci-app-qtun))