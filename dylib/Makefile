THEOS ?= $(CURDIR)/../theos
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZolaCN
ZolaCN_FILES = TweakRaw.xm Settings/ZolaCNSettings.m AntiRecall/ZLCNAntiRecall.m AntiRecall/ZLCNMediaStoreRecall.m AntiRecall/ZLCNRecallToast.m AntiRecall/ZLCNRecallStateProbe.m AntiRecall/ZLCNRecallStateShield.m AntiRecall/ZLCNRecallActionBlocker.m TranslationsData.m
ZolaCN_CFLAGS = -fobjc-arc -DZLCNInterceptedLocalCacheRecallCount=ZLCNInterceptedLocalCacheCount
ZolaCN_FRAMEWORKS = Foundation UIKit
ZolaCN_LDFLAGS = -install_name @rpath/ZolaCN.dylib

include $(THEOS_MAKE_PATH)/tweak.mk
