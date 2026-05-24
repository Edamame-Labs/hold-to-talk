.PHONY: setup build install fresh-install verify package package-zip package-dmg package-permission-test-dmg \
 notarize notarize-app notarize-dmg release permissions-reset reset-fresh-test test-reset uninstall run clean

APP_NAME := HoldToTalk
APP_DISPLAY_NAME := Hold To Talk
APP_BUNDLE := .build/$(APP_DISPLAY_NAME).app
APP_INSTALL_DIR ?= /Applications
SIGNING_IDENTITY ?= -
DIST_DIR ?= dist
DMG_VOLUME_NAME ?= Hold To Talk $(VERSION)
APP_STORE ?= 0

VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
ZIP_NAME ?= $(APP_NAME)-v$(VERSION).zip
DMG_NAME ?= $(APP_NAME)-v$(VERSION).dmg
ZIP_PATH := $(DIST_DIR)/$(ZIP_NAME)
DMG_PATH := $(DIST_DIR)/$(DMG_NAME)
DMG_STAGING := .build/dmg-staging
NOTARY_TMP_ZIP := .build/$(APP_NAME)-notary.zip

ifeq ($(APP_STORE),1)
APP_ENTITLEMENTS := Resources/HoldToTalk.entitlements
else
SPARKLE_FRAMEWORK := $(shell swift build -c release --show-bin-path)/Sparkle.framework
APP_ENTITLEMENTS := $(if $(filter -,$(SIGNING_IDENTITY)),Resources/HoldToTalk.dev.entitlements,Resources/HoldToTalk.direct.entitlements)
endif

setup:
	@bash scripts/setup-sherpa-onnx.sh

build: setup
	APP_STORE="$(APP_STORE)" swift build -c release
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	@cp ".build/release/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	@cp Resources/HoldToTalk.icns "$(APP_BUNDLE)/Contents/Resources/"
	@cp Resources/PrivacyInfo.xcprivacy "$(APP_BUNDLE)/Contents/Resources/"
	@cp -R Resources/en.lproj "$(APP_BUNDLE)/Contents/Resources/"
	@if [ -d ".build/release/HoldToTalk_HoldToTalk.bundle" ]; then \
		cp -R ".build/release/HoldToTalk_HoldToTalk.bundle" "$(APP_BUNDLE)/Contents/Resources/"; \
	elif [ -d ".build/arm64-apple-macosx/release/HoldToTalk_HoldToTalk.bundle" ]; then \
		cp -R ".build/arm64-apple-macosx/release/HoldToTalk_HoldToTalk.bundle" "$(APP_BUNDLE)/Contents/Resources/"; \
	fi
	@if [ "$(APP_STORE)" = "1" ]; then \
		plutil -remove SUFeedURL "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true; \
		plutil -remove SUPublicEDKey "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true; \
	else \
			rsync -a --delete "$(SPARKLE_FRAMEWORK)" "$(APP_BUNDLE)/Contents/Frameworks/"; \
			install_name_tool -add_rpath @executable_path/../Frameworks "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true; \
	fi
	@if [ "$(SIGNING_IDENTITY)" = "-" ]; then \
		HTT_STABLE_CODE_IDENTITY=false; \
	else \
		HTT_STABLE_CODE_IDENTITY=true; \
	fi; \
	plutil -remove HTTStableCodeIdentity "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true; \
	plutil -insert HTTStableCodeIdentity -bool $$HTT_STABLE_CODE_IDENTITY "$(APP_BUNDLE)/Contents/Info.plist"
	@if [ "$(SIGNING_IDENTITY)" = "-" ]; then \
		if [ "$(APP_STORE)" != "1" ]; then \
			codesign -f --deep -s - "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
		fi; \
		codesign -f -s - --entitlements "$(APP_ENTITLEMENTS)" "$(APP_BUNDLE)"; \
	else \
		if [ "$(APP_STORE)" != "1" ]; then \
			codesign -f --deep --options runtime --timestamp -s "$(SIGNING_IDENTITY)" "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
		fi; \
		codesign -f --options runtime --timestamp -s "$(SIGNING_IDENTITY)" --entitlements "$(APP_ENTITLEMENTS)" "$(APP_BUNDLE)"; \
	fi
	@echo "Built $(APP_BUNDLE)"

install: build
	@mkdir -p "$(APP_INSTALL_DIR)"
	@rm -rf "$(APP_INSTALL_DIR)/$(APP_DISPLAY_NAME).app"
	@cp -R "$(APP_BUNDLE)" "$(APP_INSTALL_DIR)/"
	@xattr -dr com.apple.quarantine "$(APP_INSTALL_DIR)/$(APP_DISPLAY_NAME).app" 2>/dev/null || true
	@echo "Installed to $(APP_INSTALL_DIR)/$(APP_DISPLAY_NAME).app"

fresh-install:
	@APP_USER="$(APP_USER)" bash scripts/reset-fresh-test.sh --yes
	@$(MAKE) install

verify: build
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	@if [ "$(SIGNING_IDENTITY)" = "-" ]; then \
		echo "Skipping Gatekeeper verification for ad-hoc-signed build."; \
	else \
		spctl -a -t exec -vv "$(APP_BUNDLE)"; \
	fi

