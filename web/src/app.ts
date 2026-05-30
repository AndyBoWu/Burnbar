import { type Context, Hono, type Next } from 'hono'
import { type AuthVerifier, bearerToken, githubTokenVerifier, type Identity } from './auth'
import { deleteMe, ensureUser, getMe, leaderboard, PERIODS, type Period, PROVIDERS, type Provider, upsertUsage } from './db'

export interface Env {
  DB: D1Database
}

export interface Deps {
  verifyToken: AuthVerifier
  now: () => Date
}

const USAGE_KEYS = ['date', 'provider', 'tokens', 'cost_usd'] as const

interface ValidUsage {
  date: string
  provider: Provider
  tokens: number
  cost_usd: number
}

/** Server-side privacy gate: accept ONLY the four leaderboard-safe keys. */
function validateUsage(body: unknown): { ok: true; value: ValidUsage } | { ok: false; error: string } {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    return { ok: false, error: 'body must be a JSON object' }
  }
  const keys = Object.keys(body as Record<string, unknown>)
  const extra = keys.filter((k) => !USAGE_KEYS.includes(k as (typeof USAGE_KEYS)[number]))
  if (extra.length > 0) return { ok: false, error: `unexpected keys: ${extra.join(', ')}` }
  const record = body as Record<string, unknown>
  for (const key of USAGE_KEYS) {
    if (!(key in record)) return { ok: false, error: `missing key: ${key}` }
  }
  if (typeof record.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(record.date)) {
    return { ok: false, error: 'date must be YYYY-MM-DD' }
  }
  if (typeof record.provider !== 'string' || !PROVIDERS.includes(record.provider as Provider)) {
    return { ok: false, error: 'provider must be claude or codex' }
  }
  if (typeof record.tokens !== 'number' || !Number.isInteger(record.tokens) || record.tokens < 0) {
    return { ok: false, error: 'tokens must be a non-negative integer' }
  }
  if (typeof record.cost_usd !== 'number' || !Number.isFinite(record.cost_usd) || record.cost_usd < 0) {
    return { ok: false, error: 'cost_usd must be a non-negative number' }
  }
  return {
    ok: true,
    value: {
      date: record.date,
      provider: record.provider as Provider,
      tokens: record.tokens,
      cost_usd: record.cost_usd,
    },
  }
}

export function createApp(deps: Deps): Hono<{ Bindings: Env; Variables: { identity: Identity } }> {
  const app = new Hono<{ Bindings: Env; Variables: { identity: Identity } }>()

  app.get('/', (c) => c.json({ ok: true, service: 'burnbar-api' }))

  // Auth gate for the three authenticated routes.
  type AppContext = Context<{ Bindings: Env; Variables: { identity: Identity } }>
  const requireAuth = async (c: AppContext, next: Next): Promise<Response | undefined> => {
    const token = bearerToken(c.req.header('Authorization'))
    if (!token) return c.json({ error: 'missing bearer token' }, 401)
    const identity = await deps.verifyToken(token)
    if (!identity) return c.json({ error: 'invalid token' }, 401)
    c.set('identity', identity)
    await next()
    return undefined
  }

  app.post('/api/v1/usage', requireAuth, async (c) => {
    let body: unknown
    try {
      body = await c.req.json()
    } catch {
      return c.json({ error: 'invalid JSON' }, 400)
    }
    const result = validateUsage(body)
    if (!result.ok) return c.json({ error: result.error }, 400)
    const identity = c.get('identity')
    await ensureUser(c.env.DB, identity.githubId, identity.githubLogin)
    await upsertUsage(c.env.DB, identity.githubId, result.value)
    return c.json({ ok: true }, 201)
  })

  app.get('/api/v1/leaderboard/:period', async (c) => {
    const period = c.req.param('period')
    if (!PERIODS.includes(period as Period)) {
      return c.json({ error: 'period must be daily, weekly, or monthly' }, 400)
    }
    const rows = await leaderboard(c.env.DB, period as Period, deps.now())
    return c.json({ period, entries: rows })
  })

  app.get('/api/v1/me', requireAuth, async (c) => {
    const identity = c.get('identity')
    const me = await getMe(c.env.DB, identity.githubId)
    if (!me) return c.json({ github_id: identity.githubId, github_login: identity.githubLogin, opted_in: false, hidden: false, history: [] })
    return c.json(me)
  })

  app.delete('/api/v1/me', requireAuth, async (c) => {
    const identity = c.get('identity')
    await deleteMe(c.env.DB, identity.githubId)
    return c.body(null, 204)
  })

  return app
}

/** Production app wired with the real GitHub verifier and the system clock. */
export const app = createApp({ verifyToken: githubTokenVerifier, now: () => new Date() })
