# Contributing to Burnbar

Thanks for your interest in Burnbar. This guide covers local setup, the
pre-commit hook, and the conventions we follow.

## Prerequisites

- macOS 14+ (Sonoma)
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
  (the `.xcodeproj` is generated from `project.yml`, not committed)

Install the developer tooling:

```bash
brew install swiftlint swiftformat gitleaks lefthook
```

## First-time setup

```bash
git clone https://github.com/AndyBoWu/Burnbar.git
cd Burnbar
xcodegen generate          # generate Burnbar.xcodeproj from project.yml
make setup                 # install the pre-commit hook
```

## Pre-commit hook

`make setup` wires a pre-commit hook (via [lefthook](https://github.com/evilmartians/lefthook))
that runs on every `git commit`:

1. **Lint** — SwiftFormat + SwiftLint on staged Swift files. `make format`
   auto-fixes most issues.
2. **Secret scan** — gitleaks scans the staged changes and blocks the commit if
   a credential is detected.

`make setup` also pins this repo's `core.hooksPath` to `.git/hooks`, so the hook
still works if you have a custom global hooks path.

Run the checks by hand anytime:

```bash
make lint            # style only (the reliable, install-light path)
make scan-secrets    # gitleaks scan of the full git history
```

> The pre-commit hook is a fast local guardrail, not a hard gate — it can be
> bypassed with `git commit --no-verify` and does not run in environments where
> it isn't installed. The authoritative, un-bypassable control is GitHub
> **Push Protection** (server-side secret scanning), enabled on the public repo.
> Never commit secrets: the GitHub App `client_id` is public by design, but the
> `client_secret` and any other credentials live only in environment config
> (see [SECURITY.md](SECURITY.md)).

## Build & test

```bash
./Scripts/compile_and_run.sh   # generate project, build Debug, launch the app
xcodebuild -project Burnbar.xcodeproj -scheme Burnbar -destination 'platform=macOS' test
```

The web subsystems install per-directory:

```bash
cd web && npm install && npm test            # Cloudflare Worker API
cd web/site && pnpm install && pnpm build      # Next.js site
```

## Conventions

- **One sub-ticket = one PR.** Keep changes focused; if a change would touch
  more than ~3 files or cross epic boundaries, split it.
- **Conventional commits:** `feat:`, `fix:`, `chore:`, `refactor:`, `docs:`.
- **Anonymize fixtures.** Test fixtures under `Tests/Fixtures/` are committed —
  strip any real prompts, project paths, or user identifiers first.
- **Pricing freshness.** When editing `PricingTable.swift`, update the snapshot
  date comment.

## Reporting security issues

See [SECURITY.md](SECURITY.md) — please report vulnerabilities privately, not in
a public issue.
