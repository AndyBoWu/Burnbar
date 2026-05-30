# Burnbar Site (Next.js + Tailwind → Cloudflare Pages)

The public web front-end for Burnbar's M3 leaderboard. This is the **Pages app**;
it lives alongside — but is cleanly separated from — the Worker API in
[`../`](../) (`web/src`, `web/wrangler.toml`). The Worker serves
`/api/v1/*`; this app serves the landing, leaderboard, and profile pages.

App Router + Tailwind. English-only (per CLAUDE.md constraint 5). This ticket
(3.4.1) is the **runnable, deployable shell** — the leaderboard / landing /
profile pages land in #63–#66.

## Develop & build locally (no Cloudflare account needed)

```bash
cd web/site
pnpm install
pnpm dev        # Next dev server at http://localhost:3000
pnpm build      # production build — must compile clean
pnpm typecheck  # tsc --noEmit (strict)
```

## Deploy (Cloudflare Pages — needs an account)

Deploy is the **operator's** step and requires `wrangler login` + a Cloudflare
account. The build is adapted for Pages with `@cloudflare/next-on-pages`, which
emits a static/edge bundle under `.vercel/output/static`:

```bash
cd web/site
pnpm pages:build          # next-on-pages → .vercel/output/static
pnpm deploy:staging       # wrangler pages deploy ... --branch staging
pnpm deploy:prod          # wrangler pages deploy ... --branch main
```

The first `wrangler pages deploy` creates the `burnbar-site` Pages project and
returns the staging URL. Production custom domains are configured in the
Cloudflare dashboard.

## Structure

```
web/site/
  app/
    layout.tsx     # root layout — <html lang="en">, Tailwind globals
    page.tsx       # placeholder landing ("Burnbar leaderboard")
    globals.css    # @tailwind base/components/utilities
  next.config.mjs
  tailwind.config.ts
  postcss.config.mjs
  tsconfig.json
```
