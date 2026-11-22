EXECUTABLE_NAME = mima
BUILD_DIR = .build/release
BUILD_PATH = $(BUILD_DIR)/$(EXECUTABLE_NAME)
DEBUG_PATH = .build/debug/$(EXECUTABLE_NAME)
APP = $(BUILD_DIR)/Mima.app

# "-" = ad-hoc: runs, but secrets are stored WITHOUT Touch ID protection.
# For Touch ID, pass an "Apple Development" identity from a paid team
# (security find-identity -v -p codesigning). scripts/sign.sh explains why.
SIGNING_IDENTITY ?= -
PREFIX ?= /usr/local

.PHONY: all build debug clean install uninstall

all: build

build:
	swift build -c release
	scripts/sign.sh "$(SIGNING_IDENTITY)" "$(BUILD_PATH)" "$(BUILD_DIR)"

debug:
	swift build
	scripts/sign.sh - "$(DEBUG_PATH)" .build/debug

# A Touch ID build is an app bundle in $(PREFIX)/libexec/mima, because only a
# bundle can carry the provisioning profile, plus a symlink in $(PREFIX)/bin.
# An ad-hoc build is a plain binary in $(PREFIX)/bin.
install: build
	mkdir -p "$(PREFIX)/bin"
	@if [ "$(SIGNING_IDENTITY)" = "-" ]; then \
		rm -f "$(PREFIX)/bin/$(EXECUTABLE_NAME)"; \
		install -m 755 "$(BUILD_PATH)" "$(PREFIX)/bin/$(EXECUTABLE_NAME)"; \
		echo "✅ Installed $(PREFIX)/bin/$(EXECUTABLE_NAME) (ad-hoc, no Touch ID)"; \
	else \
		mkdir -p "$(PREFIX)/libexec/mima"; \
		rm -rf "$(PREFIX)/libexec/mima/Mima.app"; \
		ditto "$(APP)" "$(PREFIX)/libexec/mima/Mima.app"; \
		ln -sfn "$(PREFIX)/libexec/mima/Mima.app/Contents/MacOS/$(EXECUTABLE_NAME)" "$(PREFIX)/bin/$(EXECUTABLE_NAME)"; \
		echo "✅ Installed $(PREFIX)/libexec/mima/Mima.app -> $(PREFIX)/bin/$(EXECUTABLE_NAME)"; \
		echo "   Verify with: mima doctor"; \
	fi

uninstall:
	rm -f "$(PREFIX)/bin/$(EXECUTABLE_NAME)"
	rm -rf "$(PREFIX)/libexec/mima/Mima.app"

clean:
	rm -rf .build
