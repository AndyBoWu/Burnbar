import { describe, expect, it } from 'vitest'
import { migratedTestDB } from './helpers/testDB'

describe('D1 migrations', () => {
  it('creates the users and daily_usage tables', () => {
    const { raw } = migratedTestDB()
    const tables = raw
      .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
      .all()
      .map((r: unknown) => (r as { name: string }).name)
    expect(tables).toContain('users')
    expect(tables).toContain('daily_usage')
  })

  it('users has exactly the leaderboard-safe columns (no content/identifying fields)', () => {
    const { raw } = migratedTestDB()
    const cols = raw.prepare('PRAGMA table_info(users)').all().map((c: unknown) => (c as { name: string }).name)
    expect(new Set(cols)).toEqual(new Set(['github_id', 'github_login', 'joined_at', 'opted_in', 'hidden']))
  })

  it('daily_usage stores only aggregate {date, provider, tokens, cost_usd} (+ keys/timestamps)', () => {
    const { raw } = migratedTestDB()
    const cols = raw.prepare('PRAGMA table_info(daily_usage)').all().map((c: unknown) => (c as { name: string }).name)
    expect(new Set(cols)).toEqual(new Set(['github_id', 'date', 'provider', 'tokens', 'cost_usd', 'uploaded_at']))
    // Defense-in-depth: assert no forbidden column ever sneaks in.
    for (const forbidden of ['cwd', 'git_branch', 'git_sha', 'machine_id', 'model', 'content', 'preview', 'title']) {
      expect(cols).not.toContain(forbidden)
    }
  })

  it('caps provider to claude/codex via CHECK', () => {
    const { raw } = migratedTestDB()
    raw.prepare('INSERT INTO users (github_id, github_login) VALUES (1, ?)').run('octocat')
    const insert = raw.prepare('INSERT INTO daily_usage (github_id, date, provider, tokens, cost_usd) VALUES (1, ?, ?, ?, ?)')
    expect(() => insert.run('2026-05-30', 'claude', 1000, 1.5)).not.toThrow()
    expect(() => insert.run('2026-05-30', 'gemini', 1000, 1.5)).toThrow()
  })

  it('enforces idempotent upsert key (github_id, date, provider)', () => {
    const { raw } = migratedTestDB()
    raw.prepare('INSERT INTO users (github_id, github_login) VALUES (1, ?)').run('octocat')
    const ins = raw.prepare('INSERT INTO daily_usage (github_id, date, provider, tokens, cost_usd) VALUES (1, ?, ?, ?, ?)')
    ins.run('2026-05-30', 'claude', 1000, 1.5)
    expect(() => ins.run('2026-05-30', 'claude', 2000, 3.0)).toThrow() // PK conflict → upsert in app layer
  })

  it('cascades daily_usage deletion when a user is deleted', () => {
    const { raw } = migratedTestDB()
    raw.prepare('INSERT INTO users (github_id, github_login) VALUES (1, ?)').run('octocat')
    raw.prepare('INSERT INTO daily_usage (github_id, date, provider, tokens, cost_usd) VALUES (1, ?, ?, ?, ?)').run('2026-05-30', 'claude', 1000, 1.5)
    raw.prepare('DELETE FROM users WHERE github_id = 1').run()
    const remaining = raw.prepare('SELECT COUNT(*) AS n FROM daily_usage').get() as { n: number }
    expect(remaining.n).toBe(0)
  })
})
