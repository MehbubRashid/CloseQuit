# CloseQuit: command-line build.
#
#   make            generate the Xcode project and build Release into ./build
#   make install    build, copy to /Applications and launch it
#   make release    build and zip the app for a GitHub release (build/CloseQuit-<version>.zip)
#   make test       run the unit tests
#   make open       open the generated project in Xcode
#   make clean      delete the build folder and the generated project

APP_NAME    := CloseQuit
PROJECT     := $(APP_NAME).xcodeproj
CONFIG      ?= Release
DERIVED     := build
APP         := $(DERIVED)/Build/Products/$(CONFIG)/$(APP_NAME).app
INSTALL_DIR ?= /Applications
DESTINATION := platform=macOS,arch=arm64
VERSION     := $(shell sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9][0-9.]*)"?.*/\1/p' project.yml | head -1)
ZIP         := $(DERIVED)/$(APP_NAME)-$(VERSION).zip
# Config/Local.xcconfig (git-ignored) overrides Config/Signing.xcconfig.
TEAM        := $(shell sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/p' \
                 Config/Signing.xcconfig Config/Local.xcconfig 2>/dev/null | tail -1)

.PHONY: all build install release test open project check-team clean

all: build

project:
	@command -v xcodegen >/dev/null || { echo "XcodeGen is missing. Install it with: brew install xcodegen"; exit 1; }
	@xcodegen generate --quiet

check-team:
	@if [ -z "$(TEAM)" ]; then \
		echo "error: no Apple Team ID set. Create Config/Local.xcconfig with your 10-character Team ID:"; \
		echo "         echo 'DEVELOPMENT_TEAM = AB12CD34EF' > Config/Local.xcconfig"; \
		echo "       (Xcode ▸ Settings ▸ Accounts shows it.) CloseQuit isn't built ad hoc, because"; \
		echo "       macOS would then forget its Accessibility permission after every rebuild."; \
		exit 1; \
	fi

build: project check-team
	xcodebuild -project $(PROJECT) -scheme $(APP_NAME) -configuration $(CONFIG) \
		-destination '$(DESTINATION)' -derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates -quiet build
	@codesign -dvv "$(APP)" 2>&1 | grep -E '^(Authority=Apple Development|TeamIdentifier)' || true
	@echo "Built $(APP)"

install: build
	@pkill -x $(APP_NAME) 2>/dev/null && sleep 1 || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@ditto "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"
	@open "$(INSTALL_DIR)/$(APP_NAME).app"

release: build
	@rm -f "$(ZIP)"
	@ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ZIP)"
	@echo "Release archive: $(ZIP)"
	@shasum -a 256 "$(ZIP)"

# Tests only exercise the decision rules (no app, no permissions), so with no team set
# they run unsigned. The app itself is never built that way.
test: project
	xcodebuild -project $(PROJECT) -scheme $(APP_NAME)Tests -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) $(if $(TEAM),-allowProvisioningUpdates,CODE_SIGNING_ALLOWED=NO) -quiet test

open: project
	@open $(PROJECT)

clean:
	rm -rf $(DERIVED) $(PROJECT)
