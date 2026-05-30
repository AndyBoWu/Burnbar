// Production Worker entry: the app wired with the real GitHub verifier.
// Routes + handlers live in src/app.ts (createApp is injected with fakes in tests).
import { app, type Env } from './app'
import { purgeOptedOut } from './db'
import { logError, logEvent } from './log'

export type { Env } from './app'

/**
 * Daily data-retention cron (3.5.3). Purges `daily_usage` rows older than 90
 * days for opted-OUT users; opted-in users retain data indefinitely. The purge
 * count is logged so "how many rows purged today" is queryable in Workers Logs.
 * Scheduled by the `[triggers] crons` entry in wrangler.toml.
 */
export async function scheduled(event: ScheduledController, env: Env, _ctx: ExecutionContext): Promise<void> {
  try {
    const deleted = await purgeOptedOut(env.DB, new Date(event.scheduledTime))
    logEvent('info', 'retention_purge', { cron: event.cron, deleted })
  } catch (err) {
    logError(err, { cron: event.cron, job: 'retention_purge' })
  }
}

export default {
  fetch: app.fetch,
  scheduled,
}
