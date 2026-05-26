# Burnbar 🔥

> Track token burn across AI coding tools — in your macOS menu bar.

**Burnbar** is a privacy-first menu bar app that shows how many tokens your AI coding tools are burning, across all your devices, with an optional global leaderboard.

[English](#english) · [中文](#中文)

---

## English

### Why Burnbar

Vibe coding with Claude Code, Codex, Gemini, or Grok? You're burning tokens — but you can't see where, how much, or what it costs across multiple Macs.

[CodexBar](https://github.com/steipete/CodexBar) solves the per-machine usage problem, but reads browser cookies and Keychain to get there. **Burnbar takes a different bet:**

- 🛡️ **Never reads browser data. Never touches Keychain.** Only local CLI logs (`~/.claude`, `~/.codex`, …).
- 🖥️ **Cross-device aggregation.** Sync via iCloud Drive — see total burn across all your Macs.
- 🌐 **Global leaderboard.** Opt-in. Sign in with GitHub. Compare daily burn with the community.

### Features

- 🔥 Real-time token burn meter in the menu bar
- 📊 Progress bars for 5-hour / weekly / monthly limits
- 🖥️ Multi-device aggregation via iCloud Drive
- 🌐 Optional GitHub-authenticated global leaderboard
- 🛡️ Privacy-first: never touches browser secrets or Keychain
- 🌍 Bilingual UI: English + 简体中文

### Supported Tools

| Tool | Status | Data source |
|---|---|---|
| Claude Code | ✅ Phase 1 | `~/.claude/stats-cache.json` + `~/.claude/projects/` |
| OpenAI Codex | ✅ Phase 1 | `~/.codex/state_5.sqlite` (`threads` table) |
| Ollama | 🚧 Phase 1.5 | `~/.ollama/logs/` (live tail) — deferred: Ollama does not persist token counts |

> By design, Burnbar sticks to **three providers**: closed-cloud (Claude), closed-cloud (Codex), open-local (Ollama). We will not expand to 40+ providers — that's CodexBar's path; ours is depth + cross-device + leaderboard.

### Status

🚧 **Early development.** Phase 1 (local Swift app) in progress. See [ROADMAP.md](ROADMAP.md).

### Requirements

- macOS 14+ (Sonoma)
- Xcode 15+ (for development)

### License

MIT © Andy Wu

---

## 中文

### 为什么需要 Burnbar

你用 Claude Code、Codex、Gemini、Grok 做 vibe coding 时，token 在哗哗烧——但你不知道在哪台机器烧得最多、加起来多少钱、什么时候会撞到 5 小时上限。

[CodexBar](https://github.com/steipete/CodexBar) 解决了单机统计，但需要读浏览器 cookies 和 Keychain。**Burnbar 走另一条路：**

- 🛡️ **绝不读浏览器数据，绝不碰 Keychain。** 只读本地 CLI 日志（`~/.claude`、`~/.codex` 等）
- 🖥️ **跨设备聚合。** 通过 iCloud Drive 同步，看到所有 Mac 加起来的总消耗
- 🌐 **全球榜单。** 可选启用，GitHub 登录，和社区比拼每日 token 消耗

### 功能

- 🔥 menu bar 实时 token 消耗指示
- 📊 5 小时 / 周 / 月 限额进度条
- 🖥️ 多设备聚合（iCloud Drive 同步）
- 🌐 可选的 GitHub 全球榜单
- 🛡️ 隐私优先：不碰浏览器密钥和 Keychain
- 🌍 双语 UI：English + 简体中文

### 支持工具

| 工具 | 状态 | 数据源 |
|---|---|---|
| Claude Code | ✅ Phase 1 | `~/.claude/stats-cache.json` + `~/.claude/projects/` |
| OpenAI Codex | ✅ Phase 1 | `~/.codex/state_5.sqlite` (`threads` 表) |
| Ollama | 🚧 Phase 1.5 | `~/.ollama/logs/`（实时 tail）——延后：Ollama 不持久化 token 统计 |

> Burnbar 刻意只做**三个 provider**：闭源云 (Claude)、闭源云 (Codex)、开源本地 (Ollama)。不会扩展到 40+ provider——那是 CodexBar 的路；我们走 "做深 + 跨设备 + 全球榜单"。

### 项目状态

🚧 **早期开发中。** Phase 1（本地 Swift app）进行中。详见 [ROADMAP.md](ROADMAP.md)。

### 环境要求

- macOS 14+ (Sonoma)
- Xcode 15+（开发用）

### 许可证

MIT © Andy Wu
