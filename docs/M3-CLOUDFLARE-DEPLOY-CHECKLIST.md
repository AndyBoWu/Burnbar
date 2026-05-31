# M3 Cloudflare deploy checklist (#71 / #90, and #82/#84 prerequisites)

A single ordered runbook to take the leaderboard from "code-complete locally" to
"live at `https://burnbar.andybowu.xyz`". Every step here is **operator-only**
(needs your Cloudflare account / `wrangler login`) — none of it runs from CI.

Detail lives in [`web/README.md`](../web/README.md) and
[`M3-OPERATOR-SETUP.md`](M3-OPERATOR-SETUP.md); this file is the **order** to do
them in and the exact placeholders to fill.

Closes when done: **#71** (DNS CNAME) → auto-unblocks **#90** (Domain epic). The
API/Pages deploy here is also what makes the leaderboard sign-in (shipped in the
app) actually function.

---

## 0. Prereqs (one time)

```bash
cd web && npm install
npx wrangler login          # opens browser; needs your Cloudflare account
```
Confirm the `andybowu.xyz` zone is active in this Cloudflare account (note the zone id).

## 1. Create D1 databases → paste ids into `wrangler.toml`

```bash
npx wrangler d1 create burnbar-staging   # copy database_id
npx wrangler d1 create burnbar-prod      # copy database_id
```
Edit `web/wrangler.toml`, replacing:
- `REPLACE_AFTER_wrangler_d1_create_burnbar-staging` → staging database_id
- `REPLACE_AFTER_wrangler_d1_create_burnbar-prod` → prod database_id

## 2. Create rate-limit KV namespaces → paste ids

```bash
npx wrangler kv namespace create RATE_LIMIT --env staging   # copy id
npx wrangler kv namespace create RATE_LIMIT --env prod      # copy id
```
Replace in `wrangler.toml`:
- `REPLACE_AFTER_wrangler_kv_namespace_create_RATE_LIMIT_staging`
- `REPLACE_AFTER_wrangler_kv_namespace_create_RATE_LIMIT_prod`

(Absent KV → the limiter fails open, so this is non-fatal but should be set.)

## 3. Set the GitHub App client secret (from #52)

The "Burnbar Leaderboard" GitHub App secret lives in 1Password. Put it in the
Worker env only — never commit it:

```bash
npx wrangler secret put GITHUB_CLIENT_SECRET --env staging
npx wrangler secret put GITHUB_CLIENT_SECRET --env prod
```
(Client id `Iv23liZtq4q4ukHeLwsh` is already in the app, committed.)

## 4. Migrate + deploy the API Worker

The `npm run` scripts wrap `wrangler d1 migrations apply` + `wrangler deploy`
per env (see `web/package.json`); run them from `web/`:

```bash
cd web
npm run migrate:staging && npm run deploy:staging   # → *.workers.dev URL; GET / returns {"ok":true}
npm run migrate:prod    && npm run deploy:prod
```

