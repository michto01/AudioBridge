SHELL := /bin/bash
BUILD_CONFIGURATION ?= debug
DIST_DIR ?= dist
APP := $(DIST_DIR)/AudioBridge.app
SWIFT_BUILD_OPTIONS ?=
export SWIFT_BUILD_OPTIONS

.PHONY: doctor build test probe app run sign verify release clean
.NOTPARALLEL:

doctor:
	@xcode-select -p
	@xcrun --find swift
	@swift --version
	@xcrun --sdk macosx --show-sdk-path

build:
	swift build -c $(BUILD_CONFIGURATION) $(SWIFT_BUILD_OPTIONS)

test:
	BUILD_CONFIGURATION="$(BUILD_CONFIGURATION)" ./scripts/test.sh

probe:
	swift run -c $(BUILD_CONFIGURATION) $(SWIFT_BUILD_OPTIONS) AudioBridgeProbe

app: build
	BUILD_CONFIGURATION="$(BUILD_CONFIGURATION)" DIST_DIR="$(DIST_DIR)" ./scripts/package-app.sh

run: sign
	/bin/bash ./scripts/run-app.sh "$(APP)"

sign: app
	./scripts/sign-app.sh "$(APP)"

verify:
	./scripts/verify-app.sh "$(APP)"

release:
	$(MAKE) BUILD_CONFIGURATION=release DIST_DIR="$(DIST_DIR)" sign
	$(MAKE) DIST_DIR="$(DIST_DIR)" verify
	cd "$(DIST_DIR)" && ditto --norsrc -c -k --keepParent AudioBridge.app AudioBridge-macOS.zip
	/usr/bin/shasum -a 256 "$(DIST_DIR)/AudioBridge-macOS.zip" | tee "$(DIST_DIR)/AudioBridge-macOS.zip.sha256"

clean:
	swift package clean
	@echo "Build products cleaned; dist artifacts retained for review."
