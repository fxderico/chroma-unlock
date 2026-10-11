TARGET := iphone:clang:latest:14.0
ARCHS := arm64
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := chromaunlock

chromaunlock_FILES := Sources/Unlock.x
chromaunlock_CFLAGS := -fobjc-arc
chromaunlock_FRAMEWORKS := Foundation UIKit
# Pure runtime swizzling in a constructor, so no Substrate dependency is linked into the IPA.
chromaunlock_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk
