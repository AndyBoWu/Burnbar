import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import Database from 'better-sqlite3'

const migrationsDir = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'migrations')

/**
 * A minimal D1Database-compatible adapter over better-sqlite3, so the Worker's
 * real SQL/handler code runs offline in vitest with no Cloudflare account.
 * Implements the subset of the D1 prepared-statement API the API uses.
 */
export interface D1Like {
  prepare(sql: string): {
    bind(...values: unknown[]): {
      first<T = Record<string, unknown>>(colName?: string): Promise<T | null>
      all<T = Record<string, unknown>>(): Promise<{ results: T[]; success: true }>
      run(): Promise<{ success: true; meta: { changes: number } }>
    }
  }
}

export function migratedTestDB(): { db: D1Like; raw: Database.Database } {
  const raw = new Database(':memory:')
  raw.pragma('foreign_keys = ON')
  for (const file of ['0001_create_users.sql', '0002_create_daily_usage.sql']) {
    raw.exec(readFileSync(join(migrationsDir, file), 'utf8'))
  }

  const db: D1Like = {
    prepare(sql: string) {
      const stmt = raw.prepare(sql)
      let bound: unknown[] = []
      const api = {
        bind(...values: unknown[]) {
          bound = values
          return api
        },
        async first<T>(colName?: string): Promise<T | null> {
          const row = stmt.get(...bound) as Record<string, unknown> | undefined
          if (!row) return null
          return (colName ? (row[colName] as T) : (row as T)) ?? null
        },
        async all<T>() {
          return { results: stmt.all(...bound) as T[], success: true as const }
        },
        async run() {
          const info = stmt.run(...bound)
          return { success: true as const, meta: { changes: info.changes } }
        },
      }
      return api
    },
  }
  return { db, raw }
}
