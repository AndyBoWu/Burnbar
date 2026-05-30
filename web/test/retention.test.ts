import { afterEach, describe, expect, it, vi } from 'vitest'
import { deleteMe, purgeOptedOut, retentionCutoff } from '../src/db'
import { scheduled } from '../src/index'
import type { Env } from '../src/app'
import { migratedTestDB } from './helpers/testDB'
import Database from 'better-sqlite3'

afterEach(() => vi.restoreAllMocks())

// "Now" anchor used across the suite; the 90-day cutoff is 2026-02-28.
const NOW = new Date('2026-05-29T03:00:00Z')

/** Insert a user with the given opt-in flag. */
function seedUser(raw: Database.Database, githubId: number, login: string, optedIn: 0 | 1): void {
  raw.prepare('INSERT INTO users (github_id, github_login, opted_in, hidden) VALUES (?, ?, ?, 0)').run(githubId, login, optedIn)
}

/** Insert a daily_usage row dated `date` (YYYY-MM-DD) for a user. */
function seedUsage(raw: Database.Database, githubId: number, date: string): void {
  raw.prepare('INSERT INTO daily_usage (github_id, date, provider, tokens, cost_usd) VALUES (?, ?, ?, ?, ?)').run(githubId, date, 'claude', 1000, 1.5)
}

function countUsage(raw: Database.Database, githubId: number): number {
  return (raw.prepare('SELECT COUNT(*) AS n FROM daily_usage WHERE github_id = ?').get(githubId) as { n: number }).n
}

describe('retentionCutoff', () => {
  it('is exactly RETENTION_DAYS (90) days before now, in UTC YYYY-MM-DD', () => {
    expect(retentionCutoff(new Date('2026-05-29T03:00:00Z'))).toBe('2026-02-28')
  })
})

describe('purgeOptedOut', () => {
  it('purges old opted-out rows, keeps opted-in (any age) and recent opted-out rows', async () => {
    const { db, raw } = migratedTestDB()
    // user 1: opted OUT — has one old row (purgeable) + one recent row (kept)
    seedUser(raw, 1, 'optedout', 0)
    seedUsage(raw, 1, '2026-01-01') // 148 days back → older than 90 → purge
    seedUsage(raw, 1, '2026-05-01') // 28 days back → recent → keep
    // user 2: opted IN — old row must be retained indefinitely
    seedUser(raw, 2, 'optedin', 1)
    seedUsage(raw, 2, '2026-01-01') // old but opted-in → keep

    const deleted = await purgeOptedOut(db as unknown as D1Database, NOW)

    expect(deleted).toBe(1)
    expect(countUsage(raw, 1)).toBe(1) // recent opted-out row kept
    expect(countUsage(raw, 2)).toBe(1) // opted-in old row kept
    const remaining = raw.prepare('SELECT date FROM daily_usage WHERE github_id = 1').all() as { date: string }[]
    expect(remaining.map((r) => r.date)).toEqual(['2026-05-01'])
  })

  it('keeps a row dated exactly on the cutoff (only strictly-older rows purge)', async () => {
    const { db, raw } = migratedTestDB()
    seedUser(raw, 1, 'optedout', 0)
    seedUsage(raw, 1, retentionCutoff(NOW)) // == cutoff → boundary kept
    seedUsage(raw, 1, '2026-02-27') // one day before cutoff → purged

    const deleted = await purgeOptedOut(db as unknown as D1Database, NOW)

    expect(deleted).toBe(1)
    expect(countUsage(raw, 1)).toBe(1)
  })

  it('returns 0 when there is nothing to purge', async () => {
    const { db, raw } = migratedTestDB()
    seedUser(raw, 2, 'optedin', 1)
    seedUsage(raw, 2, '2020-01-01') // ancient but opted-in → never purged
    expect(await purgeOptedOut(db as unknown as D1Database, NOW)).toBe(0)
  })
})

describe('scheduled() retention cron', () => {
  it('runs the purge and logs the deleted count', async () => {
    const { db, raw } = migratedTestDB()
    seedUser(raw, 1, 'optedout', 0)
    seedUsage(raw, 1, '2026-01-01')
    seedUsage(raw, 1, '2026-05-20')

    const lines: string[] = []
    vi.spyOn(console, 'log').mockImplementation((m: unknown) => {
      lines.push(String(m))
    })

    const event = { cron: '0 3 * * *', scheduledTime: NOW.getTime(), type: 'scheduled', noRetry() {} } as unknown as ScheduledController
    const env = { DB: db as unknown as D1Database } as Env
    const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext

    await scheduled(event, env, ctx)

    expect(countUsage(raw, 1)).toBe(1) // recent row survives
    const purgeLine = lines.map((l) => JSON.parse(l)).find((o) => o.message === 'retention_purge')
    expect(purgeLine).toMatchObject({ level: 'info', deleted: 1, cron: '0 3 * * *' })
  })
})

describe('manual delete coexists with retention (3.5.2 unaffected)', () => {
  it('deleteMe removes the user rows immediately, independent of age/opt-in', async () => {
    const { db, raw } = migratedTestDB()
    seedUser(raw, 1, 'optedin', 1)
    seedUsage(raw, 1, '2026-05-29') // brand-new, opted-in → retention never touches it

    await deleteMe(db as unknown as D1Database, 1)

    expect(countUsage(raw, 1)).toBe(0)
    const user = raw.prepare('SELECT COUNT(*) AS n FROM users WHERE github_id = 1').get() as { n: number }
    expect(user.n).toBe(0)
  })
})
