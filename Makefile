# Burnbar developer tasks.
#
# Lint/format are the reliable, install-light path — they need only
# `brew install swiftlint swiftformat`. The Lefthook pre-commit hook (optional)
# just calls `make lint`; if Lefthook is not installed, run `make lint`
# manually before committing (see CLAUDE.md "Workflow expectations").

.DEFAULT_GOAL := help
.PHONY: help lint format scan-secrets

## help: List available targets.
help:
	@echo "Burnbar make targets:"
	@echo "  make lint           Check formatting + lint (non-zero exit on any violation)."
	@echo "  make format         Auto-fix formatting + lint-fixable issues, in place."
	@echo "  make scan-secrets   Scan the full git history for secrets (gitleaks)."

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
