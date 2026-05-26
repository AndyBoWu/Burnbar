# Burnbar Plan

> Status: **OUTLINE + SUB-TICKETS — ready for GitHub issue creation.** Each sub-ticket maps to one GitHub Issue under its Epic (also an Issue) under its Milestone.

Four milestones. M1 + M1.5 ship Phase 1; M2 ships Phase 2; M3 ships Phase 3. Each milestone is independently shippable. Each epic is independently demoable. Each sub-ticket is one PR (half-day to one-day of work).

## Product form factor

**Decision: Hybrid (Menu Bar app + Settings window).**

- `LSUIElement = YES` — no Dock icon, menu bar icon is the primary entry.
- Menu bar **popover** is the glance UI: today's burn, progress bars, reset countdowns, quick toggles. 90% of usage.
- Native **Settings window** opens on demand for configuration that doesn't fit a popover: language, provider toggles, leaderboard opt-in, privacy controls, devices list. 10% of usage.
- Same pattern as CodexBar, 1Password menu helper, CleanShot X. Avoids the standalone-app trap of "open Dock → wait → see number → close" for what should be a glance.

## Provider scope

**Three providers, no more.** This is a deliberate boundary against CodexBar-style 40-provider sprawl.

1. **Claude Code** — closed cloud, subscription. M1.
2. **OpenAI Codex** — closed cloud, subscription. M1.
3. **Ollama** — open source, local. **M1.5** (Ollama doesn't persist token counts; requires a different implementation strategy than Claude/Codex — see [data-sources.md](data-sources.md)).

Anything beyond these three (Gemini, Grok, Cursor, Copilot, …) is out of scope — they conflict with the privacy thesis (need browser cookies / OAuth) or are pass-through wrappers.

---

## Milestone 1 — Local Swift App (Phase 1)

**Goal**: Native macOS menu bar app reading Claude Code + Codex CLI logs locally. No sync. No leaderboard. No Ollama yet.

**Definition of done**: User downloads DMG, drags to Applications, sees real token numbers from `~/.claude` and `~/.codex` within 5 seconds of launch. Bilingual UI (EN/ZH).

| # | Epic | One-line scope |
|---|---|---|
| 1.1 | **Project scaffold** | Xcode project with `LSUIElement=YES`, SwiftLint/SwiftFormat, GitHub Actions CI |
| 1.2 | **i18n foundation** | String Catalog (`.xcstrings`) with `en` + `zh-Hans`, locale override, lint rule against hardcoded strings |
| 1.3 | **Claude Code parser** | Read `~/.claude/stats-cache.json` + today's JSONL delta; emit unified `UsageRecord` |
| 1.4 | **Codex parser** | Read `~/.codex/state_5.sqlite` `threads` table; emit unified `UsageRecord` |
| 1.5 | **Token cost engine** | Pricing table (Sonnet/Opus/Haiku/GPT-5 variants, input/output/cache), $/day, monthly projection |
| 1.6 | **Menu bar UI + Settings window** | Popover (provider tiles, burn bars, reset countdowns) + minimal Settings (language, toggles, about) |
| 1.7 | **Release pipeline** | DMG + PKG build, ad-hoc signing for v0, LaunchAgent template, Sparkle skeleton |

**Epics: 7** · **Sub-tickets: 30**

### M1 sub-tickets

#### Epic 1.1: Project scaffold (4)

- **1.1.1 Init Xcode project**
  Bundle id `xyz.andybowu.Burnbar`, macOS 14+, Swift 6.3, SwiftUI `App` template, `LSUIElement=YES` in Info.plist.
  *DoD:* App launches as agent (no Dock icon); menu bar status item visible with placeholder SF Symbol.

- **1.1.2 SwiftLint + SwiftFormat config**
  Project-level `.swiftlint.yml` + `.swiftformat`; pre-commit hook via Lefthook.
  *DoD:* `make lint` fails on style violations; pre-commit blocks dirty commits.

- **1.1.3 GitHub Actions CI**
  `.github/workflows/build-and-test.yml` on push/PR, macOS-14 runner, runs `xcodebuild test` + lint.
  *DoD:* PRs show passing CI status; failing build/lint blocks merge.

- **1.1.4 Build scripts + dev docs**
  `Scripts/compile_and_run.sh`, `Scripts/package_app.sh`, README "Build from source" section.
  *DoD:* `./Scripts/compile_and_run.sh` builds and launches Burnbar.app from a clean clone.

#### Epic 1.2: i18n foundation (3)

- **1.2.1 String Catalog bootstrap**
  Create `Localizable.xcstrings`, add `en` and `zh-Hans` locales, seed with `app.name = "Burnbar"`.
  *DoD:* App reads strings via `String(localized:)`; builds with both locales.

- **1.2.2 Lint rule against hardcoded strings**
  Custom SwiftLint rule banning literal strings in `View` body except those marked `// i18n:ignore`.
  *DoD:* Rule fires on intentional violations in test fixtures.

- **1.2.3 Language picker in Settings**
  General tab dropdown `System default | English | 简体中文`; override via `AppleLanguages` UserDefaults.
  *DoD:* Selecting Chinese reloads UI in zh-Hans without restart.

#### Epic 1.3: Claude Code parser (5)

- **1.3.1 `StatsCacheReader`**
  Decode `~/.claude/stats-cache.json` (version 3 schema) into typed model: `dailyModelTokens`, `modelUsage`.
  *DoD:* On real machine, returns ≥ 30 days of per-model token counts; tested with fixture JSON.

- **1.3.2 `JSONLDeltaScanner`**
  For files in `~/.claude/projects/*/` with mtime ≥ today 00:00, stream-parse, keep `type=assistant`, extract `message.usage`.
  *DoD:* Returns sum of today's tokens by model; ignores non-assistant lines.

- **1.3.3 `UsageRecord` unified model**
  Provider-agnostic struct: `provider`, `model`, `day`, `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `costUSD`.
  *DoD:* Both Claude and Codex parsers emit this type.

- **1.3.4 Merge stats-cache + JSONL delta**
  `ClaudeUsageProvider` combines cache (≤ yesterday) + today's JSONL delta; avoids double-counting if cache already includes today.
  *DoD:* Total for today matches manual sum of today's `message.usage` from JSONLs.

- **1.3.5 Unit tests with fixtures**
  Anonymized snapshot of `stats-cache.json` + 3 sample JSONL lines. Cases: empty, single-model, multi-model.
  *DoD:* `swift test` passes; fixtures under `Tests/Fixtures/Claude/`.

#### Epic 1.4: Codex parser (4)

- **1.4.1 SQLite read-only helper**
  GRDB or raw SQLite3 wrapper opening `state_5.sqlite` in read-only mode (`?mode=ro` URI), handles WAL.
  *DoD:* Never holds write lock; works while Codex is running.

- **1.4.2 `CodexThreadsReader`**
  `SELECT DATE(created_at_ms/1000, 'unixepoch') day, model, SUM(tokens_used) FROM threads GROUP BY day, model`.
  *DoD:* On real machine, returns daily per-model totals matching manual SQL inspection.

- **1.4.3 Map to `UsageRecord`**
  Translate Codex query results into `UsageRecord`. `inputTokens = tokens_used`; other token fields = nil.
  *DoD:* Total matches threads sum; nil fields documented in `UsageRecord` doc comment.

- **1.4.4 Unit tests with fixture SQLite**
  Fixture `.sqlite` (committed binary) with 3 rows across 2 models, 2 days.
  *DoD:* `swift test` passes; fixture < 20 KB.

#### Epic 1.5: Token cost engine (4)

- **1.5.1 `PricingTable.swift`**
  Per-model rates for input, output, cache_read, cache_create (USD per million tokens).
  *DoD:* Covers all 5 Claude models on real machine + GPT-5 / GPT-5.5; source comment cites pricing pages with snapshot date.

- **1.5.2 `CostCalculator`**
  Apply pricing to `UsageRecord`. Unknown model → warn, treat as $0, surface as "Unknown model" in UI.
  *DoD:* Daily cost matches `claude-usage-tracker` (Python) output on identical input.

- **1.5.3 Time-window aggregator**
  Group `UsageRecord` into today / week / month buckets using user's local timezone.
  *DoD:* Bucket boundaries align with `Calendar.current`; DST transitions handled.

- **1.5.4 Pricing freshness check**
  Unit test fails if pricing snapshot date > 90 days old.
  *DoD:* `testPricingTableIsFresh` failure message includes "update PricingTable.swift".

#### Epic 1.6: Menu bar UI + Settings window (6)

- **1.6.1 `NSStatusItem` setup**
  `MenuBarController` owns the status item; SF Symbol `flame.fill`; subscribes to refresh notifications.
  *DoD:* Status item appears on launch; updates dynamically on data refresh.

- **1.6.2 Popover layout — provider tiles**
  `ProviderTileView`: per-provider card with today's $, today's tokens, top 3 models, last-updated timestamp.
  *DoD:* Layout matches mockup; renders correctly with 1 or 2 providers; "no data yet" state for fresh installs.

- **1.6.3 Burn bar component**
  `BurnBarView`: progress fill for 5h / weekly / monthly limit; percentage + countdown to next reset.
  *DoD:* Bars animate; reset times computed correctly (5h rolling, weekly fixed, monthly fixed).

- **1.6.4 Popover quick actions**
  Buttons: Refresh now, Open Settings, Quit. Right-click on menu bar icon = same in context menu.
  *DoD:* All actions reachable in ≤ 1 click; Quit terminates cleanly.

- **1.6.5 Settings window scaffold**
  SwiftUI `Settings` scene with `TabView`: General | Providers | About. Non-modal, single instance.
  *DoD:* `⌘,` opens Settings; closing window does not quit app.

- **1.6.6 Settings tabs content**
  General: language, theme (auto/light/dark), refresh rate. Providers: enable Claude/Codex toggles. About: version, GitHub link, privacy link.
  *DoD:* Each setting persists; provider toggle disables corresponding parser.

#### Epic 1.7: Release pipeline (4)

- **1.7.1 `Scripts/package_app.sh`**
  Build app bundle (Release config), ad-hoc sign (`codesign --sign -`), zip to `dist/Burnbar-vX.Y.Z.zip`.
  *DoD:* Output zip opens on a fresh Mac (right-click → Open the first time).

- **1.7.2 DMG packaging**
  Use `create-dmg` to build `Burnbar-vX.Y.Z.dmg` with drag-to-Applications layout.
  *DoD:* DMG mounts; install via drag works.

- **1.7.3 LaunchAgent template**
  `Scripts/install_launchagent.sh` creates `~/Library/LaunchAgents/xyz.andybowu.Burnbar.plist`; README documents enable/disable.
  *DoD:* Burnbar starts on login after install; uninstall script removes it.

- **1.7.4 Sparkle skeleton (no deploy)**
  Add Sparkle framework, generate EdDSA keypair, write `appcast.xml` template, document key custody. Auto-update **off** in v0.
  *DoD:* Sparkle integrated but no update endpoint; deferred to a future milestone.

---

## Milestone 1.5 — Ollama support (Phase 1.5)

**Goal**: Track Ollama usage and complete the 3-provider story, despite Ollama not persisting token counts to disk.

**Why separate from M1**: Ollama is fundamentally different from Claude/Codex:
- ❌ **No persistent token storage** (verified on a real machine: no `stats-cache`, no `tokens_used` column anywhere; only `eval_count` in ephemeral API responses)
- ❌ **No subscription cost** — `$` UI doesn't apply
- ❌ **No 5h/weekly/monthly limits** — limit bars don't apply
- ⚠️ **Different implementation strategy**: live log tailing + Burnbar's own SQLite for persistence

Splitting Ollama out keeps M1 fast (~2 weeks) instead of dragging it to 3+ weeks while we figure out the Ollama log format.

| # | Epic | One-line scope |
|---|---|---|
| 1.5.1 | **Ollama investigation** | Confirm exact log format with `OLLAMA_DEBUG=DEBUG`; spike on log-tail strategy |
| 1.5.2 | **Live log tailer + parser** | Tail `~/.ollama/logs/server-*.log`, parse Go-style structured lines, extract token counts |
| 1.5.3 | **Burnbar local DB** | SQLite at `~/Library/Application Support/Burnbar/usage.sqlite` to persist parsed Ollama usage |
| 1.5.4 | **Ollama-specific UI mode** | Provider tile shows "calls today / tokens generated / models used" instead of $ + burn bars |

**Epics: 4** · **Sub-tickets: TBD** (expanded after M1 ships and 1.5.1 investigation completes)

**Definition of done**: User has Ollama installed and running. Burnbar shows today's Ollama call count, total tokens generated, and per-model breakdown — for calls made *while Burnbar was running*. Acknowledged limitation: calls made when Burnbar is off are not counted (surfaced in UI as "Tracking since: <Burnbar install date>").

---

## Milestone 2 — Cross-Device Aggregation (Phase 2)

**Goal**: User installs Burnbar on a second Mac, signs in to same iCloud, and sees combined burn across both machines.

**Definition of done**: On Mac A: shows local burn = X. On Mac B: shows local burn = Y. Toggle "Combined view" → shows X + Y on both machines, with per-machine breakdown.

| # | Epic | One-line scope |
|---|---|---|
| 2.1 | **Machine identity** | Generate stable `machine_id` (hardware UUID hash), persist, display in Settings |
| 2.2 | **iCloud Drive writer** | Daily aggregate writer to `~/Library/Mobile Documents/com~apple~CloudDocs/Burnbar/{machine_id}.jsonl` |
| 2.3 | **Reconciler** | Read all machine files, merge into unified daily view (conflict-free: each machine owns its file) |
| 2.4 | **Combined view UI** | Toggle in popover, per-machine breakdown, "last sync" timestamp per machine |
| 2.5 | **Sync degradation** | Handle iCloud disabled, stale machines (> 30d), file in transit gracefully |

**Epics: 5** · **Sub-tickets: 18**

### M2 sub-tickets

#### Epic 2.1: Machine identity (3)

- **2.1.1 Hardware-UUID-based machine id**
  Read `IOPlatformUUID` from `IOPlatformExpertDevice`, hash with SHA-256, persist first 16 hex chars to UserDefaults.
  *DoD:* `machine_id` stable across reboots and reinstalls; ≤ 16 chars.

- **2.1.2 Human-readable machine label**
  Default to system computer name; user-editable in Settings → Devices.
  *DoD:* Label persists; rename reflects in UI immediately.

- **2.1.3 Settings → Devices placeholder tab**
  New tab showing this Mac's id, label, "last synced" timestamp (wired in 2.2.x).
  *DoD:* Tab visible; data updates when WriteController fires.

#### Epic 2.2: iCloud Drive writer (4)

- **2.2.1 iCloud container detection**
  Try `FileManager.default.url(forUbiquityContainerIdentifier: nil)`. If nil, fall back to `~/Library/Mobile Documents/com~apple~CloudDocs/Burnbar/`. Else report "iCloud unavailable".
  *DoD:* Returns valid URL on iCloud-enabled Mac; fallback path otherwise; clear error if neither.

- **2.2.2 Daily aggregate writer**
  Write per-day rollup to `{machine_id}.jsonl`, one line per (date, provider, model).
  *DoD:* File appears on Mac A, syncs to Mac B within ~2 min.

- **2.2.3 Atomic write**
  Write to `{machine_id}.tmp`, fsync, rename. Avoids partial reads during iCloud sync.
  *DoD:* Killing app mid-write does not corrupt file.

- **2.2.4 Write scheduler**
  Background task: every 5 min while running, on app quit, on system wake.
  *DoD:* `last-write-at` UserDefault updates at expected intervals.

#### Epic 2.3: Reconciler (4)

- **2.3.1 Multi-machine reader**
  Scan all `*.jsonl` files in the shared dir; parse each into `MachineUsage` snapshots.
  *DoD:* Returns `[machine_id: [UsageRecord]]`; missing/corrupt files: log + skip.

- **2.3.2 Per-machine identity table**
  Maintain `Machines` table in UserDefaults: known ids + labels + last-seen timestamps.
  *DoD:* New machines auto-added; renamed machines preserve label.

- **2.3.3 Merge into unified daily view**
  Union over (date, provider, model) across all machines; retain per-machine breakdown for drilldown.
  *DoD:* Total = sum of per-machine totals.

- **2.3.4 Stale machine detection**
  Tag machines with no update > 30 days as "stale"; dimmed in UI, excluded from combined view by default.
  *DoD:* Stale flag visible in Settings → Devices; toggle "include stale".

#### Epic 2.4: Combined view UI (4)

- **2.4.1 Popover view-mode toggle**
  Segmented control "This Mac | All Macs"; persists preference.
  *DoD:* Switching modes updates burn bars and tiles without restart.

- **2.4.2 All-Macs aggregate display**
  In "All Macs" mode, show summed burn + breakdown badge ("3 Macs syncing").
  *DoD:* Sum matches Reconciler output; badge click expands breakdown.

- **2.4.3 Per-machine breakdown panel**
  Expandable section listing each machine's today's burn, model split, last-sync timestamp.
  *DoD:* Renders correctly for 1–5 machines.

- **2.4.4 Devices tab — full table**
  Settings → Devices: table with label, id (truncated), today's burn, total burn, last sync. Actions: rename, hide, forget.
  *DoD:* All actions work; "forget" deletes local `{machine_id}.jsonl` after confirmation.

#### Epic 2.5: Sync degradation (3)

- **2.5.1 "iCloud disabled" badge**
  Detect missing ubiquity container → menu bar icon overlay (⚠️), tooltip "iCloud Drive disabled — sync off".
  *DoD:* Badge appears within 5 sec of iCloud disable; clears when re-enabled.

- **2.5.2 "Stale sync" warning**
  If local write fails or remote mtime > 30 min behind expected, surface "Last sync N min ago" warning in Settings.
  *DoD:* Warning text reflects actual delta; clears on resync.

- **2.5.3 Manual "Force resync"**
  Settings → Devices: button forces immediate write + read of all `{machine_id}.jsonl`.
  *DoD:* Completes within 3 sec; logs in `~/Library/Logs/Burnbar/sync.log`.

---

## Milestone 3 — Global Leaderboard (Phase 3)

**Goal**: Opt-in social layer at `burnbar.andybowu.xyz`. Users sign in with GitHub, opt in to upload daily aggregates, see daily/weekly/monthly leaderboards.

**Definition of done**: User clicks "Join leaderboard", signs in with GitHub via device flow, opts in. Within 24 h their daily burn appears on `burnbar.andybowu.xyz` leaderboard, ranked alongside other opted-in users. Personal profile shows history. Opt-out + delete-data both work.

| # | Epic | One-line scope |
|---|---|---|
| 3.1 | **Backend infra** | Cloudflare Workers + D1 schema (`users`, `daily_usage`), wrangler config, staging + prod |
| 3.2 | **GitHub OAuth Device Flow** | Menu bar app device-flow login, Keychain token storage (our service id), revoke flow |
| 3.3 | **Upload pipeline** | Daily aggregation upload (opted-in users only), retry/backoff, opt-out toggle, never upload prompt content |
| 3.4 | **Web leaderboard UI** | `burnbar.andybowu.xyz`: landing + daily/weekly/monthly rankings + individual profile, bilingual EN/ZH |
| 3.5 | **Privacy controls** | Hide-from-leaderboard, delete-all-my-data flow, retention policy, public privacy page |
| 3.6 | **Domain + DNS** | Configure `burnbar.andybowu.xyz` CNAME, TLS, Worker routes |

**Epics: 6** · **Sub-tickets: 28**

### M3 sub-tickets

#### Epic 3.1: Backend infra (5)

- **3.1.1 Cloudflare Workers project setup**
  Init wrangler project in `web/`, D1 binding, staging + prod via `wrangler.toml`.
  *DoD:* `wrangler deploy --env staging` succeeds; staging URL responds.

- **3.1.2 D1 schema migrations**
  `users` (github_id PK, github_login, joined_at, opted_in BOOL, hidden BOOL); `daily_usage` (github_id, date, provider, tokens, cost_usd, uploaded_at).
  *DoD:* `wrangler d1 migrations apply` creates both tables in staging + prod.

- **3.1.3 API endpoints**
  `POST /api/v1/usage` (auth), `GET /api/v1/leaderboard/:period` (public), `GET /api/v1/me` (auth), `DELETE /api/v1/me` (auth).
  *DoD:* All endpoints return documented status codes; integration tests cover happy + auth-fail paths.

- **3.1.4 Rate limiting**
  Workers KV-based token bucket: 10 req/min per github_id, 60 req/min per IP for unauth.
  *DoD:* Exceeding limit returns 429; counter resets correctly.

- **3.1.5 Observability**
  Workers Analytics enabled; structured logs (or console for v0).
  *DoD:* Error-rate dashboard visible; "last 24h errors" query works.

#### Epic 3.2: GitHub OAuth Device Flow (5)

- **3.2.1 GitHub App registration**
  Register "Burnbar" GitHub App with Device Flow; client_id committed in app, client_secret only in Workers env.
  *DoD:* Client_id in repo; secret never in repo.

- **3.2.2 Device flow UI in Settings**
  "Sign in with GitHub" → show 8-char user code + auto-open browser to `github.com/login/device`.
  *DoD:* User code is copyable; browser opens.

- **3.2.3 Token polling + exchange**
  Poll `POST github.com/login/oauth/access_token` at 5-sec interval until completion or 15 min timeout.
  *DoD:* On success: token received and stored; on timeout: clear error + retry option.

- **3.2.4 Keychain storage**
  Store access_token in Keychain under service `xyz.andybowu.Burnbar.github-token`. Our service identifier, not third-party.
  *DoD:* Token survives app restarts; visible in Keychain Access.app under our service.

- **3.2.5 Sign-out + revoke**
  "Sign out" clears Keychain entry; "Revoke" also calls GitHub revocation endpoint.
  *DoD:* After sign-out, `/api/v1/me` returns 401; Keychain entry absent.

#### Epic 3.3: Upload pipeline (5)

- **3.3.1 Daily aggregator**
  Roll up all machines' usage (via Reconciler) to `(date, provider, total_tokens, cost)`. Run once per day.
  *DoD:* Output matches sum of `{machine_id}.jsonl`; no prompts, paths, machine ids, raw model names.

- **3.3.2 Upload scheduler**
  Default upload time 03:00 local; jitter ± 30 min. Exponential backoff up to 24 h on failure.
  *DoD:* Upload occurs within ± 30 min of 03:00; failed uploads retry.

- **3.3.3 Payload validator**
  Pre-upload check: payload contains only `{date, provider, tokens, cost_usd}`. Reject if any other key.
  *DoD:* Unit tests cover bad payloads with extra fields, all rejected.

- **3.3.4 Leaderboard settings tab**
  Opt-in toggle, last-uploaded timestamp, "Upload now" button, link to web profile.
  *DoD:* Toggle off disables uploads; toggle on triggers immediate upload (subject to validator).

- **3.3.5 Offline queue**
  Persist unsent uploads to disk; on next online (NWPathMonitor), drain queue.
  *DoD:* Cut network mid-upload → recovers on reconnect; no duplicates.

#### Epic 3.4: Web leaderboard UI (6)

- **3.4.1 Web stack & deploy**
  Next.js (App Router) + Tailwind on Cloudflare Pages. Bilingual via `next-intl`.
  *DoD:* `pnpm dev` runs; `wrangler pages deploy` ships staging.

- **3.4.2 Landing page**
  Hero, "How it works", privacy promise, download button.
  *DoD:* Lighthouse ≥ 90 on perf/a11y; bilingual toggle in header.

- **3.4.3 Leaderboard pages**
  `/leaderboard/daily`, `/weekly`, `/monthly`. Paginated, sortable, refresh every 5 min.
  *DoD:* Top 100 per page; click user → profile.

- **3.4.4 Individual profile page**
  `/u/<github_login>`: avatar, login, 90-day burn line chart, per-provider breakdown.
  *DoD:* Hidden / opted-out users return 404 with no historical leak.

- **3.4.5 i18n on web**
  Same `en` + `zh-Hans` keys; locale switcher in header; route prefix `/zh/...`.
  *DoD:* `/zh/leaderboard/daily` shows zh-Hans; English fallback for missing keys.

- **3.4.6 OG cards + SEO**
  Per-page OG image, Twitter card, sitemap.xml, robots.txt.
  *DoD:* Share URL on X → preview image renders with current top-3.

#### Epic 3.5: Privacy controls (4)

- **3.5.1 Hide-from-leaderboard toggle**
  Setting flips `users.hidden = true`. User's data still uploaded for personal history, excluded from rankings.
  *DoD:* Hidden user absent from `/leaderboard/*`; their profile 404 to others.

- **3.5.2 Delete-all-my-data flow**
  Red button → confirm → `DELETE /api/v1/me` → clear local Keychain + opt-in.
  *DoD:* D1 rows removed; user can re-join (creates new record); no orphan rows.

- **3.5.3 Data retention policy**
  Opted-in: retain indefinitely. Opted-out: retain 90 days then purge via daily Workers cron.
  *DoD:* Cron logs purge counts; manual delete is immediate.

- **3.5.4 Privacy policy page**
  `/privacy` (bilingual): what we collect, what we don't, retention, opt-out, contact.
  *DoD:* Linked from app Settings + web footer; reviewed against actual code.

#### Epic 3.6: Domain + DNS (3)

- **3.6.1 DNS CNAME**
  Cloudflare DNS for `andybowu.xyz`: CNAME `burnbar` → Pages domain.
  *DoD:* `dig burnbar.andybowu.xyz` resolves.

- **3.6.2 Worker route**
  `wrangler.toml`: `burnbar.andybowu.xyz/api/*` → API Worker; rest → Pages.
  *DoD:* `/api/v1/*` reachable; non-API paths serve web.

- **3.6.3 TLS + force HTTPS**
  Universal SSL on; HTTP → HTTPS redirect; HSTS header from Worker.
  *DoD:* `curl -v http://burnbar.andybowu.xyz` returns 301; SSL Labs ≥ A.

---

## Summary

| Milestone | Epics | Sub-tickets | Est. duration |
|---|---|---|---|
| 1 — Local Swift App (Claude + Codex) | 7 | 30 | 1–2 weeks |
| 1.5 — Ollama support | 4 | TBD | ~1 week (after M1) |
| 2 — Cross-Device Aggregation | 5 | 18 | 1 week |
| 3 — Global Leaderboard | 6 | 28 | 2–3 weeks |
| **Total** | **22** | **~76** | **5–7 weeks** |

---

## Decisions log

- ✅ **Product form factor**: Hybrid (Menu Bar + Settings window). Folded into Epic 1.6.
- ✅ **Provider scope**: 3 providers exactly — Claude, Codex, Ollama. No more.
- ✅ **Provider sequencing**: M1 = Claude + Codex (clean data). M1.5 = Ollama (different strategy — no persistent token storage; needs live log tail + own DB; different UI mode).
- ✅ **Gemini / Grok / Cursor**: out of scope (conflict with privacy thesis or are pass-through).
- ✅ **Milestone structure**: 4 milestones, M1.5 inserted to separate Ollama work from M1 timing.
- ✅ **M1 dependency order**: scaffold → i18n → parsers → cost → UI → release.
- ✅ **M3 backend**: Cloudflare Workers + D1.
- ✅ **Sparkle**: skeleton only in Epic 1.7 (no Apple Developer cert yet).

## Open questions

(none currently — outline + sub-tickets approved. Next: create GitHub Milestones / Issues / Sub-issues from this document.)
