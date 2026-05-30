# M3 operator setup (the steps only you can do)

Everything in Burnbar's M3 leaderboard is **code-complete and locally verified**
(the Worker API, the Next.js site, the Swift auth/upload client). What remains
are **outward-facing actions that require your accounts** — they can't be done
from CI or by an agent. This is the runbook. Do these once.

## 1. Cloudflare account → deploy the API (unblocks #47, #72, #73, #85, #90)

```bash
cd web
npm install
wrangler login                                  # opens a browser; needs your Cloudflare account
wrangler d1 create burnbar-staging              # paste the returned database_id into wrangler.toml [env.staging]
wrangler d1 create burnbar-prod                 # → [env.prod]
wrangler kv namespace create RATE_LIMIT --env staging   # paste id into wrangler.toml
wrangler kv namespace create RATE_LIMIT --env prod
npm run migrate:staging && npm run deploy:staging       # → staging URL; GET / returns 200
npm run migrate:prod    && npm run deploy:prod
```

## 2. Register the GitHub App (unblocks #52, #86, and the auth client)

1. github.com → Settings → Developer settings → **GitHub Apps → New GitHub App**.
2. Name `Burnbar`; enable **Device Flow**; permissions: read-only `read:user`.
3. Copy the **Client ID** → set `GitHubDeviceFlow.clientID` in
   `Sources/BurnbarCore/Auth/` (replace the placeholder). Commit it (client_id is
   not a secret).
4. Generate a client secret → store it in the Worker only:
   `wrangler secret put GITHUB_CLIENT_SECRET --env staging` (and prod). **Never commit it.**

## 3. Web frontend → Cloudflare Pages (unblocks #62 deploy, #88)

```bash
cd web/site
pnpm install && pnpm build
wrangler pages deploy            # or connect the repo in the Cloudflare Pages dashboard
```
Set `NEXT_PUBLIC_API_URL` to the deployed API origin.

## 4. DNS for burnbar.andybowu.xyz (unblocks #71, #72, #73, #90)

In Cloudflare DNS for `andybowu.xyz`: add a `CNAME` `burnbar` → the Pages domain;
the Worker route `burnbar.andybowu.xyz/api/*` → the API Worker (in `wrangler.toml`
`routes`); Universal SSL is automatic. `dig burnbar.andybowu.xyz` should resolve.

## 5. Homebrew tap + release (unblocks #28, #79)

```bash
./Scripts/package_app.sh                 # builds dist/Burnbar-vX.Y.Z.zip + prints sha256
gh release create vX.Y.Z dist/Burnbar-vX.Y.Z.zip   # cut the GitHub Release
# Create a PUBLIC repo: andybowu/homebrew-tap, add Casks/burnbar.rb pointing at the
# release zip + sha256 (Scripts/update_cask.sh automates version+sha bumps once it lands).
```
Then `brew install --cask andybowu/tap/burnbar` works (right-click → Open first
launch, since v0 is ad-hoc signed — see ROADMAP.md).
