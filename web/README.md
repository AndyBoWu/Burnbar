# Burnbar API (Cloudflare Workers + D1)

The leaderboard backend for Burnbar's M3 social layer. Stores **only**
leaderboard-safe aggregates: `{date, provider, tokens, cost_usd}` per
`(github_id, date, provider)`. Never user content, paths, machine ids, or raw
model names (see the migrations and CLAUDE.md constraint 4).

## Develop & test locally (no Cloudflare account needed)

```bash
cd web
npm install
npm test            # vitest — routing + (later) D1 integration, all offline
npm run typecheck
npm run migrate:local   # apply migrations to a local SQLite D1
npm run dev             # wrangler dev — local Worker at http://localhost:8787
```

## Deploy (needs a Cloudflare account)

These steps require `wrangler login` and a Cloudflare account — they are the
operator's responsibility and are **not** runnable from CI/local without auth:

```bash
# One-time: create the databases and paste the returned database_id into wrangler.toml
wrangler d1 create burnbar-staging
wrangler d1 create burnbar-prod

# Apply schema + deploy
npm run migrate:staging
npm run deploy:staging      # wrangler deploy --env staging  → staging URL

npm run migrate:prod
npm run deploy:prod
```

Secrets (e.g. the GitHub App `client_secret` for Epic 3.2) are set via
`wrangler secret put <NAME> --env <env>` and are **never** committed.

## TLS / HTTPS (3.6.3)

The leaderboard is HTTPS-only. Responsibilities split between the operator's
Cloudflare zone settings and this Worker:

- **Operator (Cloudflare zone settings, one-time):**
  - Enable **Universal SSL** for the Pages custom domain so a certificate is
    issued and validated for `burnbar.andybowu.xyz`.
  - Enable **Always Use HTTPS** on the `andybowu.xyz` zone (or a scoped redirect
    rule) so `http://` requests return a `301` to `https://`.
  - Set the **SSL/TLS mode to Full (strict)** for end-to-end TLS.
  - Record the SSL Labs grade (target ≥ A) here once the domain is live.
- **This Worker:** sets `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`
  on **every** response (see the `app.use('*', ...)` middleware in
  [`src/app.ts`](src/app.ts)). This tells browsers to never speak plain HTTP to
  the domain again. The Worker does not perform the redirect itself — that is the
  operator's "Always Use HTTPS" zone setting above.

## Endpoints

Documented in this README as Epic 3.1.3 (#49) lands them: `POST /api/v1/usage`,
`GET /api/v1/leaderboard/:period`, `GET /api/v1/me`, `DELETE /api/v1/me`.
