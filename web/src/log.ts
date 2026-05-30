// Structured JSON logging. Each line is one event; Cloudflare Workers Logs /
// Logpush ingest these, and the dashboard's error-rate / "last 24h errors"
// queries filter on `level` and `message` (see wrangler.toml [observability]).

export type LogFields = Record<string, unknown>

export function logEvent(level: 'info' | 'error', message: string, fields: LogFields = {}): void {
  console.log(JSON.stringify({ level, message, time: new Date().toISOString(), ...fields }))
}

export function logRequest(fields: { method: string; path: string; status: number; durationMs: number }): void {
  logEvent(fields.status >= 500 ? 'error' : 'info', 'request', fields)
}

export function logError(err: unknown, fields: LogFields = {}): void {
  logEvent('error', 'unhandled_error', {
    ...fields,
    error: err instanceof Error ? err.message : String(err),
  })
}
