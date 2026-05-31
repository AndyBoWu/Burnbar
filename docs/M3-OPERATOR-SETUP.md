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

Preferred path: configure GitHub Actions and let
`.github/workflows/deploy-site.yml` deploy `web/site`.

Set these in GitHub first:

- Secret `CLOUDFLARE_API_TOKEN`
- Secret `CLOUDFLARE_ACCOUNT_ID`
- Variable `NEXT_PUBLIC_API_URL=https://burnbar.andybowu.xyz`

After that, pushes to `main` that touch `web/site/**` deploy production.
Pull requests from trusted same-repo branches get Pages previews.

Manual fallback:

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

Cutting a release is automated by `.github/workflows/release.yml`: push a
`v*.*.*` tag and CI (on `macos-14`) builds **both** artifacts and publishes a
GitHub Release with the `.zip` and `.dmg` attached.

```bash
git tag v0.1.0 && git push origin v0.1.0   # triggers the Release workflow
# CI runs package_app.sh (zip) + make_dmg.sh (DMG: Burnbar.app + /Applications
# drag-link) and attaches both to a GitHub Release for tag v0.1.0.
```

To build/publish manually instead (e.g. to inspect artifacts first):

```bash
./Scripts/package_app.sh    # dist/Burnbar-vX.Y.Z.zip + sha256
./Scripts/make_dmg.sh       # dist/Burnbar-vX.Y.Z.dmg + sha256 (reuses the zip's build)
gh release create vX.Y.Z dist/Burnbar-vX.Y.Z.zip dist/Burnbar-vX.Y.Z.dmg
```

Then create a PUBLIC `andybowu/homebrew-tap` repo and add `Casks/burnbar.rb`
pointing at the release zip + sha256 (`Scripts/update_cask.sh` automates
version+sha bumps once it lands). `brew install --cask andybowu/tap/burnbar`
then works (right-click → Open first launch, since v0 is ad-hoc signed — see
ROADMAP.md). Developer ID signing + notarization is tracked by #167, which slots
into the release workflow at the marked insertion point.
