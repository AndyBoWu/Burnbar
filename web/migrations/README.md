# Burnbar D1 schema

Two tables, deliberately content-free.

## `users`
`github_id` (PK), `github_login`, `joined_at`, `opted_in`, `hidden`.

## `daily_usage`
`(github_id, date, provider)` PK (idempotent upsert), `tokens`, `cost_usd`, `uploaded_at`. `provider` CHECK-capped to `claude`/`codex`; FK to `users` with `ON DELETE CASCADE`; index on `(date, provider)`.

## Never store
No `*.content`, `first_user_message`, `preview`, `title`, `cwd`, `git_*`, `machine_id`, project dirs, or raw model names. Only the four leaderboard-safe fields per row.
