# Burnbar Roadmap

Three phases. Each ships independently.

## Phase 1 — Local Swift app (1–2 weeks)

**Goal**: Native macOS menu bar app reading Claude Code + Codex CLI logs locally.

- [ ] SwiftUI menu bar app skeleton (Swift 6.3, macOS 14+, `LSUIElement = YES`)
- [ ] Claude Code parser (`~/.claude/projects/**/*.jsonl`)
- [ ] Codex parser (`~/.codex/sessions/**/*.jsonl` — confirm actual path on real machine)
- [ ] Token cost table — port from `claude-usage-tracker` (Sonnet / Opus / GPT-5 input/output/cache prices)
- [ ] String Catalog (`.xcstrings`) with `en` + `zh-Hans`
- [ ] Menu bar popover UI: provider tile + burn bar + reset countdown
- [ ] LaunchAgent template for auto-start at login
- [ ] DMG + PKG release build

**Non-goals for P1**: no sync, no leaderboard, no provider beyond Claude Code + Codex.

## Phase 2 — Cross-device aggregation (1 week)

**Goal**: See combined burn across all your Macs.

- [ ] Each Mac writes `~/Library/Mobile Documents/com~apple~CloudDocs/Burnbar/{machine-id}.jsonl`
- [ ] Port reconciliation logic from `claude-usage-tracker` (Python → Swift)
- [ ] "Combined view" toggle in popover
- [ ] Conflict-free design (each machine owns its file, no shared writes)
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

## Future ideas

- Gemini CLI support
- Grok / xAI support
- Cursor support — only if a non-browser data source exists
- Project-level burn breakdown
- Burn-rate alerts (push notification at 80% of weekly limit)
- Team / private leaderboards
- Public read API for third-party dashboards / widgets

## Design principles

1. **Privacy is the product.** Browser secrets and Keychain are off-limits, forever.
2. **One feature, done well.** Resist becoming CodexBar's 40-provider sprawl.
3. **Bilingual from day one.** Never ship an English-only string.
4. **Native feel.** SwiftUI / AppKit, no Electron, no web view wrappers.
