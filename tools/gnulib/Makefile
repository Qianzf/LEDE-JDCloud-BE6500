include $(TOPDIR)/rules.mk

PKG_NAME:=gnulib
PKG_CPE_ID:=cpe:/a:gnu:$(PKG_NAME)

PKG_VERSION:=2026.07.04~b22f5a30
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.zst

PKG_SOURCE_URL=git://git.git.savannah.gnu.org/$(PKG_NAME).git
PKG_SOURCE_DATE:=2026-07-04
PKG_SOURCE_VERSION:=b22f5a3037712a3c957a03071ce0b219cef4d65b# # stable-202507
PKG_MIRROR_HASH:=d1423a784794e3e08bd03b397544821ece257aa748566386bd97219d1edf98d5

include $(INCLUDE_DIR)/host-build.mk

define Host/Configure
endef

define Host/Install
	$(call Host/Uninstall)
	$(INSTALL_DIR) $(1)/share/aclocal
	$(INSTALL_DATA) $(HOST_BUILD_DIR)/m4/*.m4 $(1)/share/aclocal/
	# gnulib 的 cond.m4 与 automake 的 cond.m4 同名：前者只定义 gl_COND，
	# 后者定义 AM_CONDITIONAL，而 aclocal 对同名 *.m4 只采用第一个命中的。
	# 装进 share/aclocal 后会遮蔽 automake 的那份，导致 autoreconf 报
	# "possibly undefined macro: AM_CONDITIONAL" / "cannot find required
	# auxiliary files: ar-lib"（dcwapd 等 autotools 包因此构建失败）。
	# 换个文件名：仍会被 aclocal 扫描（gl_COND 不丢），但不再遮蔽。
	[ ! -f $(1)/share/aclocal/cond.m4 ] || \
		mv -f $(1)/share/aclocal/cond.m4 $(1)/share/aclocal/gnulib-cond.m4
	$(CP) $(HOST_BUILD_DIR)/ $(1)/share/gnulib/
	ln -sf ../share/gnulib/gnulib-tool $(STAGING_DIR_HOST)/bin/gnulib-tool
endef

define Host/Uninstall
	rm -rf $(STAGING_DIR_HOST)/bin/gnulib-tool $(STAGING_DIR_HOST)/share/gnulib
	rm -f $(STAGING_DIR_HOST)/share/aclocal/gl_*.m4 \
		$(STAGING_DIR_HOST)/share/aclocal/cond.m4 \
		$(STAGING_DIR_HOST)/share/aclocal/gnulib-cond.m4
endef

$(eval $(call HostBuild))
