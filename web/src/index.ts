import { Hono } from 'hono'

export interface Env {
  DB: D1Database
}

const app = new Hono<{ Bindings: Env }>()

// Health check — the staging/prod deploy DoD (3.1.1) verifies this returns 200.
app.get('/', (c) => c.json({ ok: true, service: 'burnbar-api' }))

export default app
