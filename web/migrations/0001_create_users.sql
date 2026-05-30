-- Burnbar leaderboard: GitHub identity + opt-in/hidden flags.
-- Privacy: NO content/identifying columns ever (see migrations/README.md).
CREATE TABLE IF NOT EXISTS users (
  github_id    INTEGER PRIMARY KEY,
  github_login TEXT    NOT NULL,
  joined_at    TEXT    NOT NULL DEFAULT (datetime('now')),
  opted_in     INTEGER NOT NULL DEFAULT 0 CHECK (opted_in IN (0, 1)),
  hidden       INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0, 1))
);
