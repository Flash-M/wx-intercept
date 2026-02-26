# Makefile — wx-intercept
# Builds a universal (x86_64 + arm64) dynamic library for macOS.
#
# Requirements: Xcode Command Line Tools  (clang, codesign)
# Usage:
#   make          — build WxIntercept.dylib
#   make clean    — remove build artefacts
#   make install  — build then run Scripts/install.sh
#   make uninstall — run Scripts/uninstall.sh

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
CC        = clang
CODESIGN  = codesign

# ---------------------------------------------------------------------------
# Product
# ---------------------------------------------------------------------------
PRODUCT   = WxIntercept.dylib

# ---------------------------------------------------------------------------
# Source files
# ---------------------------------------------------------------------------
SRCS      = Sources/WxIntercept.m \
            Sources/MessageCache.m

# ---------------------------------------------------------------------------
# Compiler flags
# ---------------------------------------------------------------------------
# -dynamiclib          : produce a .dylib
# -fobjc-arc           : enable ARC
# -arch x86_64 -arch arm64 : universal binary (Intel + Apple Silicon)
# -mmacosx-version-min : match WeChat's minimum macOS deployment target
CFLAGS    = -dynamiclib \
            -fobjc-arc \
            -arch x86_64 \
            -arch arm64 \
            -mmacosx-version-min=10.13 \
            -framework Foundation \
            -framework AppKit \
            -framework UserNotifications \
            -I Sources

# Optional: enable optimisation in release builds
ifdef RELEASE
  CFLAGS += -O2 -DNDEBUG
else
  CFLAGS += -g -O0
endif

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
.PHONY: all clean install uninstall

all: $(PRODUCT)

$(PRODUCT): $(SRCS)
	@echo "  CC   $@"
	$(CC) $(CFLAGS) -o $@ $(SRCS)
	@echo "  SIGN $@"
	$(CODESIGN) --force --sign - $@
	@echo "  Done: $@"
	@lipo -info $@

clean:
	rm -f $(PRODUCT)
	rm -rf $(PRODUCT).dSYM

install: $(PRODUCT)
	@bash Scripts/install.sh

uninstall:
	@bash Scripts/uninstall.sh
