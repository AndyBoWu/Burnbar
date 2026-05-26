# Burnbar Roadmap

Four milestones. Each ships independently. See [docs/PLAN.md](docs/PLAN.md) for full epic + sub-ticket detail.

## Phase 1 — Local Swift app (1–2 weeks)

**Goal**: Native macOS menu bar app reading Claude Code + Codex CLI logs locally.

- [ ] SwiftUI menu bar app skeleton (Swift 6.3, macOS 14+, `LSUIElement = YES`)
- [ ] Claude Code parser (`~/.claude/stats-cache.json` + today's JSONL delta)
- [ ] Codex parser (`~/.codex/state_5.sqlite` `threads` table)
- [ ] Token cost table — Sonnet / Opus / Haiku / GPT-5 input/output/cache prices
- [ ] String Catalog (`.xcstrings`) with `en` + `zh-Hans`
- [ ] Menu bar popover UI + minimal Settings window
- [ ] LaunchAgent template for auto-start at login
- [ ] DMG release build

**Non-goals for P1**: no sync, no leaderboard, no Ollama (deferred to P1.5).

## Phase 1.5 — Ollama support (~1 week, after P1 ships)

**Goal**: Add Ollama as the open-source local-LLM provider, completing the 3-provider story.

**Why split from P1**: Ollama does **not** persist token counts to disk (verified on a real machine — neither `~/.ollama/logs/`, `~/.ollama/history`, nor the Desktop app's `db.sqlite` has them). Implementation differs significantly from Claude/Codex: needs live log tailing, Burnbar's own SQLite for persistence, and a different UI mode (no `$`, no limit bars). Splitting it out keeps P1 fast and clean.

- [ ] Investigate `OLLAMA_DEBUG=DEBUG` log format for token counts
- [ ] Live tailer for `~/.ollama/logs/server-*.log`
- [ ] Burnbar local SQLite at `~/Library/Application Support/Burnbar/usage.sqlite`
- [ ] Ollama-specific UI mode (calls / tokens / models — no `$`, no limit bars)

## Phase 2 — Cross-device aggregation (1 week)

**Goal**: See combined burn across all your Macs.

- [ ] Each Mac writes `~/Library/Mobile Documents/com~apple~CloudDocs/Burnbar/{machine-id}.jsonl`
- [ ] Reconciler merges all machines on read (conflict-free: each machine owns its file)
- [ ] "Combined view" toggle in popover with per-machine breakdown
- [ ] Detect iCloud Drive disabled and degrade gracefully

## Phase 3 — Global leaderboard (2–3 weeks)

**Goal**: Opt-in social layer for the vibe coding community. Lives at `burnbar.andybowu.xyz`.

- [ ] GitHub OAuth Device Flow (no callback URL needed — perfect for menu bar app)
- [ ] Cloudflare Workers + D1 backend
- [ ] Upload schema: `{github_id, date, claude_tokens, codex_tokens, ollama_tokens, machine_count}` — **never** any prompt/response content
- [ ] Web dashboard at `burnbar.andybowu.xyz`
- [ ] Daily / weekly / monthly leaderboards
- [ ] Personal profile page with history
- [ ] Settings: opt-in toggle, hide from leaderboard, delete all data

## Out of scope (will not be added)

These conflict with the privacy thesis or are pass-through wrappers around providers we already cover:

- **Gemini / Grok / xAI** — closed cloud, requires OAuth + browser flows
- **Cursor / Copilot** — requires browser session cookies
- **Aider / Cline / Continue / OpenCode** — pass-through wrappers; tokens are already counted at the underlying provider (Claude / OpenAI)

## Future ideas (post-Phase 3)

- LM Studio support (alternative local-LLM serving — only if there's clear user demand)
- Project-level burn breakdown
- Burn-rate alerts (push notification at 80% of weekly limit)
- Team / private leaderboards
- Public read API for third-party dashboards / widgets

## Design principles

1. **Privacy is the product.** Browser secrets and Keychain are off-limits, forever.
2. **One feature, done well.** Resist becoming CodexBar's 40-provider sprawl. **Three providers, no more.**
3. **Bilingual from day one.** Never ship an English-only string.
4. **Native feel.** SwiftUI / AppKit, no Electron, no web view wrappers.
