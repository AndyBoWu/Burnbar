# Burnbar Data Sources

Result of scanning a real developer Mac running Claude Code, Codex CLI, and Ollama. Source of truth for parser implementation. **Reviewed: 2026-05-25.**

## TL;DR

| Tool | Primary source | Format | Pre-aggregated? | Strategy |
|---|---|---|---|---|
| Claude Code | `~/.claude/stats-cache.json` | JSON | ✅ Per-day, per-model | Read cache + today's JSONL delta |
| OpenAI Codex | `~/.codex/state_5.sqlite` (`threads`) | SQLite | ❌ but cheap `GROUP BY` | One `SELECT … GROUP BY day, model` |
| Ollama | (no persistent token data!) | — | ❌ — verified empty | Live log tail + Burnbar's own DB (M1.5) |

All sources are local files maintained by the respective tools. **Burnbar never touches browsers or the system Keychain.**

---

## Claude Code

### Directory: `~/.claude/` (52 MB observed, 103 JSONL files)

| Path | Purpose | Read? |
|---|---|---|
| `~/.claude/stats-cache.json` | Token statistics cache (Claude Code maintains it) | ✅ **Primary source** |
| `~/.claude/projects/<encoded-cwd>/<session>.jsonl` | Per-session conversation log incl. token usage | ✅ Today's mtime files only |
| `~/.claude/history.jsonl` | Global command history (contains prompts) | ❌ Contains content |
| `~/.claude/sessions/` (mode 700) | Daemon internal state | ❌ Not needed |
| `~/.claude/auth.json` (if present) | OAuth credentials | ❌ Forever |
| `~/Library/Application Support/Claude/` | Claude Desktop app (different product) | ❌ Not Claude Code |

### `stats-cache.json` schema (version 3)

```jsonc
{
  "version": 3,
  "lastComputedDate": "2026-05-24",
  "dailyActivity": [
    { "date": "2026-04-24", "messageCount": 26, "sessionCount": 1, "toolCallCount": 2 }
  ],
  "dailyModelTokens": [
    { "date": "2026-01-10", "tokensByModel": { "claude-opus-4-5-20251101": <int>, ... } }
  ],
  "modelUsage": {
    "claude-opus-4-7": {
      "inputTokens": 63474,
      "outputTokens": 1592614,
      "cacheReadInputTokens": 65907504,
      "cacheCreationInputTokens": 4270790,
      "webSearchRequests": 0
    }
    // ... one entry per model
  },
  "totalSessions": <int>,
  "totalMessages": <int>,
  "firstSessionDate": "ISO8601",
  "hourCounts": { "0": <int>, "1": <int>, ... },
  "totalSpeculationTimeSavedMs": <int>
}
```

**Privacy**: contains aggregates only — no prompts, no responses. Safe to read.

### JSONL per-message format (today's delta only)

```jsonc
{
  "type": "assistant",
  "timestamp": "...",
  "message": {
    "model": "claude-opus-4-7",
    "usage": {
      "input_tokens": 2,
      "cache_creation_input_tokens": 31824,
      "cache_read_input_tokens": 0,
      "output_tokens": 137,
      "server_tool_use": {
        "web_search_requests": 0,
        "web_fetch_requests": 0
      }
    },
    "content": [...]  // ⚠ contains response text — DO NOT READ
  }
}
```

Burnbar reads **only** `type`, `timestamp`, `message.usage`, `message.model`. **Never reads `message.content` or `text` fields anywhere.**

### Project directory naming convention

`~/.claude/projects/<encoded-cwd>/` where `<encoded-cwd>` is the cwd with `/` replaced by `-`.

Example: cwd `/Users/andy/Repos/andybowu` → dir `-Users-andy-Repos-andybowu`.

Burnbar may surface project name locally in UI, **but must never upload it to the leaderboard** (filesystem layout leak).

### Models observed on real machine

- `claude-opus-4-7`
- `claude-opus-4-6`
- `claude-opus-4-5-20251101`
- `claude-sonnet-4-6`
- `claude-haiku-4-5-20251001`

PricingTable.swift must cover all of these plus expected future variants.

---

## OpenAI Codex

### Directory: `~/.codex/` (424 MB observed)

| Path | Purpose | Read? |
|---|---|---|
| `~/.codex/state_5.sqlite` | Threads, jobs, agent state | ✅ **Primary source** (`threads` table only) |
| `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | Per-message rollout per session | ✅ Optional (per-message detail; not needed for P1) |
| `~/.codex/logs_2.sqlite` (82 MB) | Telemetry / debug log | ❌ Not token-related |
| `~/.codex/goals_1.sqlite` | Goals feature | ❌ Not token-related |
| `~/.codex/.codex-global-state.json` | Electron UI state | ❌ Window positions etc. |
| `~/.codex/auth.json` | OAuth credentials | ❌ Forever |
| `~/.codex/history.jsonl` | Global command history (contains prompts) | ❌ Contains content |

### `state_5.sqlite` → `threads` table schema

```sql
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  rollout_path TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  source TEXT NOT NULL,
  model_provider TEXT NOT NULL,
  cwd TEXT NOT NULL,
  title TEXT NOT NULL,
  sandbox_policy TEXT NOT NULL,
  approval_mode TEXT NOT NULL,
  tokens_used INTEGER NOT NULL DEFAULT 0,    -- 👈 the field we want
  has_user_event INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  archived_at INTEGER,
  git_sha TEXT,
  git_branch TEXT,
  git_origin_url TEXT,
  cli_version TEXT NOT NULL DEFAULT '',
  first_user_message TEXT NOT NULL DEFAULT '',   -- ⚠ contains prompt — DO NOT READ
  agent_nickname TEXT,
  agent_role TEXT,
  memory_mode TEXT NOT NULL DEFAULT 'enabled',
  model TEXT,                                    -- 👈 also needed
  reasoning_effort TEXT,
  agent_path TEXT,
  created_at_ms INTEGER,                         -- 👈 timestamp for daily bucketing
  updated_at_ms INTEGER,
  thread_source TEXT,
  preview TEXT NOT NULL DEFAULT ''               -- ⚠ contains content — DO NOT READ
);
```

### Burnbar's Codex query

```sql
SELECT
  DATE(created_at_ms / 1000, 'unixepoch') AS day,
  COALESCE(model, 'unknown') AS model,
  SUM(tokens_used) AS tokens
