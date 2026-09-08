# Cassette build commands. Run `make help`.

.PHONY: help setup build build-mac test lint check-cast ci run run-mac device logs archive-ios clean

.NOTPARALLEL:

PROJECT = Cassette.xcodeproj
SCHEME = Cassette
DERIVED_DATA = .build

# Personal device name lives in Makefile.local (gitignored).
-include Makefile.local
DEVICE_NAME ?= iPhone

# Bundle ID follows Config/Local.xcconfig when present, else the upstream default.
BUNDLE_ID = $(shell grep -hs '^CASSETTE_BUNDLE_ID' Config/Local.xcconfig Config/Cassette.xcconfig | head -1 | sed 's/.*= *//')

# First available iPhone simulator. Do not hardcode a UDID.
SIMULATOR_ID = $(shell xcrun simctl list devices available | grep -m1 "iPhone" | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
SIM_DEST = 'platform=iOS Simulator,id=$(SIMULATOR_ID)'

help:
	@echo "Cassette"
	@echo ""
	@echo "  make setup       - Create Config/Local.xcconfig and Makefile.local from the examples"
	@echo "  make build       - Build for the iOS simulator"
	@echo "  make build-mac   - Build the macOS app"
	@echo "  make test        - Run the unit tests on the iOS simulator"
	@echo "  make lint        - SwiftLint, strict (the same gate CI runs)"
	@echo "  make check-cast  - List the Cast receivers this machine can see"
	@echo "  make ci          - Everything CI runs: lint, both builds, tests"
	@echo "  make run         - Build and launch on the iOS simulator"
	@echo "  make run-mac     - Build and launch the macOS app"
	@echo "  make device      - Build, install and launch on a connected iPhone (DEVICE_NAME=...)"
	@echo "  make logs        - Relaunch on the device with its output attached"
	@echo "  make archive-ios - Build a signed iOS .xcarchive in $(DERIVED_DATA)"
	@echo "  make clean       - Remove build artifacts"

setup:
	@command -v xcodebuild >/dev/null 2>&1 || { echo "Error: Xcode required"; exit 1; }
	@test -f Config/Local.xcconfig || cp Config/Local.xcconfig.example Config/Local.xcconfig
	@test -f Makefile.local || cp Makefile.local.example Makefile.local
	@command -v swiftlint >/dev/null 2>&1 || brew install swiftlint
	@echo "Edit Config/Local.xcconfig (team, bundle ID, app group) and Makefile.local (device name)."

build:
	@echo "Building for simulator..."
	@xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination $(SIM_DEST) -derivedDataPath $(DERIVED_DATA) -quiet
	@echo "Build succeeded."

build-mac:
	@echo "Building for macOS..."
	@xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED_DATA) \
		-allowProvisioningUpdates -quiet
	@echo "Build succeeded."

test:
	@echo "Running tests..."
	@xcodebuild test -project $(PROJECT) -scheme CassetteTests \
		-destination $(SIM_DEST) -derivedDataPath $(DERIVED_DATA) -quiet
	@echo "Tests passed."

lint:
	@command -v swiftlint >/dev/null 2>&1 || { echo "error: swiftlint required (brew install swiftlint)"; exit 1; }
	@swiftlint lint --strict --quiet
	@echo "Lint clean."

# The whole gate in one command, in CI's order: lint first because it is seconds,
# so a style failure doesn't cost two builds first.
ci: lint build build-mac test
	@echo "All checks passed."

# Deliberately outside `make test`: no receivers means an empty room, not a defect.
check-cast:
	@./scripts/check-cast.sh

run: build
	@xcrun simctl boot $(SIMULATOR_ID) 2>/dev/null || true
	@open -a Simulator
	@APP_PATH=$$(find $(DERIVED_DATA) -name "$(SCHEME).app" -path "*/Debug-iphonesimulator/*" -type d | head -1) && \
		xcrun simctl install $(SIMULATOR_ID) "$$APP_PATH" && \
		xcrun simctl launch $(SIMULATOR_ID) $(BUNDLE_ID)

run-mac: build-mac
	@open $(DERIVED_DATA)/Build/Products/Debug/$(SCHEME).app

# Fail early with something readable: xcodebuild's own "no matching destination"
# error buries the cause under every simulator it does know about.
device:
	@STATE=$$(xcrun devicectl list devices 2>/dev/null | awk -v n="$(DEVICE_NAME)" '$$1 == n { print $$4 }'); \
	if [ -z "$$STATE" ]; then \
		echo "error: no paired device named '$(DEVICE_NAME)'."; \
		echo "Set DEVICE_NAME in Makefile.local to one of:"; \
		xcrun devicectl list devices 2>/dev/null | tail -n +3 | awk '{ print "  " $$1 }'; \
		exit 1; \
	elif [ "$$STATE" != "connected" ] && [ "$$STATE" != "available" ]; then \
		echo "error: '$(DEVICE_NAME)' is paired but $$STATE."; \
		echo "Connect it by cable, unlock it, and tap Trust if asked."; \
		echo "For Wi-Fi builds, tick 'Connect via network' in Xcode > Window > Devices and Simulators."; \
		exit 1; \
	fi
	@echo "Building for $(DEVICE_NAME)..."
	@xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=iOS,name=$(DEVICE_NAME)' \
		-derivedDataPath $(DERIVED_DATA) -allowProvisioningUpdates -quiet
	@echo "Installing on $(DEVICE_NAME)..."
	@xcrun devicectl device install app --device "$(DEVICE_NAME)" \
		$$(find $(DERIVED_DATA) -name "$(SCHEME).app" -path "*/Debug-iphoneos/*" -type d | head -1)
	@echo "Launching $(BUNDLE_ID)..."
	@xcrun devicectl device process launch --device "$(DEVICE_NAME)" $(BUNDLE_ID) 2>&1 | tail -3 \
		|| echo "note: installed fine, but could not launch it — unlock the phone and tap the app."

logs:
	@echo "Relaunching $(BUNDLE_ID) on $(DEVICE_NAME) attached to the console (Ctrl-C to stop)..."
	@xcrun devicectl device process launch --device "$(DEVICE_NAME)" --console $(BUNDLE_ID)

archive-ios:
	@xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' \
		-archivePath $(DERIVED_DATA)/$(SCHEME).xcarchive -allowProvisioningUpdates -quiet
	@echo "Archive: $(DERIVED_DATA)/$(SCHEME).xcarchive"

clean:
	@rm -rf $(DERIVED_DATA)
	@xcodebuild clean -project $(PROJECT) -scheme $(SCHEME) -quiet 2>/dev/null || true