package: _check-direct-distribution package-zip package-dmg

package-zip: _check-direct-distribution build
	@mkdir -p "$(DIST_DIR)"
	@ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(ZIP_PATH)"
	@echo "Packaged $(ZIP_PATH)"

package-dmg: _check-direct-distribution build
	@mkdir -p "$(DIST_DIR)"
	@bash scripts/package-dmg.sh \
		--app-bundle "$(APP_BUNDLE)" \
		--volume-name "$(DMG_VOLUME_NAME)" \
		--output "$(DMG_PATH)"
	@if [ "$(SIGNING_IDENTITY)" = "-" ]; then \
		echo "warning: $(DMG_PATH) is ad-hoc signed; Accessibility and Input Monitoring tests across rebuilds may require removing and re-adding Hold To Talk in System Settings."; \
	fi

package-permission-test-dmg: _check-direct-distribution _check-signing package-dmg
	@echo "Packaged stable-signed DMG for macOS permission testing: $(DMG_PATH)"

notarize: notarize-app

notarize-app: _check-direct-distribution build _check-signing _check-notary
	@ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(NOTARY_TMP_ZIP)"
	@xcrun notarytool submit "$(NOTARY_TMP_ZIP)" \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(APPLE_TEAM_ID)" \
		--password "$(APPLE_APP_PASSWORD)" \
		--wait
	@xcrun stapler staple "$(APP_BUNDLE)"
	@rm -f "$(NOTARY_TMP_ZIP)"
	@echo "Notarized and stapled $(APP_BUNDLE)"

notarize-dmg: _check-direct-distribution package-dmg _check-signing _check-notary
	@xcrun notarytool submit "$(DMG_PATH)" \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(APPLE_TEAM_ID)" \
		--password "$(APPLE_APP_PASSWORD)" \
		--wait
	@xcrun stapler staple "$(DMG_PATH)"
	@echo "Notarized and stapled $(DMG_PATH)"

release: _check-direct-distribution notarize-app package-zip package-dmg notarize-dmg
	@echo "Release artifacts:"
	@echo "  - $(ZIP_PATH)"
	@echo "  - $(DMG_PATH)"

permissions-reset:
	@APP_USER="$(APP_USER)" bash scripts/reset-fresh-test.sh --yes --permissions-only

reset-fresh-test:
	@APP_USER="$(APP_USER)" bash scripts/reset-fresh-test.sh $(ARGS)

test-reset:
	@APP_USER="$(APP_USER)" bash scripts/reset-fresh-test.sh --yes

uninstall:
	@APP_USER="$(APP_USER)" bash scripts/reset-fresh-test.sh --yes

run: setup
	swift build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	@cp ".build/debug/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/"
	@cp Resources/HoldToTalk.icns "$(APP_BUNDLE)/Contents/Resources/"
	@cp Resources/PrivacyInfo.xcprivacy "$(APP_BUNDLE)/Contents/Resources/"
	@cp -R Resources/en.lproj "$(APP_BUNDLE)/Contents/Resources/"
	@if [ -d ".build/debug/HoldToTalk_HoldToTalk.bundle" ]; then \
		cp -R ".build/debug/HoldToTalk_HoldToTalk.bundle" "$(APP_BUNDLE)/Contents/Resources/"; \
	elif [ -d ".build/arm64-apple-macosx/debug/HoldToTalk_HoldToTalk.bundle" ]; then \
		cp -R ".build/arm64-apple-macosx/debug/HoldToTalk_HoldToTalk.bundle" "$(APP_BUNDLE)/Contents/Resources/"; \
	fi
	@SPARKLE_FW="$$(swift build --show-bin-path)/Sparkle.framework"; \
	if [ -d "$$SPARKLE_FW" ]; then \
		rsync -a --delete "$$SPARKLE_FW" "$(APP_BUNDLE)/Contents/Frameworks/"; \
		install_name_tool -add_rpath @executable_path/../Frameworks "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true; \
		codesign -f --deep -s - "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
	fi
	@plutil -remove HTTStableCodeIdentity "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@plutil -insert HTTStableCodeIdentity -bool false "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign -f -s - --entitlements Resources/HoldToTalk.dev.entitlements "$(APP_BUNDLE)"
	@echo "Built debug $(APP_BUNDLE)"
	open "$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)" "$(DIST_DIR)" "$(DMG_STAGING)" "$(NOTARY_TMP_ZIP)"

_check-signing:
	@test "$(SIGNING_IDENTITY)" != "-" || (echo "Error: set SIGNING_IDENTITY to your Developer ID Application certificate" && exit 1)

_check-notary:
	@test -n "$(APPLE_ID)" || (echo "Error: set APPLE_ID to your Apple ID email" && exit 1)
	@test -n "$(APPLE_TEAM_ID)" || (echo "Error: set APPLE_TEAM_ID to your Apple Developer Team ID" && exit 1)
	@test -n "$(APPLE_APP_PASSWORD)" || (echo "Error: set APPLE_APP_PASSWORD to your app-specific password" && exit 1)

_check-direct-distribution:
	@test "$(APP_STORE)" != "1" || (echo "Error: packaging and notarization targets are for direct distribution only. Use the App Store workflow for APP_STORE=1 builds." && exit 1)
