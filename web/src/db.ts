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

export async function deleteMe(db: D1Database, githubId: number): Promise<void> {
  // daily_usage cascades via the FK, but delete explicitly too in case PRAGMA
  // foreign_keys is off on the connection.
  await db.prepare('DELETE FROM daily_usage WHERE github_id = ?').bind(githubId).run()
  await db.prepare('DELETE FROM users WHERE github_id = ?').bind(githubId).run()
}
