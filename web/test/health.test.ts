import { describe, expect, it } from 'vitest'
import app from '../src/index'

describe('health check', () => {
  it('GET / returns 200 with an ok payload', async () => {
    const res = await app.request('/')
    expect(res.status).toBe(200)
    expect(await res.json()).toMatchObject({ ok: true, service: 'burnbar-api' })
  })

  it('unknown route returns 404', async () => {
    const res = await app.request('/nope')
    expect(res.status).toBe(404)
  })
})
