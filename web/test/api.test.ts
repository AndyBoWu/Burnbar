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

describe('GET /api/v1/u/:login', () => {
  it('returns the public profile + 90-day history for an opted-in, non-hidden user (200)', async () => {
    const { app, env, authed } = setup()
    // Two daily rows across both providers on the same day -> summed per date.
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify({ ...validBody, tokens: 1000, cost_usd: 1.5 }) }, env)
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify({ ...validBody, provider: 'codex', tokens: 500, cost_usd: 0.5 }) }, env)
    const res = await app.request('/api/v1/u/octocat', {}, env)
    expect(res.status).toBe(200)
    const body = (await res.json()) as { github_login: string; history: { date: string; tokens: number; cost_usd: number }[] }
    expect(body.github_login).toBe('octocat')
    expect(body.history).toHaveLength(1)
    expect(body.history[0]).toEqual({ date: '2026-05-30', tokens: 1500, cost_usd: 2 })
  })

  it('matches the login case-insensitively (200)', async () => {
    const { app, env, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    const res = await app.request('/api/v1/u/OCTOCAT', {}, env)
    expect(res.status).toBe(200)
    expect(((await res.json()) as { github_login: string }).github_login).toBe('octocat')
  })

  it('never exposes provider, machine, project, or model fields (privacy)', async () => {
    const { app, env, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    const body = (await (await app.request('/api/v1/u/octocat', {}, env)).json()) as Record<string, unknown>
    expect(Object.keys(body).sort()).toEqual(['github_login', 'history'])
    const point = (body.history as Record<string, unknown>[])[0]
    expect(Object.keys(point).sort()).toEqual(['cost_usd', 'date', 'tokens'])
  })

  it('returns 404 for a hidden user with no history leaked (DoD)', async () => {
    const { app, env, raw, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    raw.prepare('UPDATE users SET hidden = 1 WHERE github_id = 1').run()
    const res = await app.request('/api/v1/u/octocat', {}, env)
    expect(res.status).toBe(404)
    const body = (await res.json()) as Record<string, unknown>
    expect(body).not.toHaveProperty('history')
    expect(body).not.toHaveProperty('github_login')
  })

  it('returns 404 for an opted-out user with no history leaked (DoD)', async () => {
    const { app, env, raw, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    raw.prepare('UPDATE users SET opted_in = 0 WHERE github_id = 1').run()
    const res = await app.request('/api/v1/u/octocat', {}, env)
    expect(res.status).toBe(404)
    expect((await res.json()) as Record<string, unknown>).not.toHaveProperty('history')
  })

  it('returns 404 for an unknown login', async () => {
    const { app, env } = setup()
    const res = await app.request('/api/v1/u/ghost', {}, env)
    expect(res.status).toBe(404)
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

describe('PATCH /api/v1/me', () => {
  it('hiding via PATCH removes the user from the leaderboard (DoD)', async () => {
    const { app, env, raw, authed } = setup()
    // Two opted-in users both rank initially.
    await app.request('/api/v1/usage', { method: 'POST', headers: authed('good'), body: JSON.stringify({ ...validBody, tokens: 500 }) }, env)
    await app.request('/api/v1/usage', { method: 'POST', headers: authed('good2'), body: JSON.stringify({ ...validBody, tokens: 900 }) }, env)
    const before = (await (await app.request('/api/v1/leaderboard/daily', {}, env)).json()) as { entries: { github_login: string }[] }
    expect(before.entries.map((e) => e.github_login)).toEqual(['hubot', 'octocat'])

    const patch = await app.request('/api/v1/me', { method: 'PATCH', headers: authed('good'), body: JSON.stringify({ hidden: true }) }, env)
    expect(patch.status).toBe(200)
    expect(((await patch.json()) as { hidden: boolean }).hidden).toBe(true)
    expect((raw.prepare('SELECT hidden FROM users WHERE github_id = 1').get() as { hidden: number }).hidden).toBe(1)

    const after = (await (await app.request('/api/v1/leaderboard/daily', {}, env)).json()) as { entries: { github_login: string }[] }
    expect(after.entries.map((e) => e.github_login)).toEqual(['hubot'])
  })

  it('unhiding via PATCH restores the user to the leaderboard', async () => {
    const { app, env, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed('good'), body: JSON.stringify(validBody) }, env)
    await app.request('/api/v1/me', { method: 'PATCH', headers: authed('good'), body: JSON.stringify({ hidden: true }) }, env)
    expect((((await (await app.request('/api/v1/leaderboard/daily', {}, env)).json()) as { entries: unknown[] }).entries)).toHaveLength(0)
    await app.request('/api/v1/me', { method: 'PATCH', headers: authed('good'), body: JSON.stringify({ hidden: false }) }, env)
    const entries = ((await (await app.request('/api/v1/leaderboard/daily', {}, env)).json()) as { entries: { github_login: string }[] }).entries
    expect(entries.map((e) => e.github_login)).toEqual(['octocat'])
  })

  it('still returns the hidden user full history via GET /api/v1/me', async () => {
    const { app, env, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    await app.request('/api/v1/me', { method: 'PATCH', headers: authed(), body: JSON.stringify({ hidden: true }) }, env)
    const body = (await (await app.request('/api/v1/me', { headers: authed() }, env)).json()) as { hidden: boolean; history: unknown[] }
    expect(body.hidden).toBe(true)
    expect(body.history).toHaveLength(1)
  })

  it('updates opted_in independently of hidden', async () => {
    const { app, env, raw, authed } = setup()
    await app.request('/api/v1/usage', { method: 'POST', headers: authed(), body: JSON.stringify(validBody) }, env)
    const res = await app.request('/api/v1/me', { method: 'PATCH', headers: authed(), body: JSON.stringify({ opted_in: false }) }, env)
    expect(res.status).toBe(200)
    const row = raw.prepare('SELECT opted_in, hidden FROM users WHERE github_id = 1').get() as { opted_in: number; hidden: number }
    expect(row).toMatchObject({ opted_in: 0, hidden: 0 })
  })

  it('can set flags before any upload (creates the user row)', async () => {
    const { app, env, raw, authed } = setup()
    const res = await app.request('/api/v1/me', { method: 'PATCH', headers: authed(), body: JSON.stringify({ hidden: true }) }, env)
    expect(res.status).toBe(200)
    const row = raw.prepare('SELECT hidden FROM users WHERE github_id = 1').get() as { hidden: number }
    expect(row.hidden).toBe(1)
  })

  it('rejects extra keys not in the allowlist (400)', async () => {
    const { app, env, authed } = setup()
    const res = await app.request('/api/v1/me', { method: 'PATCH', headers: authed(), body: JSON.stringify({ hidden: true, github_id: 999 }) }, env)
    expect(res.status).toBe(400)
    expect(((await res.json()) as { error: string }).error).toContain('unexpected keys')
  })

  it('rejects a non-boolean flag value (400)', async () => {
    const { app, env, authed } = setup()
    const res = await app.request('/api/v1/me', { method: 'PATCH', headers: authed(), body: JSON.stringify({ hidden: 'yes' }) }, env)
    expect(res.status).toBe(400)
  })

  it('rejects an empty body with no flags (400)', async () => {
    const { app, env, authed } = setup()
    const res = await app.request('/api/v1/me', { method: 'PATCH', headers: authed(), body: JSON.stringify({}) }, env)
    expect(res.status).toBe(400)
  })

  it('rejects invalid JSON (400)', async () => {
    const { app, env, authed } = setup()
    const res = await app.request('/api/v1/me', { method: 'PATCH', headers: authed(), body: 'not json' }, env)
    expect(res.status).toBe(400)
  })

  it('rejects missing auth (401)', async () => {
    const { app, env } = setup()
    const res = await app.request('/api/v1/me', { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ hidden: true }) }, env)
    expect(res.status).toBe(401)
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
