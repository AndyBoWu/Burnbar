# Burnbar 🔥

> Track token burn across AI coding tools — in your macOS menu bar.

**Burnbar** is a privacy-first menu bar app that shows how many tokens your AI coding tools are burning, across all your devices, with an optional global leaderboard.

## Why Burnbar

Vibe coding with Claude Code or Codex? You're burning tokens — but you can't see where, how much, or what it costs across multiple Macs.

[CodexBar](https://github.com/steipete/CodexBar) solves the per-machine usage problem, but reads browser cookies and Keychain to get there. **Burnbar takes a different bet:**

- 🛡️ **Never reads browser data. Never touches Keychain.** Only local CLI logs (`~/.claude`, `~/.codex`).
- 🖥️ **Cross-device aggregation.** Sync via iCloud Drive — see total burn across all your Macs.
- 🌐 **Global leaderboard.** Opt-in. Sign in with GitHub. Compare daily burn with the community.

## Features

- 🔥 Real-time token burn meter in the menu bar
- 📊 Progress bars for 5-hour / weekly / monthly limits
- 🖥️ Multi-device aggregation via iCloud Drive
- 🌐 Optional GitHub-authenticated global leaderboard
- 🛡️ Privacy-first: never touches browser secrets or Keychain

## Supported Tools

| Tool | Status | Data source |
|---|---|---|
| Claude Code | ✅ Phase 1 | `~/.claude/stats-cache.json` + `~/.claude/projects/` |
| OpenAI Codex | ✅ Phase 1 | `~/.codex/state_5.sqlite` (`threads` table) |

> By design, Burnbar sticks to **two providers**: Claude Code and OpenAI Codex. We will not expand to 40+ providers — that's CodexBar's path; ours is depth + cross-device + leaderboard.

## Status

🚧 **Early development.** Phase 1 (local Swift app) in progress. See [ROADMAP.md](ROADMAP.md).

## Requirements

- macOS 14+ (Sonoma)
- Xcode 15+ (for development)

## Build from source

Prerequisites: **macOS 14+**, **Xcode 15+**, and [XcodeGen](https://github.com/yonsm/XcodeGen) (`brew install xcodegen`) — the `.xcodeproj` is generated from `project.yml`, not committed.

```bash
git clone https://github.com/AndyBoWu/Burnbar.git
cd Burnbar
./Scripts/compile_and_run.sh   # generates the project, builds Debug, launches the menu-bar app
```

Look for the 🔥 flame icon in your menu bar (Burnbar runs as an `LSUIElement` agent — no Dock icon).

To run the tests:

```bash
xcodegen generate
xcodebuild -project Burnbar.xcodeproj -scheme Burnbar -destination 'platform=macOS' test
```

## License

MIT © Andy Wu
