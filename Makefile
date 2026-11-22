# HideRead: hide posts you've already read in the official Reddit app.
#
#   make package                                  rootless (Dopamine, palera1n rootless, ...)
#   make package ROOTFUL=1                        rootful (checkra1n, unc0ver, palera1n rootful, ...)
#   make package THEOS_PACKAGE_SCHEME=roothide    roothide Dopamine (needs roothide Theos)
#   make do                                       build, install over SSH and relaunch Reddit

TARGET := iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = RedditApp Reddit

ifeq ($(ROOTFUL),1)
  THEOS_PACKAGE_SCHEME =
else
  THEOS_PACKAGE_SCHEME ?= rootless
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HideRead

HideRead_FILES = Tweak.x $(wildcard Sources/*.m)
# Theos treats warnings as errors; don't let a newer SDK deprecating an API break the build.
HideRead_CFLAGS = -fobjc-arc -ISources -Wno-error=deprecated-declarations
HideRead_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
