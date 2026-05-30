# Security Policy

## Reporting a vulnerability

If you discover a security issue in Burnbar, please report it privately:

- Use GitHub's [private vulnerability reporting](https://github.com/AndyBoWu/Burnbar/security/advisories/new) (Security → Report a vulnerability), or
- Email the maintainer at the address on the [GitHub profile](https://github.com/AndyBoWu).

Please do **not** open a public issue for security problems. We aim to respond
within a few days.

## Scope

Burnbar's privacy posture is core to the project. Reports we especially want:

- Anything that causes Burnbar to read data **outside** `~/.claude` / `~/.codex`
  (e.g. browser data, third-party Keychain items).
- Anything that causes the leaderboard upload to include data beyond the
  allowlisted `{date, provider, tokens, cost_usd}` (e.g. paths, prompts, machine
  ids, raw model names).
- Secret/credential exposure in the repo, releases, or the leaderboard backend.

## Secret handling

- The committed GitHub App `client_id` is public by design; the `client_secret`
  is never committed (it lives only in the Cloudflare Worker env).
- Secrets are kept out of the repo by `.gitignore` and a gitleaks pre-commit
  hook (`make scan-secrets` audits full history on demand). Once the repo is
  public, GitHub Push Protection blocks secret pushes server-side.
