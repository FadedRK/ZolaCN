THEOS ?= $(CURDIR)/../theos
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZolaCN
ZolaCN_FILES = Tweak.xm TranslationsData.m
ZolaCN_CFLAGS = -fobjc-arc
ZolaCN_FRAMEWORKS = Foundation
ZolaCN_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
