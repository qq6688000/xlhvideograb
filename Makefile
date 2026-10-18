#
# XLHVideoGrab — 悬浮抓取网页视频链接
# 构建： make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
#

TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLHVideoGrab

XLHVideoGrab_FILES := Tweak.xm \
                      VGCommon.m \
                      VGManager.m \
                      VGOverlay.m \
                      VGDownloader.m \
                      VGScript.mm

XLHVideoGrab_CFLAGS := -fobjc-arc -O2 -Wall
XLHVideoGrab_FRAMEWORKS := Foundation UIKit WebKit CoreGraphics
XLHVideoGrab_LIBRARIES := substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 MobileSafari SpringBoard 2>/dev/null || true"
