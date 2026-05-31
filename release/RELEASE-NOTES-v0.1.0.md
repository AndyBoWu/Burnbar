# Burnbar v0.1.0

First public release. 🔥

Burnbar is a privacy-first macOS menu bar app that tracks how many tokens your
AI coding tools (Claude Code + OpenAI Codex) are burning — and what it costs —
across all your Macs.

## What works in this release

- **Live token-burn meter** in the menu bar, with 5-hour / weekly / monthly
  progress bars.
- **Two providers, read locally only:** Claude Code (`~/.claude`) and OpenAI
  Codex (`~/.codex`). Burnbar **never** reads browser cookies or the system
  Keychain — only local CLI logs.
- **Cost breakdown** per provider/model from a built-in pricing table.
- **Cross-device aggregation** via iCloud Drive — see combined burn across every
  Mac, with a per-machine breakdown and a Devices tab.
- **Global leaderboard (opt-in), built in:** GitHub device-flow sign-in and the
  upload pipeline ship in this build. The public leaderboard is rolling out soon
  at `burnbar.andybowu.xyz` — you can sign in and opt in now, and your opted-in
  totals will appear publicly once it's live. Local tracking and iCloud sync work
  fully today, no account needed.

## Requirements

- macOS 14 (Sonoma) or later

## Install

Download `Burnbar-v0.1.0.zip` below, unzip, and move **Burnbar.app** to
`/Applications`.

> **First launch (one time):** v0.1.0 is ad-hoc signed (no paid Apple Developer
> ID yet), so Gatekeeper quarantines it. **Right-click the app → Open**, then
> confirm — after that it launches normally. Developer ID + notarization (which
> removes this step) is planned post-MVP.

Burnbar runs as a menu-bar agent (no Dock icon) — look for the 🔥 flame icon.

### Launch at login (optional)

To launch Burnbar automatically when you log in, open **Settings → General**
and turn on **"Open at Login"**.

## Privacy

Burnbar reads only local CLI logs under `~/.claude` and `~/.codex` — never
browser data, never third-party Keychain items. The optional leaderboard uploads
only non-identifying daily aggregates (`date, provider, tokens, cost_usd`) —
never prompts, paths, project names, machine ids, or raw model names.

## Known limitations

- Ad-hoc signed → first-open Gatekeeper step (above).
- The public leaderboard is rolling out soon — sign-in and opt-in work now, but
  your totals won't appear publicly until `burnbar.andybowu.xyz` is deployed.
- Codex reports a single token total per thread (a CLI limitation), so the Codex
  tile shows totals only; the Claude tile shows the full input/output/cache
  breakdown.

---

MIT © Andy Wu
