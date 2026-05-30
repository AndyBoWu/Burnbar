import { describe, expect, it } from 'vitest'
import worker from '../src/index'

// The production default export is now an object ({ fetch, scheduled }) so the
// Worker can serve HTTP and run the retention cron (3.5.3). Exercise the HTTP
// entry via worker.fetch.
const env = {} as unknown as Parameters<typeof worker.fetch>[1]
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext

describe('health check', () => {
  it('GET / returns 200 with an ok payload', async () => {
    const res = await worker.fetch(new Request('http://localhost/'), env, ctx)
    expect(res.status).toBe(200)
    expect(await res.json()).toMatchObject({ ok: true, service: 'burnbar-api' })
  })

  it('unknown route returns 404', async () => {
    const res = await worker.fetch(new Request('http://localhost/nope'), env, ctx)
    expect(res.status).toBe(404)
  })
})
