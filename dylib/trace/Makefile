THEOS ?= $(CURDIR)/../../theos
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BubbleTrace
BubbleTrace_FILES = BubbleTrace.m
BubbleTrace_CFLAGS = -fobjc-arc
BubbleTrace_FRAMEWORKS = Foundation UIKit
BubbleTrace_LDFLAGS = -install_name @rpath/BubbleTrace.dylib

include $(THEOS_MAKE_PATH)/tweak.mk
