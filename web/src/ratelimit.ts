// Fixed-window rate limiting backed by Workers KV. A new window bucket starts
// every `windowSeconds`, so counters reset automatically (KV TTL cleans them up).

export interface KVLike {
  get(key: string): Promise<string | null>
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>
}

export interface RateLimitResult {
  allowed: boolean
  remaining: number
}

export async function checkRateLimit(
  kv: KVLike,
  id: string,
  limit: number,
  windowSeconds: number,
  nowMs: number,
): Promise<RateLimitResult> {
  const bucket = Math.floor(nowMs / 1000 / windowSeconds)
  const key = `rl:${id}:${bucket}`
  const current = Number((await kv.get(key)) ?? '0')
  if (current >= limit) return { allowed: false, remaining: 0 }
  await kv.put(key, String(current + 1), { expirationTtl: windowSeconds })
  return { allowed: true, remaining: limit - current - 1 }
}

export const RATE_LIMITS = {
  /** Authenticated requests, keyed by github_id. */
  perUserPerMinute: 10,
  /** Unauthenticated requests, keyed by client IP. */
  perIpPerMinute: 60,
  windowSeconds: 60,
} as const
