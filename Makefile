SHELL := /bin/bash
PROJECT := Mupaw.xcodeproj
SCHEME := Mupaw
CONFIGURATION ?= Debug
DERIVED_DATA ?= .build/DerivedData
APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Mupaw.app
MCP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/mupaw-mcp
DEV_APP_PATH ?= $(HOME)/Applications/Mupaw.app
DEV_CODE_SIGN_IDENTITY ?= -

-include .mupaw.local.mk

.PHONY: generate format localization-check lint build test install-dev uninstall-dev run open-screen-recording-settings mcp-smoke mcp-smoke-running mcp-smoke-capture mcp-smoke-full-screen mcp-negative-smoke mcp-capture-conflict-smoke rpc-negative-smoke m0-acceptance m1a-acceptance clean open

generate:
	xcodegen generate

format:
	xcrun swift-format format --configuration .swift-format --in-place --recursive Sources Tests

localization-check:
	python3 scripts/validate_localizations.py

lint: localization-check
	xcrun swift-format lint --configuration .swift-format --recursive Sources Tests

build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		build

test: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		test

install-dev: build
	@osascript -e 'tell application id "com.xiaodou.mupaw" to quit' >/dev/null 2>&1 || true
	@sleep 1
	@pkill -x Mupaw >/dev/null 2>&1 || true
	@mkdir -p "$(dir $(DEV_APP_PATH))"
	@rm -rf "$(DEV_APP_PATH)"
	@ditto --rsrc --extattr --acl "$(APP_PATH)" "$(DEV_APP_PATH)"
	@if [[ "$(DEV_CODE_SIGN_IDENTITY)" != "-" ]]; then \
		codesign --force --deep --sign "$(DEV_CODE_SIGN_IDENTITY)" --timestamp=none "$(DEV_APP_PATH)"; \
	fi
	@codesign --verify --deep --strict "$(DEV_APP_PATH)"
	@printf 'Installed development app: %s\n' "$(DEV_APP_PATH)"
	@printf 'Development signing identity: %s\n' "$(DEV_CODE_SIGN_IDENTITY)"

uninstall-dev:
	@osascript -e 'tell application id "com.xiaodou.mupaw" to quit' >/dev/null 2>&1 || true
	@pkill -x Mupaw >/dev/null 2>&1 || true
	@rm -rf "$(DEV_APP_PATH)"

run: install-dev
	open "$(DEV_APP_PATH)"

open-screen-recording-settings:
	open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

mcp-smoke: build
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)"

mcp-smoke-running: build
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)" --require-running

mcp-smoke-capture: build
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)" --require-running --capture-one

mcp-smoke-full-screen: build
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)" --require-running --capture-full-screen

mcp-negative-smoke: build
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)" --require-running --negative

mcp-capture-conflict-smoke: build
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)" --require-running --expect-capture-in-progress

rpc-negative-smoke:
	python3 scripts/rpc_negative_smoke.py

m0-acceptance:
	@$(MAKE) lint
	@$(MAKE) test
	@$(MAKE) run
	python3 scripts/rpc_negative_smoke.py --wait-seconds 15
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)" --require-running --negative --capture-one

m1a-acceptance:
	@$(MAKE) lint
	@$(MAKE) test
	@$(MAKE) run
	python3 scripts/rpc_negative_smoke.py --wait-seconds 15
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)" --require-running --negative --capture-one

open: generate
	open $(PROJECT)

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT)
	rm -f Config/Mupaw-Info.plist
