import { describe, expect, it } from 'vitest'
import { createApp } from '../src/app'
import { migratedTestDB } from './helpers/testDB'

function setup() {
  const { db, raw } = migratedTestDB()
  const app = createApp({
    verifyToken: async (t) =>
      t === 'good'
        ? { githubId: 1, githubLogin: 'octocat' }
        : t === 'good2'
          ? { githubId: 2, githubLogin: 'hubot' }
          : null,
    now: () => new Date('2026-05-30T12:00:00Z'),
  })
  const env = { DB: db as unknown as D1Database }
  const authed = (token = 'good') => ({ Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' })
  return { app, env, raw, authed }
}

const validBody = { date: '2026-05-30', provider: 'claude', tokens: 1000, cost_usd: 1.5 }

describe('POST /api/v1/usage', () => {
  it('accepts a valid payload and upserts (201)', async () => {
    const { app, env, raw, authed } = setup()
    const res = await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    expect(res.status).toBe(201)
    const row = raw.prepare('SELECT tokens, cost_usd FROM daily_usage WHERE github_id = 1').get() as { tokens: number; cost_usd: number }
    expect(row).toMatchObject({ tokens: 1000, cost_usd: 1.5 })
  })

  it('upsert is idempotent on (github_id, date, provider)', async () => {
    const { app, env, raw, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify({ ...validBody, tokens: 2000, cost_usd: 3 }) }, env)
    const rows = raw.prepare('SELECT COUNT(*) AS n FROM daily_usage').get() as { n: number }
    expect(rows.n).toBe(1)
    const row = raw.prepare('SELECT tokens FROM daily_usage').get() as { tokens: number }
    expect(row.tokens).toBe(2000)
  })

  it('rejects missing auth (401)', async () => {
    const { app, env } = setup()
    const res = await app.request('/api/v1/usage', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(validBody) }, env)
    expect(res.status).toBe(401)
  })

  it('rejects an invalid token (401)', async () => {
    const { app, env, authed } = setup()
    const res = await app.request('/api/v1/usage', { method: 'POST', headers: authed('nope'), body: JSON.stringify(validBody) }, env)
    expect(res.status).toBe(401)
  })

  it('rejects an over-shaped payload with extra keys (400)', async () => {
    const { app, env, authed } = setup()
    const res = await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify({ ...validBody, machine_id: 'abc', model: 'claude-opus' }) }, env)
    expect(res.status).toBe(400)
    expect((await res.json() as { error: string }).error).toContain('unexpected keys')
  })

  it('rejects an unknown provider (400)', async () => {
    const { app, env, authed } = setup()
    const res = await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify({ ...validBody, provider: 'gemini' }) }, env)
    expect(res.status).toBe(400)
  })
})

describe('GET /api/v1/leaderboard/:period', () => {
  it('ranks opted-in, non-hidden users by tokens (200)', async () => {
    const { app, env, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed('good'), body: JSON.stringify({ ...validBody, tokens: 500 }) }, env)
    await app.request('/api/v1/usage', { method: 'POST', headers: authed('good2'), body: JSON.stringify({ ...validBody, tokens: 900 }) }, env)
    const res = await app.request('/api/v1/leaderboard/weekly', {}, env)
    expect(res.status).toBe(200)
    const body = (await res.json()) as { entries: { github_login: string; tokens: number }[] }
    expect(body.entries.map((e) => e.github_login)).toEqual(['hubot', 'octocat'])
    expect(body.entries[0].tokens).toBe(900)
  })

  it('excludes hidden users', async () => {
    const { app, env, raw, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed('good'), body: JSON.stringify(validBody) }, env)
    raw.prepare('UPDATE users SET hidden = 1 WHERE github_id = 1').run()
    const res = await app.request('/api/v1/leaderboard/daily', {}, env)
    expect(((await res.json()) as { entries: unknown[] }).entries).toHaveLength(0)
  })

  it('rejects an invalid period (400)', async () => {
    const { app, env } = setup()
    expect((await app.request('/api/v1/leaderboard/yearly', {}, env)).status).toBe(400)
  })
})

describe('GET /api/v1/me', () => {
  it('returns the user + history (200)', async () => {
    const { app, env, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    const res = await app.request('/api/v1/me', { headers: authed() }, env)
    expect(res.status).toBe(200)
    const body = (await res.json()) as { github_login: string; history: unknown[] }
    expect(body.github_login).toBe('octocat')
    expect(body.history).toHaveLength(1)
  })

  it('rejects missing auth (401)', async () => {
    const { app, env } = setup()
    expect((await app.request('/api/v1/me', {}, env)).status).toBe(401)
  })
})

describe('DELETE /api/v1/me', () => {
  it('deletes the user and all their usage (204)', async () => {
    const { app, env, raw, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    const res = await app.request('/api/v1/me', { method: 'DELETE', headers: authed() }, env)
    expect(res.status).toBe(204)
    expect((raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number }).n).toBe(0)
    expect((raw.prepare('SELECT COUNT(*) AS n FROM daily_usage').get() as { n: number }).n).toBe(0)
  })

  it('rejects missing auth (401)', async () => {
    const { app, env } = setup()
    expect((await app.request('/api/v1/me', { method: 'DELETE' }, env)).status).toBe(401)
  })
})
