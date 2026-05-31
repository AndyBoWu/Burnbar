// Typed client for the public Burnbar leaderboard API (Cloudflare Worker, Epic 3.1).
// Reads ONLY leaderboard-safe public fields: rank/login/tokens/cost. Never
// touches per-machine, per-project, cwd, or raw-model data (none is exposed by
// the API anyway — this client mirrors the public contract).

/**
 * Canonical readiness copy for the not-yet-live public leaderboard. This is the
 * SINGLE source of truth for the "rolling out soon" wording so every surface —
 * the landing page, the privacy page, the leaderboard, and profile pages — reads
 * identically (issue #174). When the backend goes live (operator sets
 * `NEXT_PUBLIC_API_URL`, issue #173), the not-configured branches stop rendering
 * automatically; to flip the messaging everywhere, edit this one string.
 */
export const LEADERBOARD_ROLLING_OUT =
  "The public leaderboard is rolling out soon." as const;

/** Short badge/label form of {@link LEADERBOARD_ROLLING_OUT} for CTAs. */
export const LEADERBOARD_ROLLING_OUT_SHORT = "Coming soon" as const;

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
 * Placeholder origin used when no API is configured. Kept ONLY as the sentinel
 * the build falls back to so pages can detect the "not deployed yet" state and
 * render the intentional "coming soon" message instead of trying (and failing)
 * to reach a non-existent host. The operator replaces it by setting
 * `NEXT_PUBLIC_API_URL` to the deployed Worker origin (see
 * docs/M3-CLOUDFLARE-DEPLOY-CHECKLIST.md).
 */
export const PLACEHOLDER_API_BASE = "https://api.burnbar.example";

/**
 * Base URL of the public API. Configured via `NEXT_PUBLIC_API_URL`; falls back
 * to a documented placeholder so builds succeed without the deployed Worker.
 * When it equals the placeholder (or is empty), the API is treated as
 * unconfigured and the leaderboard renders the "coming soon" state.
 */
export const API_BASE: string =
  process.env.NEXT_PUBLIC_API_URL?.trim() || PLACEHOLDER_API_BASE;

/**
 * Sentinel returned by the fetchers when no real API origin is configured yet
 * (i.e. `API_BASE` is still the placeholder). Callers render the intentional
 * "leaderboard coming soon" state — NOT the generic transient-error state.
 */
export const NOT_CONFIGURED = "not-configured" as const;
export type NotConfigured = typeof NOT_CONFIGURED;

/**
 * Whether a real API origin has been configured. `false` while `API_BASE` is
 * still the documented placeholder (the pre-deploy default). Used to decide
 * between the "coming soon" state and a real error state.
 */
export function isApiConfigured(): boolean {
  return API_BASE !== PLACEHOLDER_API_BASE;
}

/** The API caps results at 100; we never render more than this. */
export const MAX_ROWS = 100;

/**
 * Fetch the top-100 leaderboard for a period. Returns:
 *   - the parsed entries on success (possibly empty → "no entries yet"),
 *   - `"not-configured"` when no real API origin is set yet (pre-deploy →
 *     "coming soon"), so callers never hit the doomed placeholder host,
 *   - `null` on any network/HTTP/shape error from a CONFIGURED API (→ the
 *     transient "try again later" error state).
 *
 * Revalidates every 5 minutes (ISR) per the ticket's refresh requirement.
 */
export async function fetchLeaderboard(
  period: Period,
): Promise<LeaderboardEntry[] | NotConfigured | null> {
  if (!isApiConfigured()) return NOT_CONFIGURED;
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

/** One day in a user's public burn series (`{date, tokens, cost_usd}` only). */
export interface ProfilePoint {
  date: string;
  tokens: number;
  cost_usd: number;
}

/** Shape of `GET /api/v1/u/:login` — public identity + 90-day burn series. */
export interface PublicProfile {
  github_login: string;
  history: ProfilePoint[];
}

/** Days of history the public profile endpoint exposes. */
export const PROFILE_HISTORY_DAYS = 90;

/**
 * Fetch a user's public profile (`GET /api/v1/u/:login`). The Worker returns
 * the 90-day series ONLY for opted-in, non-hidden users; hidden, opted-out, and
 * unknown logins all 404. Returns:
 *   - the parsed profile on 200,
 *   - `"not-found"` on 404 (hidden / opted-out / unknown → caller renders 404),
 *   - `"not-configured"` when no real API origin is set yet (pre-deploy →
 *     "coming soon"), so we never hit the doomed placeholder host,
 *   - `null` on any network/other-HTTP/shape error (caller renders an error).
 *
 * No history is fetched or embedded when the user is excluded — the 404 is
 * decided server-side before any series is returned.
 */
export async function getProfile(
  login: string,
): Promise<PublicProfile | "not-found" | NotConfigured | null> {
  if (!isApiConfigured()) return NOT_CONFIGURED;
  const url = `${API_BASE}/api/v1/u/${encodeURIComponent(login)}`;
  try {
    const res = await fetch(url, {
      headers: { accept: "application/json" },
      next: { revalidate: 300 },
    });
    if (res.status === 404) return "not-found";
    if (!res.ok) return null;
    const data: unknown = await res.json();
    return parseProfile(data);
  } catch {
    return null;
  }
}

/** Validate the profile payload defensively; return `null` on any mismatch. */
function parseProfile(data: unknown): PublicProfile | null {
  if (typeof data !== "object" || data === null) return null;
  const { github_login, history } = data as Record<string, unknown>;
  if (typeof github_login !== "string" || !Array.isArray(history)) return null;
  const points: ProfilePoint[] = [];
  for (const item of history) {
    if (typeof item !== "object" || item === null) return null;
    const { date, tokens, cost_usd } = item as Record<string, unknown>;
    if (
      typeof date !== "string" ||
      typeof tokens !== "number" ||
      typeof cost_usd !== "number"
    ) {
      return null;
    }
    points.push({ date, tokens, cost_usd });
  }
  return { github_login, history: points };
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
