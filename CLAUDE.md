# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

**Pre-implementation.** The repo contains only planning docs — no Xcode project, no Swift sources, no build/test scripts yet. M1.1.1 ("Init Xcode project") in [docs/PLAN.md](docs/PLAN.md) is the next concrete unit of work.

When sub-tickets ship and tooling lands, update this file's "Commands" section in the same PR.

## Source of truth

Read these before proposing changes — they encode decisions that are not derivable from code:

- [docs/PLAN.md](docs/PLAN.md) — milestones, epics, every sub-ticket with Definition of Done. **Authoritative for scope.**
- [docs/data-sources.md](docs/data-sources.md) — exact file paths, schemas, and SQL queries Burnbar parses. **Authoritative for parser implementation.** Includes the explicit "never read" list (`message.content`, `first_user_message`, `preview`, `cwd`, `git_*`, browser data, Keychain).
- [ROADMAP.md](ROADMAP.md) — public-facing phase summary.

If a code change conflicts with PLAN.md or data-sources.md, the docs win — surface the conflict before deviating.

## Load-bearing constraints

These are product-defining, not stylistic. Violating any of them is a design bug:

1. **Privacy thesis.** Burnbar reads only local CLI logs under `~/.claude` and `~/.codex`. **Never** browser cookies/storage, **never** the system Keychain for third-party items (only our own `xyz.andybowu.Burnbar.*` service ids in M3). This is the differentiator vs. CodexBar — do not erode it.
2. **Two providers, hard cap.** Claude Code and OpenAI Codex. Do not add Gemini, Grok, Cursor, Copilot, Aider, Cline, Continue, OpenCode, Ollama, etc. — they either need browser secrets, are pass-through wrappers, or don't persist token counts. Listed in [ROADMAP.md](ROADMAP.md) "Out of scope".
3. **Never read user content.** Skip every field flagged ⚠ in [docs/data-sources.md](docs/data-sources.md): `message.content`, `first_user_message`, `preview`, `title`, `history.jsonl`. Parse only token counts, models, timestamps.
4. **Never upload identifying paths.** `cwd`, `git_branch`, `git_origin_url`, project dir names may surface in local UI but must not leave the machine via the M3 leaderboard upload. The M3 payload schema (`{date, provider, tokens, cost_usd}`) is validated pre-upload — extend only with non-identifying fields.
5. **English-only UI for MVP.** User-facing strings are plain English literals — no String Catalog, no `String(localized:)`, no locale switching. Keeps M1 focused on getting accurate numbers on screen. Internationalization is not on the roadmap.
6. **Native macOS only.** SwiftUI / AppKit, `LSUIElement = YES` (menu bar agent, no Dock icon). No Electron, no web view wrappers. Target macOS 14+ (Sonoma), Swift 6.3, Xcode 15+.

## Architecture (planned)

The unified data model is `UsageRecord` (Epic 1.2.3): `provider`, `model`, `day`, `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `costUSD`. Every parser emits this; every UI/cost/aggregation component consumes this. Per-provider quirks live behind the boundary:

- **Claude** (`ClaudeUsageProvider`, Epic 1.2): merges `~/.claude/stats-cache.json` (history through yesterday) with today's JSONL delta scanned from `~/.claude/projects/*/`. Full input/output/cache breakdown available.
- **Codex** (`CodexThreadsReader`, Epic 1.3): one read-only SQL query against `~/.codex/state_5.sqlite` `threads` table. Open with `?mode=ro` URI so the WAL lock is never contended while Codex CLI runs. **Caveat:** Codex stores only a single `tokens_used` integer per thread — map to `inputTokens`, leave the rest `nil`. UI must render this asymmetry (Codex tile = total only; Claude tile = stacked breakdown).

Cost is applied post-parse by `CostCalculator` against `PricingTable.swift` (Epic 1.4). Unknown model → warn + treat as $0 + surface "Unknown model" in UI; never silently drop.

Cross-device aggregation (M2) writes per-machine JSONL rollups to iCloud Drive (`{machine_id}.jsonl` — each machine owns one file, so merging is conflict-free). The reconciler reads all files, dedupes by `(date, provider, model, machine_id)`.

Leaderboard upload (M3) aggregates *across* machines first (via the M2 reconciler), then uploads `(date, provider, tokens, cost_usd)` only — never per-machine, never per-project, never raw model names from M3.3.3's validator.

## Workflow expectations

- **One sub-ticket = one PR.** Sub-tickets in PLAN.md are sized to half-day to one-day. If a change would touch >3 files or cross epic boundaries, stop and decompose first.
- **Check open PRs before starting an epic/sub-ticket.** Coverage may already exist on another branch (per the user's global CLAUDE.md rule).
- **Pre-commit hooks aren't guaranteed installed.** If/when a `Makefile` lands with `make pre-commit-run` or equivalent, run it manually before commits and handoffs — don't rely on git hooks being wired up in cloud/agent environments.
- **Pricing freshness.** When editing `PricingTable.swift`, update the snapshot date comment. Epic 1.4.4 adds a test that fails if the table is >90 days stale.
- **Fixtures must be anonymized.** Test fixtures under `Tests/Fixtures/{Claude,Codex}/` are committed — strip any real prompts, project paths, or user identifiers before committing.

## Commands

_To be added when M1.1 (project scaffold) lands. Expected entries per PLAN.md Epic 1.1:_

- `./Scripts/compile_and_run.sh` — build + launch Burnbar.app from clean clone (1.1.4)
- `./Scripts/package_app.sh` — Release build → ad-hoc signed `.zip`/`.dmg` (1.6.1, 1.6.2)
- `make lint` — SwiftLint + SwiftFormat (1.1.2)
- `xcodebuild test` — unit tests (CI runs this per 1.1.3)
- `./Scripts/install_launchagent.sh` — install LaunchAgent for login auto-start (1.6.3)

Update this section in the same PR that introduces each script.
