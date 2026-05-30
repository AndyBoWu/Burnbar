import { describe, expect, it } from 'vitest'
import worker from '../src/index'

// The production default export is an object ({ fetch, scheduled }); exercise the
// HTTP entry via worker.fetch.
const env = {} as unknown as Parameters<typeof worker.fetch>[1]
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext

describe('HSTS (3.6.3)', () => {
  it('GET / carries a Strict-Transport-Security header', async () => {
    const res = await worker.fetch(new Request('http://localhost/'), env, ctx)
    expect(res.headers.get('Strict-Transport-Security')).toBe('max-age=63072000; includeSubDomains; preload')
  })

  it('unknown route (404) still carries the HSTS header', async () => {
    const res = await worker.fetch(new Request('http://localhost/nope'), env, ctx)
    expect(res.status).toBe(404)
    expect(res.headers.get('Strict-Transport-Security')).toBe('max-age=63072000; includeSubDomains; preload')
  })
})