Equivalent explicit commands (if you'd rather not use the npm aliases):

```bash
cd web
npx wrangler d1 migrations apply burnbar-prod --env prod --remote   # applies migrations/0001..0002 to the prod D1
npx wrangler deploy --env prod                                      # deploys src/index.ts with the [env.prod] D1 binding
```

`deploy:prod` also attaches the route `burnbar.andybowu.xyz/api/*` (already in
`wrangler.toml`). The route needs the DNS record in step 6 to resolve; until
then, exercise the API at its `*.workers.dev` URL.

**Note the prod API origin** — it's either the `*.workers.dev` URL printed by
`deploy:prod`, or (once DNS lands) `https://burnbar.andybowu.xyz`. You'll point
the site at it in step 5.

## 5. Point the site at the API (the one-step wiring) + deploy Pages

The site reads its API origin from **`NEXT_PUBLIC_API_URL`** (baked in at build
time — it's a `NEXT_PUBLIC_*` var, so it must be present when `pnpm pages:build`
runs, not just at runtime). Until it's set to a real origin, the site falls back
to the placeholder `api.burnbar.example` and **the leaderboard renders the
intentional "rolling out soon" state instead of a generic error** (see
`web/site/app/lib/api.ts` → `isApiConfigured()`). So the *only* thing needed to
go from "coming soon" to live rows is setting this one variable to the step-4
origin and rebuilding.

Preferred path: GitHub Actions deploys `web/site` via
`.github/workflows/deploy-site.yml`.

Configure the repository first:

- Secret `CLOUDFLARE_API_TOKEN`
- Secret `CLOUDFLARE_ACCOUNT_ID`
- Variable `NEXT_PUBLIC_API_URL` = the prod API origin from step 4
  (`https://burnbar.andybowu.xyz` once DNS lands, or the `*.workers.dev` URL
  before that). The workflow already reads this var (defaulting to
  `https://burnbar.andybowu.xyz`) and exports it into the build env.

Then push a `web/site/**` change to `main`; the workflow runs
`pnpm typecheck`, `pnpm pages:build`, and `wrangler pages deploy --branch main`.
PRs from trusted same-repo branches create Pages previews; forked PRs build and
skip deploy.

Manual fallback:

```bash
cd web/site
pnpm install
NEXT_PUBLIC_API_URL=https://burnbar.andybowu.xyz pnpm pages:build   # bake the API origin into the bundle
npx wrangler pages deploy          # or connect the repo in the Pages dashboard
```
Add **`burnbar.andybowu.xyz`** as a Custom Domain on the Pages project.

> Same-origin alternative: instead of a cross-origin `NEXT_PUBLIC_API_URL`, the
> prod Worker route `burnbar.andybowu.xyz/api/*` (step 4) already makes
> `/api/v1/leaderboard/...` resolve same-origin once DNS lands. Setting
> `NEXT_PUBLIC_API_URL=https://burnbar.andybowu.xyz` uses exactly that route, so
> no extra rewrite/proxy is needed — the Worker route + the Pages catch-all live
> on one hostname.

## 6. DNS — the actual #71 deliverable

In Cloudflare DNS for `andybowu.xyz`:
- Add `CNAME` `burnbar` → the Pages project domain (`<project>.pages.dev`),
  **proxied (orange cloud) ON**.

Verify:
```bash
dig +short burnbar.andybowu.xyz     # resolves → #71 Definition of Done met
```

## 7. TLS / HTTPS (3.6.3 — zone settings)

In the `andybowu.xyz` zone:
- **Universal SSL**: on (cert for the custom domain).
- **Always Use HTTPS**: on (so `http://` → `301` `https://`).
- **SSL/TLS mode**: Full (strict).

(The Worker already sends the HSTS header on every response — that part is code,
already done in #156.)

## 8. End-to-end verification → close #71, #90

```bash
curl -i https://burnbar.andybowu.xyz/api/v1/leaderboard/daily   # JSON from the API Worker
curl -i https://burnbar.andybowu.xyz/                            # web landing page (Pages)
curl -i http://burnbar.andybowu.xyz                             # 301 → https
curl -s https://burnbar.andybowu.xyz/leaderboard/daily | grep -o "rolling out soon" || echo "no coming-soon copy (API is wired)"
```
- All three `curl -i` pass → **close #71** (DNS CNAME). With #72/#73 already
  closed, **#90** (Domain epic) can close too.
- The `/leaderboard/daily` page should now render **real rows or the empty
  "No entries yet" state — NOT "rolling out soon"** (that string appearing means
  `NEXT_PUBLIC_API_URL` was unset at `pnpm pages:build` time → redo step 5) and
  NOT the red "Couldn't load…" error (that means the API origin is set but the
  Worker is unreachable/500 → check step 4). **This closes #173.**
- Then test the app: sign in with GitHub from Settings → it should reach
  `/api/v1/me` and authenticate. (This also retroactively validates the #86
  revoke path against a live token — see the note on the closed #86.)

## ⚠️ Don't commit the filled-in ids

`wrangler.toml` will then contain real database_ids / KV ids. These aren't
secrets, but decide deliberately whether to commit them. The `client_secret` is
**never** in this file (it's a `wrangler secret`). Do a `git diff web/wrangler.toml`
before committing.
