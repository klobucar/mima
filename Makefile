EXECUTABLE_NAME = mima
BUILD_PATH = .build/release/$(EXECUTABLE_NAME)
DEBUG_PATH = .build/debug/$(EXECUTABLE_NAME)
SIGNING_IDENTITY ?= -

.PHONY: all build debug clean install

all: build

build:
	swift build -c release
	codesign --force --sign $(SIGNING_IDENTITY) --identifier "com.mima.cli" --entitlements entitlements.plist $(BUILD_PATH)
	@echo "✅ Built and signed release binary at $(BUILD_PATH)"

debug:
	swift build
	codesign --force --sign $(SIGNING_IDENTITY) --identifier "com.mima.cli" --entitlements entitlements.plist $(DEBUG_PATH)
	@echo "✅ Built and signed debug binary at $(DEBUG_PATH)"

install: build
	cp $(BUILD_PATH) /usr/local/bin/$(EXECUTABLE_NAME)
	@echo "✅ Installed to /usr/local/bin/$(EXECUTABLE_NAME)"

clean:
	rm -rf .build
