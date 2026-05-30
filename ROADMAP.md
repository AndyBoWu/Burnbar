# Burnbar Roadmap

Three milestones. Each ships independently. See [docs/PLAN.md](docs/PLAN.md) for full epic + sub-ticket detail.

## Phase 1 — Local Swift app (1–2 weeks)

**Goal**: Native macOS menu bar app reading Claude Code + Codex CLI logs locally.

- [ ] SwiftUI menu bar app skeleton (Swift 6.3, macOS 14+, `LSUIElement = YES`)
- [ ] Claude Code parser (`~/.claude/stats-cache.json` + today's JSONL delta)
- [ ] Codex parser (`~/.codex/state_5.sqlite` `threads` table)
- [ ] Token cost table — Sonnet / Opus / Haiku / GPT-5 input/output/cache prices
- [ ] Menu bar popover UI + minimal Settings window
- [ ] LaunchAgent template for auto-start at login
- [ ] DMG release build
- [ ] Homebrew tap — one-line install: `brew install --cask andybowu/tap/burnbar`

**Non-goals for P1**: no sync, no leaderboard, no official homebrew-cask (needs Developer ID + notarization — deferred post-MVP).

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
- [ ] Upload schema: `{github_id, date, claude_tokens, codex_tokens, machine_count}` — **never** any prompt/response content
- [ ] Web dashboard at `burnbar.andybowu.xyz`
- [ ] Daily / weekly / monthly leaderboards
- [ ] Personal profile page with history
- [ ] Settings: opt-in toggle, hide from leaderboard, delete all data

## Out of scope (will not be added)

These conflict with the privacy thesis, are pass-through wrappers, or don't persist token counts:

- **Gemini / Grok / xAI** — closed cloud, requires OAuth + browser flows
- **Cursor / Copilot** — requires browser session cookies
- **Aider / Cline / Continue / OpenCode** — pass-through wrappers; tokens are already counted at the underlying provider (Claude / OpenAI)
- **Ollama / LM Studio** — local LLMs that don't persist token counts to disk; would require live log tailing and a different UI mode (no cost, no limits)

## Future ideas (post-Phase 3)

- Project-level burn breakdown
- Burn-rate alerts (push notification at 80% of weekly limit)
- Team / private leaderboards
- Public read API for third-party dashboards / widgets

## Design principles

1. **Privacy is the product.** Browser secrets and Keychain are off-limits, forever.
2. **One feature, done well.** Resist becoming CodexBar's 40-provider sprawl. **Two providers, no more.**
3. **Native feel.** SwiftUI / AppKit, no Electron, no web view wrappers.
