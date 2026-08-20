# TypeFlow — Makefile
# Run `make help` for available commands.
#
# APP_NAME / DISPLAY_NAME / APP_DIR come from scripts/app-name.sh, the single
# definition shared with build.sh / dist.sh / install.sh / uninstall.sh.
# APP_NAME is the executable (pgrep/killall target); DISPLAY_NAME is the
# user-visible product name and APP_DIR the .app bundle folder.

.PHONY: build install install-cli dmg release test clean reset run help

APP_NAME     := $(shell . scripts/app-name.sh && printf '%s' "$$APP_NAME")
DISPLAY_NAME := $(shell . scripts/app-name.sh && printf '%s' "$$DISPLAY_NAME")
APP_DIR      := $(shell . scripts/app-name.sh && printf '%s' "$$APP_DIR")

.DEFAULT_GOAL := help

## Build .app bundle in repo root (fast, for development)
build:
	@./scripts/build.sh

## Build and install to /Applications (recommended for first-time setup)
install:
	@./scripts/install.sh

## Install CLI commands (vocamac, vocamac-build) to ~/.local/bin
install-cli:
	@./scripts/install.sh --cli

## Build DMG for distribution
dmg:
	@./scripts/dist.sh

## Release — tag and push to trigger GitHub Actions release workflow (usage: make release VERSION=0.4.0)
release:
	@./scripts/release.sh $(VERSION)

## Run tests
test:
	@swift test

## Remove build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	@swift package clean 2>/dev/null || true
	@rm -rf "$(APP_DIR)"
	@rm -rf VocaMac.app        # pre-rename bundle, if still lying around
	@rm -rf .build
	@rm -rf .xcode-build
	@rm -rf dist
	@echo "✅ Clean complete"

## Reset all local app data (models, cache, preferences) — app must not be running
reset:
	@if pgrep -x $(APP_NAME) > /dev/null 2>&1; then echo "❌ $(DISPLAY_NAME) is running. Quit it first." && exit 1; fi
	@echo "⚠️  This will permanently delete all $(DISPLAY_NAME) local data:"
	@echo ""
	@echo "   • Downloaded whisper models (~76MB each)"
	@echo "   • Debug logs"
	@echo "   • Cached data"
	@echo "   • All preferences (selected model, language, onboarding state, etc.)"
	@echo ""
	@echo "Next launch will start as if freshly installed (onboarding + bundled tiny model)."
	@echo ""
	@bash -c 'read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || (echo "Aborted." && exit 1)'
	@rm -rf ~/Library/Application\ Support/VocaMac
	@rm -rf ~/Library/Caches/com.vocamac.app
	@defaults delete com.vocamac.app 2>/dev/null || true
	@echo "✅ Reset complete — next launch will start fresh"

## Launch the locally built .app (build first with `make build`)
run:
	@open "$(APP_DIR)" 2>/dev/null || (echo "❌ $(APP_DIR) not found. Run 'make build' first." && exit 1)

## Show this help
help:
	@echo "$(DISPLAY_NAME) — Available Commands"
	@echo ""
	@echo "  make build        Build .app bundle (fast, for development)"
	@echo "  make install      Build + install to /Applications (recommended)"
	@echo "  make install-cli  Install CLI commands to ~/.local/bin"
	@echo "  make dmg          Build DMG for distribution (output in dist/)"
	@echo "  make release VERSION=X.Y.Z  Tag and release (triggers CI signing + notarization)"
	@echo "  make test         Run tests"
	@echo "  make run          Launch the locally built .app"
	@echo "  make clean        Remove build artifacts"
	@echo "  make reset        Delete all local app data (models, cache, prefs)"
	@echo "  make help         Show this help"
	@echo ""
	@echo "Quick start:  make install"
