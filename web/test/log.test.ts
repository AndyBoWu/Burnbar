import { afterEach, describe, expect, it, vi } from 'vitest'
import { createApp } from '../src/app'
import { logError, logEvent, logRequest } from '../src/log'

afterEach(() => vi.restoreAllMocks())

function captureLogs(): string[] {
  const lines: string[] = []
  vi.spyOn(console, 'log').mockImplementation((m: unknown) => {
    lines.push(String(m))
  })
  return lines
}

describe('structured logging', () => {
  it('logEvent emits one parseable JSON line with level/message/time', () => {
    const lines = captureLogs()
    logEvent('info', 'hello', { a: 1 })
    expect(lines).toHaveLength(1)
    const obj = JSON.parse(lines[0])
    expect(obj).toMatchObject({ level: 'info', message: 'hello', a: 1 })
    expect(typeof obj.time).toBe('string')
  })

  it('logRequest marks 5xx as error level (for the error-rate query)', () => {
    const lines = captureLogs()
    logRequest({ method: 'GET', path: '/x', status: 500, durationMs: 3 })
    expect(JSON.parse(lines[0]).level).toBe('error')
  })

  it('logError records the error message, never throws', () => {
    const lines = captureLogs()
    logError(new Error('boom'), { path: '/x' })
    expect(JSON.parse(lines[0])).toMatchObject({ level: 'error', message: 'unhandled_error', error: 'boom' })
  })
})

describe('app error boundary + request logging', () => {
  it('logs a request line for a normal response', async () => {
    const lines = captureLogs()
    const app = createApp({ verifyToken: async () => null, now: () => new Date() })
    await app.request('/', {}, { DB: {} as unknown as D1Database })
    expect(lines.some((l) => JSON.parse(l).message === 'request')).toBe(true)
  })

  it('returns a non-leaky 500 and logs unhandled_error when a handler throws', async () => {
    const lines = captureLogs()
    const app = createApp({ verifyToken: async () => ({ githubId: 1, githubLogin: 'octocat' }), now: () => new Date() })
    const brokenDB = {
      prepare() {
        throw new Error('db down')
      },
    } as unknown as D1Database
    const res = await app.request('/api/v1/me', { headers: { Authorization: 'Bearer good' } }, { DB: brokenDB })
    expect(res.status).toBe(500)
    expect((await res.json()) as { error: string }).toEqual({ error: 'internal error' })
    expect(lines.some((l) => JSON.parse(l).message === 'unhandled_error')).toBe(true)
  })
})
