# emux — convenience targets.
#
# `make` with no target prints help. Run `make <target>` for any of the below.
#
# This is a thin wrapper around xcodebuild + helper scripts. The project is an
# Xcode project (emux.xcodeproj), not a Swift Package, so `swift run` won't work.

PROJECT   := emux.xcodeproj
SCHEME    := Ghostty
CONFIG    := Debug
DEST      := platform=macOS
BUNDLE_ID := com.ekinertac.emux.debug

# Locate the most recently built emux.app under DerivedData. Evaluated lazily.
# Explicitly excludes Index.noindex (Xcode's code-completion build artifact,
# which has no executable). Real builds live under Build/Products/<Config>/.
BUILT_APP = $(shell /usr/bin/find $$HOME/Library/Developer/Xcode/DerivedData -name 'emux.app' -type d -not -path '*Index.noindex*' 2>/dev/null | head -1)

# Color escape for the help target.
CYAN  := \033[36m
RESET := \033[0m

.DEFAULT_GOAL := help

.PHONY: help build release run run-attached quit restart open clean libghostty logs status

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(CYAN)%-12s$(RESET) %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build Debug configuration
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DEST)' build 2>&1 | grep -E '^(error|warning:|\*\* BUILD|.*\.swift:[0-9]+:[0-9]+: (error|warning))' || true
	@if [ -d "$$($(MAKE) -s _built-app-path)" ]; then echo "✓ built: $$($(MAKE) -s _built-app-path)"; fi

release: ## Build Release configuration
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DEST)' build 2>&1 | tail -3

run: build ## Build Debug + launch emux.app (detached, no console output)
	@if [ -n "$(BUILT_APP)" ]; then open "$(BUILT_APP)"; echo "→ launched $(BUILT_APP)"; \
	else echo "✗ no emux.app found under DerivedData — build failed?"; exit 1; fi

run-attached: build ## Build + launch with stdout/stderr attached to this terminal (Ctrl-C quits)
	@if [ -n "$(BUILT_APP)" ]; then \
		echo "→ launching $(BUILT_APP)/Contents/MacOS/ghostty (Ctrl-C to quit)"; \
		"$(BUILT_APP)/Contents/MacOS/ghostty"; \
	else echo "✗ no emux.app found under DerivedData — build failed?"; exit 1; fi

logs: ## Stream OSLog output for emux (subsystem com.ekinertac.emux) — keep open in a separate terminal
	@echo "→ streaming emux logs (Ctrl-C to stop). Open emux in another window."
	@log stream --predicate 'subsystem CONTAINS "com.ekinertac"' --level=debug --style compact

quit: ## Quit running emux gracefully
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null || true
	@sleep 1
	@if pgrep -f 'emux.app/Contents/MacOS/ghostty' >/dev/null; then echo "✗ still running — try killing manually"; else echo "✓ quit"; fi

restart: quit run ## Quit + relaunch

open: ## Open emux.xcodeproj in Xcode
	@open $(PROJECT)

clean: ## Remove the build directory from DerivedData
	@DD=$$HOME/Library/Developer/Xcode/DerivedData/$$(ls -1t $$HOME/Library/Developer/Xcode/DerivedData 2>/dev/null | grep '^emux-' | head -1); \
	if [ -d "$$DD" ]; then rm -rf "$$DD"; echo "✓ removed $$DD"; else echo "(no emux DerivedData to clean)"; fi

libghostty: ## Rebuild the vendored GhosttyKit.xcframework from pinned Ghostty tag
	@scripts/build-libghostty.sh

status: ## Show git status + last 5 commits
	@git status --short
	@echo
	@git log --oneline -5

# Internal helper, not in help.
_built-app-path:
	@echo "$(BUILT_APP)"
