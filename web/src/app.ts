import { type Context, Hono, type Next } from 'hono'
import { type AuthVerifier, bearerToken, githubTokenVerifier, type Identity } from './auth'
import { deleteMe, ensureUser, getMe, leaderboard, PERIODS, type Period, PROVIDERS, type Provider, publicProfile, updateUserFlags, type UserFlags, upsertUsage } from './db'
import { logError, logRequest } from './log'
import { checkRateLimit, RATE_LIMITS } from './ratelimit'

export interface Env {
  DB: D1Database
  /** Optional KV for rate limiting. Absent → limiter fails open (allows). */
  RATE_LIMIT?: KVNamespace
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

const FLAG_KEYS = ['hidden', 'opted_in'] as const

/** Validate a PATCH /api/v1/me body: allowlist {hidden, opted_in}, booleans, at least one. */
function validateUserFlags(body: unknown): { ok: true; value: UserFlags } | { ok: false; error: string } {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    return { ok: false, error: 'body must be a JSON object' }
  }
  const record = body as Record<string, unknown>
  const extra = Object.keys(record).filter((k) => !FLAG_KEYS.includes(k as (typeof FLAG_KEYS)[number]))
  if (extra.length > 0) return { ok: false, error: `unexpected keys: ${extra.join(', ')}` }
  for (const key of FLAG_KEYS) {
    if (key in record && typeof record[key] !== 'boolean') {
      return { ok: false, error: `${key} must be a boolean` }
    }
  }
  if (!('hidden' in record) && !('opted_in' in record)) {
    return { ok: false, error: 'body must include at least one of: hidden, opted_in' }
  }
  const value: UserFlags = {}
  if ('hidden' in record) value.hidden = record.hidden as boolean
  if ('opted_in' in record) value.opted_in = record.opted_in as boolean
  return { ok: true, value }
}

export function createApp(deps: Deps): Hono<{ Bindings: Env; Variables: { identity: Identity } }> {
  const app = new Hono<{ Bindings: Env; Variables: { identity: Identity } }>()

  // Structured request log for every response (feeds Workers Logs / the dashboard).
  app.use('*', async (c, next) => {
    const start = Date.now()
    await next()
    logRequest({ method: c.req.method, path: new URL(c.req.url).pathname, status: c.res.status, durationMs: Date.now() - start })
  })

  // Error boundary: log + a non-leaky 500 (never echo internals/stack to clients).
  app.onError((err, c) => {
    logError(err, { path: new URL(c.req.url).pathname })
    return c.json({ error: 'internal error' }, 500)
  })

  app.get('/', (c) => c.json({ ok: true, service: 'burnbar-api' }))

  // Auth gate for the three authenticated routes.
  type AppContext = Context<{ Bindings: Env; Variables: { identity: Identity } }>
  const requireAuth = async (c: AppContext, next: Next): Promise<Response | undefined> => {
    const token = bearerToken(c.req.header('Authorization'))
    if (!token) return c.json({ error: 'missing bearer token' }, 401)
    const identity = await deps.verifyToken(token)
    if (!identity) return c.json({ error: 'invalid token' }, 401)
    if (c.env.RATE_LIMIT) {
      const rl = await checkRateLimit(c.env.RATE_LIMIT, `user:${identity.githubId}`, RATE_LIMITS.perUserPerMinute, RATE_LIMITS.windowSeconds, deps.now().getTime())
      if (!rl.allowed) return c.json({ error: 'rate limit exceeded' }, 429)
    }
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
    if (c.env.RATE_LIMIT) {
      const ip = c.req.header('CF-Connecting-IP') ?? 'unknown'
      const rl = await checkRateLimit(c.env.RATE_LIMIT, `ip:${ip}`, RATE_LIMITS.perIpPerMinute, RATE_LIMITS.windowSeconds, deps.now().getTime())
      if (!rl.allowed) return c.json({ error: 'rate limit exceeded' }, 429)
    }
    const period = c.req.param('period')
    if (!PERIODS.includes(period as Period)) {
      return c.json({ error: 'period must be daily, weekly, or monthly' }, 400)
    }
    const rows = await leaderboard(c.env.DB, period as Period, deps.now())
    return c.json({ period, entries: rows })
  })

  // Public per-user profile (3.4.4). No auth; IP rate-limited like the
  // leaderboard. Returns the last-90-days burn series ONLY for opted-in,
  // non-hidden users — hidden/opted-out/unknown all 404 with no history leak.
  app.get('/api/v1/u/:login', async (c) => {
    if (c.env.RATE_LIMIT) {
      const ip = c.req.header('CF-Connecting-IP') ?? 'unknown'
      const rl = await checkRateLimit(c.env.RATE_LIMIT, `ip:${ip}`, RATE_LIMITS.perIpPerMinute, RATE_LIMITS.windowSeconds, deps.now().getTime())
      if (!rl.allowed) return c.json({ error: 'rate limit exceeded' }, 429)
    }
    const login = c.req.param('login')
    const profile = await publicProfile(c.env.DB, login, deps.now())
    if (!profile) return c.json({ error: 'not found' }, 404)
    return c.json(profile)
  })

  app.get('/api/v1/me', requireAuth, async (c) => {
    const identity = c.get('identity')
    const me = await getMe(c.env.DB, identity.githubId)
    if (!me) return c.json({ github_id: identity.githubId, github_login: identity.githubLogin, opted_in: false, hidden: false, history: [] })
    return c.json(me)
  })

  app.patch('/api/v1/me', requireAuth, async (c) => {
    let body: unknown
    try {
      body = await c.req.json()
    } catch {
      return c.json({ error: 'invalid JSON' }, 400)
    }
    const result = validateUserFlags(body)
    if (!result.ok) return c.json({ error: result.error }, 400)
    const identity = c.get('identity')
    // Ensure the user row exists so flags can be set before the first upload.
    await ensureUser(c.env.DB, identity.githubId, identity.githubLogin)
    await updateUserFlags(c.env.DB, identity.githubId, result.value)
    const me = await getMe(c.env.DB, identity.githubId)
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
