// All persistence for the leaderboard API. Stores ONLY leaderboard-safe
// aggregates (date, provider, tokens, cost_usd) per (github_id, date, provider).

export const PROVIDERS = ['claude', 'codex'] as const
export type Provider = (typeof PROVIDERS)[number]

export interface UsageInput {
  date: string
  provider: Provider
  tokens: number
  cost_usd: number
}

export type Period = 'daily' | 'weekly' | 'monthly'
export const PERIODS: Period[] = ['daily', 'weekly', 'monthly']

export interface LeaderboardRow {
  github_login: string
  tokens: number
  cost_usd: number
}

export async function ensureUser(db: D1Database, githubId: number, login: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO users (github_id, github_login, opted_in, hidden) VALUES (?, ?, 1, 0)
       ON CONFLICT(github_id) DO UPDATE SET github_login = excluded.github_login`,
    )
    .bind(githubId, login)
    .run()
}

export async function upsertUsage(db: D1Database, githubId: number, row: UsageInput): Promise<void> {
  await db
    .prepare(
      `INSERT INTO daily_usage (github_id, date, provider, tokens, cost_usd, uploaded_at)
       VALUES (?, ?, ?, ?, ?, datetime('now'))
       ON CONFLICT(github_id, date, provider)
       DO UPDATE SET tokens = excluded.tokens, cost_usd = excluded.cost_usd, uploaded_at = datetime('now')`,
    )
    .bind(githubId, row.date, row.provider, row.tokens, row.cost_usd)
    .run()
}

/** Inclusive window-start `YYYY-MM-DD`: daily = today, weekly = 6 days back, monthly = 29 days back. */
export function windowStart(period: Period, now: Date): string {
  const back = period === 'daily' ? 0 : period === 'weekly' ? 6 : 29
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - back))
  return start.toISOString().slice(0, 10)
}

export async function leaderboard(db: D1Database, period: Period, now: Date): Promise<LeaderboardRow[]> {
  const result = await db
    .prepare(
      `SELECT u.github_login AS github_login,
              SUM(d.tokens) AS tokens,
              SUM(d.cost_usd) AS cost_usd
       FROM daily_usage d
       JOIN users u ON u.github_id = d.github_id
       WHERE u.opted_in = 1 AND u.hidden = 0 AND d.date >= ?
       GROUP BY d.github_id, u.github_login
       ORDER BY tokens DESC, github_login ASC
       LIMIT 100`,
    )
    .bind(windowStart(period, now))
    .all<LeaderboardRow>()
  return result.results
}

export interface MeResponse {
  github_id: number
  github_login: string
  opted_in: boolean
  hidden: boolean
  history: { date: string; provider: string; tokens: number; cost_usd: number }[]
}

export async function getMe(db: D1Database, githubId: number): Promise<MeResponse | null> {
  const user = await db
    .prepare('SELECT github_id, github_login, opted_in, hidden FROM users WHERE github_id = ?')
    .bind(githubId)
    .first<{ github_id: number; github_login: string; opted_in: number; hidden: number }>()
  if (!user) return null
  const history = await db
    .prepare('SELECT date, provider, tokens, cost_usd FROM daily_usage WHERE github_id = ? ORDER BY date DESC')
    .bind(githubId)
    .all<{ date: string; provider: string; tokens: number; cost_usd: number }>()
  return {
    github_id: user.github_id,
    github_login: user.github_login,
    opted_in: user.opted_in === 1,
    hidden: user.hidden === 1,
    history: history.results,
  }
}

/** Days of per-user public-profile history exposed at `/api/v1/u/:login`. */
export const PROFILE_HISTORY_DAYS = 90

export interface ProfilePoint {
  date: string
  tokens: number
  cost_usd: number
}

export interface PublicProfile {
  github_login: string
  history: ProfilePoint[]
}

/** Inclusive `YYYY-MM-DD` start of the public-profile window (89 days back + today = 90 days). */
export function profileWindowStart(now: Date): string {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - (PROFILE_HISTORY_DAYS - 1)))
  return start.toISOString().slice(0, 10)
}

/**
 * Public profile for `/api/v1/u/:login` (3.4.4). Returns the user's last-90-days
 * daily burn series ONLY when the user is opted_in AND not hidden; otherwise
 * `null` so the caller returns a 404 with no historical data leaked.
 *
 * The lookup is by `github_login` (case-insensitive). Per-day tokens/cost are
 * summed across providers so the public series carries no provider/model/path
 * detail — only the leaderboard-safe `{date, tokens, cost_usd}` shape.
 */
export async function publicProfile(db: D1Database, login: string, now: Date): Promise<PublicProfile | null> {
  const user = await db
    .prepare('SELECT github_id, github_login, opted_in, hidden FROM users WHERE github_login = ? COLLATE NOCASE')
    .bind(login)
    .first<{ github_id: number; github_login: string; opted_in: number; hidden: number }>()
  // Privacy gate: unknown, opted-out, or hidden users expose nothing (404 upstream).
  if (!user || user.opted_in !== 1 || user.hidden !== 0) return null
  const history = await db
    .prepare(
      `SELECT date AS date, SUM(tokens) AS tokens, SUM(cost_usd) AS cost_usd
       FROM daily_usage
       WHERE github_id = ? AND date >= ?
       GROUP BY date
       ORDER BY date ASC`,
    )
    .bind(user.github_id, profileWindowStart(now))
    .all<ProfilePoint>()
  return { github_login: user.github_login, history: history.results }
}

export interface UserFlags {
  hidden?: boolean
  opted_in?: boolean
}

/**
 * Update the authenticated user's privacy flags (`hidden` / `opted_in`).
 * Only the flags present in `flags` are written; omitted flags are left as-is.
 * Returns the number of rows changed (0 if the user row does not exist yet).
 */
export async function updateUserFlags(db: D1Database, githubId: number, flags: UserFlags): Promise<number> {
  const sets: string[] = []
  const values: number[] = []
  if (flags.hidden !== undefined) {
    sets.push('hidden = ?')
    values.push(flags.hidden ? 1 : 0)
  }
  if (flags.opted_in !== undefined) {
    sets.push('opted_in = ?')
    values.push(flags.opted_in ? 1 : 0)
  }
  if (sets.length === 0) return 0
  const result = await db
    .prepare(`UPDATE users SET ${sets.join(', ')} WHERE github_id = ?`)
    .bind(...values, githubId)
    .run()
  return result.meta.changes
}

export async function deleteMe(db: D1Database, githubId: number): Promise<void> {
  // daily_usage cascades via the FK, but delete explicitly too in case PRAGMA
  // foreign_keys is off on the connection.
  await db.prepare('DELETE FROM daily_usage WHERE github_id = ?').bind(githubId).run()
  await db.prepare('DELETE FROM users WHERE github_id = ?').bind(githubId).run()
}

/** Days of daily_usage history retained for opted-OUT users (3.5.3 retention policy). */
export const RETENTION_DAYS = 90

/** Inclusive `YYYY-MM-DD` retention cutoff: rows dated strictly before this are purgeable. */
export function retentionCutoff(now: Date): string {
  const cutoff = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - RETENTION_DAYS))
  return cutoff.toISOString().slice(0, 10)
}

/**
 * Data-retention purge (3.5.3): delete `daily_usage` rows older than
 * `RETENTION_DAYS` belonging to opted-OUT users (`users.opted_in = 0`).
 *
 * Retention rule, by design:
 *   - `opted_in = 1` → retain indefinitely (never touched here).
 *   - `opted_in = 0` → purge rows with `date < cutoff` (90 days back).
 *
 * Recent opted-out rows and ALL opted-in rows are kept. Returns the number of
 * rows deleted so the caller can log it.
 */
export async function purgeOptedOut(db: D1Database, now: Date): Promise<number> {
  const cutoff = retentionCutoff(now)
  const result = await db
    .prepare(
      `DELETE FROM daily_usage
       WHERE date < ?
         AND github_id IN (SELECT github_id FROM users WHERE opted_in = 0)`,
    )
    .bind(cutoff)
    .run()
  return result.meta.changes
}
