TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

# Built as a plain dylib; the app loads it itself (load command added by build_app_deb.py).
LIBRARY_NAME = FlappyHats
FlappyHats_FILES = Hats.x Voice.x Tick.x Store.m
FlappyHats_LIBRARIES = substrate
FlappyHats_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AVFoundation AudioToolbox
FlappyHats_CFLAGS = -Wall -fobjc-arc

include $(THEOS)/makefiles/library.mk
