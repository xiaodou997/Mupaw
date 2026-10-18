SHELL := /bin/bash
PROJECT := Mupaw.xcodeproj
SCHEME := Mupaw
CONFIGURATION ?= Debug
DERIVED_DATA ?= .build/DerivedData
APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Mupaw.app
MCP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/mupaw-mcp

.PHONY: generate format lint build test run mcp-smoke mcp-smoke-running clean open

generate:
	xcodegen generate

format:
	xcrun swift-format format --configuration .swift-format --in-place --recursive Sources Tests

lint:
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

run: build
	@osascript -e 'tell application id "com.xiaodou.mupaw" to quit' >/dev/null 2>&1 || true
	@sleep 1
	@pkill -x Mupaw >/dev/null 2>&1 || true
	open "$(APP_PATH)"

mcp-smoke: build
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)"

mcp-smoke-running: build
	python3 scripts/mcp_smoke.py --executable "$(MCP_PATH)" --require-running

open: generate
	open $(PROJECT)

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT)
	rm -f Config/Mupaw-Info.plist
