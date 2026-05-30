export interface Identity {
  githubId: number
  githubLogin: string
}

/**
 * Resolves a bearer token to a GitHub identity. Injectable so the API (3.1.3)
 * is testable without the real OAuth flow (Epic 3.2 wires the production
 * verifier in).
 */
export type AuthVerifier = (token: string) => Promise<Identity | null>

/** Production verifier: validate the token against the GitHub API. */
export const githubTokenVerifier: AuthVerifier = async (token) => {
  const res = await fetch('https://api.github.com/user', {
    headers: {
      Authorization: `Bearer ${token}`,
      'User-Agent': 'burnbar-api',
      Accept: 'application/vnd.github+json',
    },
  })
  if (!res.ok) return null
  const user = (await res.json()) as { id?: number; login?: string }
  if (typeof user.id !== 'number' || typeof user.login !== 'string') return null
  return { githubId: user.id, githubLogin: user.login }
}

/** Extract the bearer token from an `Authorization: Bearer <token>` header. */
export function bearerToken(header: string | undefined | null): string | null {
  if (!header) return null
  const match = /^Bearer\s+(.+)$/i.exec(header.trim())
  return match ? match[1] : null
}