FROM threads
WHERE created_at_ms IS NOT NULL
GROUP BY day, model
ORDER BY day DESC;
```

**Fields read**: `tokens_used`, `model`, `created_at_ms`, `updated_at_ms`, `cli_version`, `reasoning_effort`.

**Fields never read**: `title`, `first_user_message`, `preview`, `cwd`, `git_*`, `rollout_path` — these leak user content or filesystem structure.

### Codex token granularity caveat

Codex stores **only `tokens_used` (a single integer)** per thread — no breakdown into input / output / cache_read / cache_create.

Burnbar's `UsageRecord` for Codex: set `inputTokens = tokens_used`, leave `outputTokens`, `cacheReadTokens`, `cacheCreationTokens` as `nil`. UI must handle this asymmetry: Codex tile shows total only; Claude tile can show stacked input/output/cache breakdown.

If more detail is needed later, fall back to scanning `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` per-message events.

---

## Ollama (M1.5 — partial)

### Directory: `~/.ollama/` + `~/Library/Application Support/Ollama/`

| Path | Purpose | Read? |
|---|---|---|
| `~/.ollama/logs/server-*.log` | Daemon logs; HTTP request metadata | ⚠️ Tailed live for token counts (TBD: M1.5.1 to confirm exact format with `OLLAMA_DEBUG=DEBUG`) |
| `~/.ollama/logs/app-*.log` | Desktop app UI events | ❌ No relevant data |
| `~/.ollama/history` | Plaintext prompt history | ❌ Contains prompts |
| `~/.ollama/models/` | Downloaded model blobs (large) | ❌ Not relevant for usage |
| `~/.ollama/id_ed25519`, `id_ed25519.pub` | Ollama Hub auth keys | ❌ Forever |
| `~/Library/Application Support/Ollama/db.sqlite` | Desktop app chat DB | ❌ See note below |

### Verified: Ollama does NOT persist token counts

Confirmed on real machine running Ollama 0.12.6 (CLI + Desktop):

- `~/.ollama/logs/server-*.log` → no `eval_count`, no `prompt_eval_count` in default INFO logs (only HTTP request metadata)
- `~/Library/Application Support/Ollama/db.sqlite` → `messages` table has `content`, `thinking_time_start/end` etc., **no `tokens_used` column**:
  ```sql
  CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL DEFAULT '',         -- ⚠ contains user prompts and model responses — DO NOT READ
    thinking TEXT NOT NULL DEFAULT '',         -- ⚠ contains thinking traces — DO NOT READ
    model_name TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    thinking_time_start TIMESTAMP,
    thinking_time_end TIMESTAMP,
    tool_result TEXT
    -- NO tokens_used, eval_count, or similar
  );
  ```
- Token counts (`eval_count`, `prompt_eval_count`) are only present in API response bodies, ephemeral

### Strategy implication for M1.5

Burnbar must:

1. **Tail** `~/.ollama/logs/server-*.log` in real time, possibly requiring user to set `OLLAMA_DEBUG=DEBUG` (TBD M1.5.1)
2. **Parse** log lines for token counts when they appear
3. **Persist** parsed data in Burnbar's own SQLite under `~/Library/Application Support/Burnbar/usage.sqlite`
4. **Acknowledge**: calls made while Burnbar is *not* running are NOT captured. UI must surface "Tracking since: <date>"

### UI implication

Ollama tile in popover differs from Claude/Codex:

- **No `$` cost** (Ollama is free) — show "calls today" or "tokens generated today" instead
- **No limit bars** (no quotas)
- **Show**: calls today, tokens generated, models used, GPU time (if available)
- **Reset countdown**: not applicable

### Models observed on real machine

`qwen3:30b` is loaded. Full inventory at `~/.ollama/models/manifests/registry.ollama.ai/`.

---

## What Burnbar never reads (everywhere)

| Source | Why excluded |
|---|---|
| Browser cookies, Local Storage, IndexedDB | Core privacy thesis |
| macOS Keychain — third-party items | Same. We only use Keychain for **our own** items (Burnbar's GitHub token in M3) |
| `auth.json` files from any CLI | Forever |
| `*.content`, `*.text`, `first_user_message`, `preview`, `title` fields anywhere | User content |
| `cwd`, `git_branch`, `git_origin_url` (used as project labels locally — never uploaded) | Filesystem layout |
| Claude Desktop app data | Different product, not in scope |
| Ollama `history` file, `db.sqlite.messages.content`, `db.sqlite.messages.thinking` | User content |

---

## Adding a new provider (template — for future use only)

**Provider scope is locked at 3 (Claude + Codex + Ollama).** This template exists for hypothetical future expansion only. Before adding any provider, the privacy thesis must be re-evaluated.

When investigating a new provider, fill in:

1. **Directory(ies)** used by the tool on macOS
2. **Files table** (read / never read / why)
3. **Schema** of primary source(s)
4. **Burnbar's query / extraction logic** (SQL / JSON path / log parse)
5. **Granularity caveats** (input/output/cache split? cost? limits? per-message vs aggregate?)
6. **Privacy exclusions** — explicit list of fields never read
7. **Models observed** on a real machine
