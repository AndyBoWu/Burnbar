// Typed client for the public Burnbar leaderboard API (Cloudflare Worker, Epic 3.1).
// Reads ONLY leaderboard-safe public fields: rank/login/tokens/cost. Never
// touches per-machine, per-project, cwd, or raw-model data (none is exposed by
// the API anyway — this client mirrors the public contract).

/** Period segments accepted by `GET /api/v1/leaderboard/:period`. */
export const PERIODS = ["daily", "weekly", "monthly"] as const;
export type Period = (typeof PERIODS)[number];

/** Type guard: narrow an arbitrary string to a valid `Period`. */
export function isPeriod(value: string): value is Period {
  return (PERIODS as readonly string[]).includes(value);
}

/** Human-readable label for a period segment. */
export const PERIOD_LABELS: Record<Period, string> = {
  daily: "Today",
  weekly: "This week",
  monthly: "This month",
};

/** A single ranked entry as returned by the public leaderboard endpoint. */
export interface LeaderboardEntry {
  github_login: string;
  tokens: number;
  cost_usd: number;
}

/** Shape of `GET /api/v1/leaderboard/:period`. */
export interface LeaderboardResponse {
  period: Period;
  entries: LeaderboardEntry[];
}

/**
 * Base URL of the public API. Configured via `NEXT_PUBLIC_API_URL`; falls back
 * to a documented placeholder so builds succeed without the deployed Worker.
 */
export const API_BASE: string =
  process.env.NEXT_PUBLIC_API_URL ?? "https://api.burnbar.example";

/** The API caps results at 100; we never render more than this. */
export const MAX_ROWS = 100;

/**
 * Fetch the top-100 leaderboard for a period. Returns the parsed entries on
 * success, or `null` on any network/HTTP/shape error so callers can render an
 * error state instead of throwing during render.
 *
 * Revalidates every 5 minutes (ISR) per the ticket's refresh requirement.
 */
export async function fetchLeaderboard(
  period: Period,
): Promise<LeaderboardEntry[] | null> {
  const url = `${API_BASE}/api/v1/leaderboard/${period}`;
  try {
    const res = await fetch(url, {
      headers: { accept: "application/json" },
      next: { revalidate: 300 },
    });
    if (!res.ok) return null;
    const data: unknown = await res.json();
    const entries = parseEntries(data);
    if (entries === null) return null;
    return entries.slice(0, MAX_ROWS);
  } catch {
    return null;
  }
}

/** Validate the API payload defensively; return `null` on any mismatch. */
function parseEntries(data: unknown): LeaderboardEntry[] | null {
  if (typeof data !== "object" || data === null) return null;
  const raw = (data as { entries?: unknown }).entries;
  if (!Array.isArray(raw)) return null;
  const entries: LeaderboardEntry[] = [];
  for (const item of raw) {
    if (typeof item !== "object" || item === null) return null;
    const { github_login, tokens, cost_usd } = item as Record<string, unknown>;
    if (
      typeof github_login !== "string" ||
      typeof tokens !== "number" ||
      typeof cost_usd !== "number"
    ) {
      return null;
    }
    entries.push({ github_login, tokens, cost_usd });
  }
  return entries;
}
