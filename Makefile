TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Zalo

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZolaCN
ZolaCN_FILES = Tweak.xm
ZolaCN_CFLAGS = -fobjc-arc
ZolaCN_FRAMEWORKS = Foundation
ZolaCN_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
