# Burnbar developer tasks.
#
# Lint/format are the reliable, install-light path — they need only
# `brew install swiftlint swiftformat`. `make setup` wires the pre-commit hook
# (lint + gitleaks secret scan); if it isn't installed, run `make lint` (and
# `make scan-secrets`) manually before committing (see CLAUDE.md).

.DEFAULT_GOAL := help
.PHONY: help setup hooks lint format scan-secrets

## help: List available targets.
help:
	@echo "Burnbar make targets:"
	@echo "  make setup          Install the pre-commit hook (run once per clone)."
	@echo "  make lint           Check formatting + lint (non-zero exit on any violation)."
	@echo "  make format         Auto-fix formatting + lint-fixable issues, in place."
	@echo "  make scan-secrets   Scan the full git history for secrets (gitleaks)."

## setup: Install the git pre-commit hook (lint + secret scan). Run once per clone.
setup: hooks
hooks:
	@command -v lefthook >/dev/null 2>&1 || { echo "error: lefthook not found — run 'brew install lefthook'"; exit 1; }
	@command -v gitleaks >/dev/null 2>&1 || echo "warning: gitleaks not found — the secret-scan step is skipped until you 'brew install gitleaks'"
	@# A global core.hooksPath (e.g. ~/.git-hooks) makes git ignore .git/hooks and
	@# makes lefthook refuse to install. Pin this repo to .git/hooks locally, then
	@# force lefthook to install there.
	@git config --local core.hooksPath .git/hooks
	lefthook install --force
	@echo "Pre-commit hook installed. Verify with: cat .git/hooks/pre-commit"

## lint: Verify style without modifying files. Fails on any violation.
lint:
	@command -v swiftformat >/dev/null 2>&1 || { echo "error: swiftformat not found — run 'brew install swiftformat'"; exit 1; }
	@command -v swiftlint   >/dev/null 2>&1 || { echo "error: swiftlint not found — run 'brew install swiftlint'"; exit 1; }
	swiftformat --lint .
	swiftlint --strict

## format: Apply formatting and auto-fixable lint corrections in place.
format:
	@command -v swiftformat >/dev/null 2>&1 || { echo "error: swiftformat not found — run 'brew install swiftformat'"; exit 1; }
	@command -v swiftlint   >/dev/null 2>&1 || { echo "error: swiftlint not found — run 'brew install swiftlint'"; exit 1; }
	swiftformat .
	swiftlint --fix

## scan-secrets: Scan the full git history for committed secrets (gitleaks).
scan-secrets:
	@command -v gitleaks >/dev/null 2>&1 || { echo "error: gitleaks not found — run 'brew install gitleaks'"; exit 1; }
	gitleaks git --redact --verbose
