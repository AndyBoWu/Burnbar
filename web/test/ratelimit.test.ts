import { describe, expect, it } from 'vitest'
import { createApp } from '../src/app'
import { checkRateLimit, type KVLike, RATE_LIMITS } from '../src/ratelimit'
import { migratedTestDB } from './helpers/testDB'

/** In-memory KV with TTL ignored (fine for window-bucket tests). */
function fakeKV(): KVLike {
  const store = new Map<string, string>()
  return {
    get: async (k) => store.get(k) ?? null,
    put: async (k, v) => {
      store.set(k, v)
    },
  }
}

describe('checkRateLimit', () => {
  it('allows up to the limit then blocks, and resets in the next window', async () => {
    const kv = fakeKV()
    const t0 = 1_000_000_000_000
    for (let i = 0; i < 3; i++) {
      expect((await checkRateLimit(kv, 'x', 3, 60, t0)).allowed).toBe(true)
    }
    expect((await checkRateLimit(kv, 'x', 3, 60, t0)).allowed).toBe(false)
    // 60s later → new bucket → allowed again.
    expect((await checkRateLimit(kv, 'x', 3, 60, t0 + 60_000)).allowed).toBe(true)
  })
})

describe('API rate limiting', () => {
  const now = new Date('2026-05-30T12:00:00Z')
  function setup() {
    const { db } = migratedTestDB()
    const app = createApp({ verifyToken: async (t) => (t === 'good' ? { githubId: 1, githubLogin: 'octocat' } : null), now: () => now })
    const env = { DB: db as unknown as D1Database, RATE_LIMIT: fakeKV() as unknown as KVNamespace }
    return { app, env }
  }

  it('returns 429 once the authenticated per-user limit is exceeded', async () => {
    const { app, env } = setup()
    const headers = { Authorization: 'Bearer good' }
    let last = 200
    for (let i = 0; i < RATE_LIMITS.perUserPerMinute + 2; i++) {
      last = (await app.request('/api/v1/me', { headers }, env)).status
    }
    expect(last).toBe(429)
  })

  it('returns 429 once the public per-IP leaderboard limit is exceeded', async () => {
    const { app, env } = setup()
    const headers = { 'CF-Connecting-IP': '203.0.113.7' }
    let last = 200
    for (let i = 0; i < RATE_LIMITS.perIpPerMinute + 2; i++) {
      last = (await app.request('/api/v1/leaderboard/daily', { headers }, env)).status
    }
    expect(last).toBe(429)
  })

  it('fails open (no 429) when no KV is bound', async () => {
    const { db } = migratedTestDB()
    const app = createApp({ verifyToken: async () => ({ githubId: 1, githubLogin: 'octocat' }), now: () => now })
    const env = { DB: db as unknown as D1Database }
    let last = 200
    for (let i = 0; i < RATE_LIMITS.perUserPerMinute + 5; i++) {
      last = (await app.request('/api/v1/me', { headers: { Authorization: 'Bearer good' } }, env)).status
    }
    expect(last).toBe(200)
  })
})
