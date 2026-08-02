# Pensieve — native macOS markdown editor
# Thin Makefile facade. Delegates to scripts/ for non-trivial pipelines.
#
# Quick start:
#   make            # = make help
#   make run        # build + launch app
#   make test       # unit + integration tests
#   make install-app # local app install + repo git hooks
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
C_RED    := \033[31m
C_RESET  := \033[0m

# =========================================================================
# DEVELOPMENT (daily driver)
# =========================================================================

.PHONY: build
build:  ## Debug build (SwiftPM)
build: ffi-check
	@cd $(PKG_DIR) && swift build

.PHONY: build-release
build-release:  ## Release build (unsigned, fast smoke)
build-release: ffi-check
	@cd $(PKG_DIR) && swift build -c release --arch arm64

.PHONY: run
run: build  ## Build + launch app (debug, no .app bundle)
	@cd $(PKG_DIR) && swift run Pensieve

.PHONY: run-release
run-release: release-local  ## Build + launch signed .app (no notarize)
	@open "$(APP_BUNDLE)"

.PHONY: install-app
install-app: init-hooks release-local  ## Build signed .app + swap the production bundle in /Applications
	@printf "$(C_CYAN)[install]$(C_RESET) quitting running Pensieve — a live process + bundle swap = SIGKILL (code signature invalid)\n"
	@osascript -e 'tell application id "io.vetcoders.pensieve" to quit' >/dev/null 2>&1 || true
	@pkill -x Pensieve >/dev/null 2>&1 || true
	@sleep 0.6
	@printf "$(C_CYAN)[install]$(C_RESET) swapping /Applications/Pensieve.app\n"
	@rm -rf "/Applications/Pensieve.app"
	@ditto "$(APP_BUNDLE)" "/Applications/Pensieve.app"
	@printf "$(C_CYAN)[install]$(C_RESET) relaunching from /Applications\n"
	@open "/Applications/Pensieve.app"
	@printf "$(C_GREEN)[ ok ]$(C_RESET) installed $(APP_BUNDLE) → /Applications/Pensieve.app\n"

.PHONY: clean
clean:  ## Remove .build/ + dist/
	@printf "$(C_CYAN)[clean]$(C_RESET) removing .build + dist\n"
	@# Rename-aside before delete: a live SourceKit/IDE indexer writing into
	@# .build/index-build races a plain `rm -rf` (it repopulates a dir mid-delete,
	@# so rmdir hits ENOTEMPTY). An atomic rename detaches the tree from the path
	@# the indexer holds, so the delete can't lose that race. Best-effort: never
	@# abort the gated release if a stray file lingers.
	@for d in $(BUILD_DIR) $(DIST); do \
		[ -e "$$d" ] || continue; \
		trash="$$d.trash.$$$$"; \
		mv "$$d" "$$trash" 2>/dev/null || trash="$$d"; \
		rm -rf "$$trash" 2>/dev/null || rm -rf "$$trash" 2>/dev/null || true; \
	done
	@printf "$(C_GREEN)[ ok ]$(C_RESET) cleaned\n"

.PHONY: clean-deep
clean-deep: clean  ## Clean + nuke SwiftPM resolved deps cache
	@rm -rf $(PKG_DIR)/.swiftpm $(PKG_DIR)/Package.resolved

# =========================================================================
# QUALITY GATES
# =========================================================================

.PHONY: test
test:  ## Run unit + integration tests
	@cd $(PKG_DIR) && mkdir -p .build && \
	{ set -o pipefail; swift test 2>&1 | tee .build/test-output.log | tail -25; } || { \
		status=$$?; \
		printf "\n$(C_RED)[fail]$(C_RESET) failing tests (full log: $(PKG_DIR)/.build/test-output.log):\n"; \
		grep -E "Test Case .* failed|error:|✘" .build/test-output.log | head -40 || true; \
		exit $$status; \
	}

.PHONY: test-scripts
test-scripts:  ## Shell-side unit tests (release script guards)
	@$(SCRIPTS)/test-bundle-identity.sh

.PHONY: ui-smoke
ui-smoke:  ## Accessibility-driven smoke against dist/Pensieve.app
	@$(SCRIPTS)/ui-smoke.sh "$(APP_BUNDLE)"

.PHONY: test-ui
test-ui: ui-smoke  ## Alias for the accessibility UI smoke harness

.PHONY: bugmap-smoke
bugmap-smoke:  ## BUGMAP P0 runtime matrix against dist/Pensieve.app (EVIDENCE_DIR=…)
	@$(SCRIPTS)/bugmap-p0-smoke.sh --app "$(APP_BUNDLE)" \
		--evidence "$(or $(EVIDENCE_DIR),dist/bugmap-evidence)"

.PHONY: lint
lint:  ## Required format check; fails if swift-format is missing
	@if ! command -v swift-format >/dev/null 2>&1; then \
		printf "$(C_YELLOW)[missing]$(C_RESET) swift-format is required for lint/release gates (brew install swift-format)\n"; \
		exit 1; \
	fi
	@cd $(PKG_DIR) && swift-format lint $$(find Sources Tests -name '*.swift' ! -path 'Sources/Pensieve/VistaBridge/qube_ffi.swift' -print)

.PHONY: format
format:  ## Apply swift-format in-place when installed (best-effort helper)
	@command -v swift-format >/dev/null 2>&1 \
		&& cd $(PKG_DIR) && swift-format format --in-place $$(find Sources Tests -name '*.swift' ! -path 'Sources/Pensieve/VistaBridge/qube_ffi.swift' -print) \
		|| printf "$(C_YELLOW)[skip]$(C_RESET) swift-format not installed (brew install swift-format)\n"

.PHONY: semgrep
semgrep:  ## Security scan with reviewed, repository-owned finding policy
	@if ! command -v semgrep >/dev/null 2>&1; then \
		printf "$(C_YELLOW)[missing]$(C_RESET) semgrep is required for security/release gates (brew install semgrep)\n"; \
		exit 1; \
	fi
	@if ! command -v jq >/dev/null 2>&1; then \
		printf "$(C_YELLOW)[missing]$(C_RESET) jq is required for the Semgrep policy gate (brew install jq)\n"; \
		exit 1; \
	fi
	@$(SCRIPTS)/semgrep-with-policy.sh

.PHONY: gates
gates: test test-scripts lint semgrep  ## Run all quality gates (test + shell tests + lint + security)
	@printf "$(C_GREEN)[ ok ]$(C_RESET) all gates passed\n"

.PHONY: init-hooks
init-hooks:  ## Install git hooks via lefthook (Vibecrafted standard)
	@if [ "$$CI" = "true" ]; then \
		printf "$(C_YELLOW)[skip]$(C_RESET) CI detected; not installing local git hooks\n"; \
	elif ! command -v lefthook >/dev/null 2>&1; then \
		printf "$(C_YELLOW)[skip]$(C_RESET) lefthook not installed — run 'brew install lefthook' then 'make init-hooks'\n"; \
	elif git rev-parse --git-dir >/dev/null 2>&1; then \
		lefthook install >/dev/null; \
		printf "$(C_GREEN)[ ok ]$(C_RESET) git hooks installed via lefthook (lefthook.yml -> .husky)\n"; \
	else \
		true; \
	fi

.PHONY: ffi
ffi:  ## Rebuild and vendor qube-ffi bridge/dylib (FFI_PROFILE=debug|release)
	@$(PKG_DIR)/scripts/build-ffi.sh

.PHONY: ffi-check
ffi-check:  ## Warn if vendored qube-ffi provenance is stale
	@$(PKG_DIR)/scripts/check-ffi-freshness.sh

# =========================================================================
# RELEASE PIPELINE
# =========================================================================

.PHONY: release
release: gates  ## Full signed + notarized .app + .dmg (gated by test+lint)
release: ffi-check
	@$(SCRIPTS)/build-release.sh

.PHONY: release-local
release-local: gates  ## Signed .app only (no dmg, no notarize) — local install/run
release-local: ffi-check
	@$(SCRIPTS)/build-release.sh --no-notarize --no-dmg

.PHONY: release-clean
release-clean: clean gates  ## Clean + full release (gated, most reproducible)
release-clean: ffi-check
	@$(SCRIPTS)/build-release.sh --clean

.PHONY: notarize
notarize:  ## DMG-only: package + notarize + staple from the existing signed .app (no rebuild, no gates)
	@$(SCRIPTS)/build-release.sh --dmg-only

.PHONY: release-appstore
release-appstore: gates  ## Mac App Store lane: sandbox-signed .app + .pkg in dist/mas (needs PENSIEVE_MAS_APP_IDENTITY)
release-appstore: ffi-check
	@$(SCRIPTS)/build-release.sh --appstore

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

.PHONY: info-appstore
info-appstore:  ## Inspect dist/mas artifacts: entitlements on the .app + pkg signature (read-only)
	@if [[ -d "$(DIST)/mas/Pensieve.app" ]]; then \
		printf "$(C_CYAN)[entitlements]$(C_RESET) dist/mas/Pensieve.app\n"; \
		codesign -d --entitlements - "$(DIST)/mas/Pensieve.app" 2>/dev/null; \
		printf "\n$(C_CYAN)[signature]$(C_RESET)\n"; \
		codesign -dv "$(DIST)/mas/Pensieve.app" 2>&1 | grep -E "Authority|TeamIdentifier|flags" || true; \
	else \
		printf "$(C_YELLOW)[empty]$(C_RESET) dist/mas/Pensieve.app missing — run \`make release-appstore\` first\n"; \
	fi
	@if [[ -f "$(DIST)/mas/Pensieve.pkg" ]]; then \
		printf "\n$(C_CYAN)[pkg]$(C_RESET)\n"; \
		pkgutil --check-signature "$(DIST)/mas/Pensieve.pkg" | head -6 || true; \
	fi
	@printf "\n$(C_CYAN)[mas certs]$(C_RESET)\n"
	@security find-identity -v -p codesigning | grep -E "Apple Distribution|3rd Party Mac Developer" || printf "  (none — see docs/appstore-lane.md)\n"

# =========================================================================
# CI
# =========================================================================

.PHONY: ci
ci: clean gates build-release  ## CI suite: clean + test + lint + release build
ci: ffi-check
	@printf "$(C_GREEN)[ ok ]$(C_RESET) CI complete\n"

# =========================================================================
# SMOKE (operator-side, ad-hoc — not gated by `make ci`)
# =========================================================================

.PHONY: smoke-search-memory
smoke-search-memory:  ## Multi-root reindex memory smoke (B-04, audit F-8-R03)
	@$(SCRIPTS)/smoke_search_memory.sh

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
