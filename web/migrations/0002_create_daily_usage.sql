-- Per-day, per-provider leaderboard rollup. The composite PK makes uploads
-- idempotent (upsert on (github_id, date, provider)).
-- Privacy: stores ONLY aggregate tokens + cost_usd. NEVER cwd, git_*,
-- machine_id, raw model names, project dirs, or any *.content / first_user_message
-- / preview / title. provider is capped to the two supported providers.
CREATE TABLE IF NOT EXISTS daily_usage (
  github_id   INTEGER NOT NULL REFERENCES users (github_id) ON DELETE CASCADE,
  date        TEXT    NOT NULL,
  provider    TEXT    NOT NULL CHECK (provider IN ('claude', 'codex')),
  tokens      INTEGER NOT NULL CHECK (tokens >= 0),
  cost_usd    REAL    NOT NULL CHECK (cost_usd >= 0),
  uploaded_at TEXT    NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (github_id, date, provider)
);

-- Leaderboard period queries scan by (date, provider).
CREATE INDEX IF NOT EXISTS idx_daily_usage_date_provider ON daily_usage (date, provider);
