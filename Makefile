# Pensieve — native macOS markdown editor
# Thin Makefile facade. Delegates to scripts/ for non-trivial pipelines.
#
# Quick start:
#   make            # = make help
#   make run        # build + launch app
#   make test       # unit + integration tests
#   make release    # full signed + notarized .app + .dmg
#
# Conventions:
#   `info-*` targets are inspection (read-only, no side effects)
#   `release-*` targets produce signed artifacts in dist/

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ─── Paths ────────────────────────────────────────────────────────────────
REPO_ROOT  := $(shell pwd)
PKG_DIR    := $(REPO_ROOT)/Pensieve
SCRIPTS    := $(REPO_ROOT)/scripts
DIST       := $(REPO_ROOT)/dist
BUILD_DIR  := $(PKG_DIR)/.build
APP_BUNDLE := $(DIST)/Pensieve.app
DMG_PATH   := $(DIST)/Pensieve.dmg

# ─── Colors ───────────────────────────────────────────────────────────────
C_CYAN   := \033[36m
C_GREEN  := \033[32m
C_YELLOW := \033[33m
C_RESET  := \033[0m

# =========================================================================
# DEVELOPMENT (daily driver)
# =========================================================================

.PHONY: build
build:  ## Debug build (SwiftPM)
	@cd $(PKG_DIR) && swift build

.PHONY: build-release
build-release:  ## Release build (unsigned, fast smoke)
	@cd $(PKG_DIR) && swift build -c release --arch arm64

.PHONY: run
run: build  ## Build + launch app (debug, no .app bundle)
	@cd $(PKG_DIR) && swift run Pensieve

.PHONY: run-release
run-release: release-local  ## Build + launch signed .app (no notarize)
	@open "$(APP_BUNDLE)"

.PHONY: clean
clean:  ## Remove .build/ + dist/
	@printf "$(C_CYAN)[clean]$(C_RESET) removing .build + dist\n"
	@rm -rf $(BUILD_DIR) $(DIST)
	@printf "$(C_GREEN)[ ok ]$(C_RESET) cleaned\n"

.PHONY: clean-deep
clean-deep: clean  ## Clean + nuke SwiftPM resolved deps cache
	@rm -rf $(PKG_DIR)/.swiftpm $(PKG_DIR)/Package.resolved

# =========================================================================
# QUALITY GATES
# =========================================================================

.PHONY: test
test:  ## Run unit + integration tests
	@cd $(PKG_DIR) && swift test 2>&1 | tail -25

.PHONY: ui-smoke
ui-smoke:  ## Accessibility-driven smoke against dist/Pensieve.app
	@$(SCRIPTS)/ui-smoke.sh "$(APP_BUNDLE)"

.PHONY: test-ui
test-ui: ui-smoke  ## Alias for the accessibility UI smoke harness

.PHONY: lint
lint:  ## Required format check; fails if swift-format is missing
	@if ! command -v swift-format >/dev/null 2>&1; then \
		printf "$(C_YELLOW)[missing]$(C_RESET) swift-format is required for lint/release gates (brew install swift-format)\n"; \
		exit 1; \
	fi
	@cd $(PKG_DIR) && swift-format lint --recursive Sources/ Tests/

.PHONY: format
format:  ## Apply swift-format in-place when installed (best-effort helper)
	@command -v swift-format >/dev/null 2>&1 \
		&& cd $(PKG_DIR) && swift-format format --in-place --recursive Sources/ Tests/ \
		|| printf "$(C_YELLOW)[skip]$(C_RESET) swift-format not installed (brew install swift-format)\n"

.PHONY: gates
gates: test lint  ## Run all quality gates (test + lint)
	@printf "$(C_GREEN)[ ok ]$(C_RESET) all gates passed\n"

# =========================================================================
# RELEASE PIPELINE
# =========================================================================

.PHONY: release
release: gates  ## Full signed + notarized .app + .dmg (gated by test+lint)
	@$(SCRIPTS)/build-release.sh

.PHONY: release-local
release-local: gates  ## Signed .app + .dmg, skip notarization (gated, local-only)
	@$(SCRIPTS)/build-release.sh --no-notarize

.PHONY: release-clean
release-clean: clean gates  ## Clean + full release (gated, most reproducible)
	@$(SCRIPTS)/build-release.sh --clean

# =========================================================================
# INSPECTION
# =========================================================================

.PHONY: loc
loc:  ## Codebase overview via loctree (`loct --for-ai`)
	@command -v loct >/dev/null 2>&1 && loct --for-ai 2>/dev/null | head -40 \
		|| printf "$(C_YELLOW)[skip]$(C_RESET) loctree CLI not on PATH\n"

.PHONY: tree
tree:  ## Source tree (Pensieve/Sources only)
	@find Pensieve/Sources -name '*.swift' -not -path '*/.build/*' | sort

.PHONY: log
log:  ## Recent commit log
	@git log --oneline --decorate -10

.PHONY: info-status
info-status:  ## Git status + branch (read-only)
	@git status -sb

.PHONY: info-artifacts
info-artifacts:  ## Inspect dist/ artifacts (sizes + sigs)
	@if [[ -d "$(DIST)" ]]; then \
		ls -lh $(DIST)/ 2>/dev/null | grep -v "^total\|\.log$$\|\.zip$$"; \
		printf "\n$(C_CYAN)[stapler]$(C_RESET)\n"; \
		[[ -d "$(APP_BUNDLE)" ]] && xcrun stapler validate "$(APP_BUNDLE)" 2>&1 | tail -2; \
		[[ -f "$(DMG_PATH)" ]] && xcrun stapler validate "$(DMG_PATH)" 2>&1 | tail -2; \
	else \
		printf "$(C_YELLOW)[empty]$(C_RESET) dist/ does not exist — run \`make release\` first\n"; \
	fi

.PHONY: info-certs
info-certs:  ## Show signing identities in keychain
	@security find-identity -v -p codesigning | grep -E "Developer ID|Apple Development" || true

# =========================================================================
# CI
# =========================================================================

.PHONY: ci
ci: clean gates build-release  ## CI suite: clean + test + lint + release build
	@printf "$(C_GREEN)[ ok ]$(C_RESET) CI complete\n"

# =========================================================================
# HELP (default target)
# =========================================================================

.PHONY: help
help:  ## Show this help
	@printf "\n$(C_CYAN)Pensieve$(C_RESET) — native macOS markdown editor\n"
	@printf "$(C_CYAN)$$(printf '%.s─' {1..72})$(C_RESET)\n\n"
	@awk 'BEGIN {FS = ":.*?## "} \
		/^# =+$$/ { in_section=1; next } \
		in_section && /^# / { sub(/^# /, ""); printf "\n  $(C_YELLOW)%s$(C_RESET)\n", $$0; in_section=0; next } \
		/^[a-zA-Z][a-zA-Z0-9_?\\-]*:.*?##/ { \
			target=$$1; gsub(/\\\?/, "?", target); \
			printf "    $(C_GREEN)%-18s$(C_RESET) %s\n", target, $$2 \
		}' $(MAKEFILE_LIST)
	@printf "\n  $(C_CYAN)Quick start:$(C_RESET)\n"
	@printf "    make run             # build + launch (debug)\n"
	@printf "    make test            # unit + integration tests\n"
	@printf "    make ui-smoke        # launch .app + verify native UI surface\n"
	@printf "    make release         # signed + notarized .app + .dmg\n"
	@printf "    make info-artifacts  # inspect dist/ contents\n\n"
