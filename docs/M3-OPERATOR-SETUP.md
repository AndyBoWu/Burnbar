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
then works. Until Developer ID signing + notarization is enabled (next section),
v0 ships ad-hoc signed, so first launch needs right-click → Open — see
ROADMAP.md and the cask's `postflight` quarantine strip.

## 6. Developer ID signing + notarization (#167)

Until this is set up, releases are **ad-hoc signed** (`Signature=adhoc`,
`TeamIdentifier=not set`) and Gatekeeper rejects a fresh download
(`spctl --assess` → `rejected`), forcing right-click → Open. The tooling for the
full Developer ID + hardened-runtime + notarization + stapling flow is already in
the repo and **activates automatically once the secrets below exist** — nothing
in the scripts or workflow changes. This step needs a paid Apple Developer
account ($99/yr); it is the only blocker.

### 6a. One-time Apple Developer assets

1. **Developer ID Application certificate.** Apple Developer → Certificates → `+`
   → **Developer ID Application** (NOT "Apple Distribution" / "Mac App Store").
   Create it, download the `.cer`, double-click to add it to your **login**
   keychain. In **Keychain Access** confirm the private key sits under the cert.
2. **Export the signing identity as a `.p12`.** In Keychain Access select **both**
   the "Developer ID Application: …" cert **and** its private key → right-click →
   **Export 2 items…** → `.p12`, set a strong password. This password becomes the
   `MACOS_CERTIFICATE_PWD` secret.
3. **Note the identity string + Team ID.** Run locally:
   ```bash
   security find-identity -v -p codesigning
   # → "Developer ID Application: Andy Wu (TEAMID)"  ← the full quoted string
   ```
   The full quoted string is `MACOS_SIGNING_IDENTITY`; the 10-char `(TEAMID)` is
   `APPLE_TEAM_ID`.
4. **App-specific password for notarytool.** appleid.apple.com → Sign-In &
   Security → **App-Specific Passwords** → generate one labelled `burnbar-notary`.
   This is `APPLE_APP_SPECIFIC_PASSWORD`; your Apple ID email is `APPLE_ID`.

### 6b. Add the GitHub repo secrets

Settings → Secrets and variables → **Actions** → New repository secret, for each:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of the `.p12`: `base64 -i DeveloperID.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PWD` | the `.p12` export password from 6a-2 |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Andy Wu (TEAMID)` |
| `KEYCHAIN_PASSWORD` | any random string — names the throwaway CI keychain |
| `APPLE_ID` | your Apple Developer account email |
| `APPLE_TEAM_ID` | the 10-char Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | the app-specific password from 6a-4 |

`MACOS_CERTIFICATE` gates the whole path: with it set, `release.yml` imports the
cert into a temporary keychain and the packaging scripts switch to Developer ID
signing + notarization; without it the release stays ad-hoc. **Never commit any
of these values.**

### 6c. Cut a signed + notarized release

Same trigger as before — push a `v*.*.*` tag:

```bash
git tag v0.2.0 && git push origin v0.2.0   # release.yml signs + notarizes + staples
```

Or run it locally (the scripts auto-detect the env vars; absent → ad-hoc):

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Andy Wu (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_SPECIFIC_PASSWORD="abcd-efgh-ijkl-mnop"
# (optional) instead of the Apple-ID triplet, store a notarytool profile once:
#   xcrun notarytool store-credentials burnbar-notary \
#     --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
#     --password "$APPLE_APP_SPECIFIC_PASSWORD"
#   export NOTARY_KEYCHAIN_PROFILE=burnbar-notary
./Scripts/package_app.sh   # signs (hardened runtime) → notarizes zip → staples app → re-zips
./Scripts/make_dmg.sh      # reuses the signed app → signs+notarizes+staples the DMG
```

`Scripts/sign_and_notarize.sh` does the signing/notarization; it signs the
embedded `BurnbarCore.framework` and the bundled Sparkle helpers
(`Autoupdate`, `Downloader.xpc`, `Installer.xpc`) **before** the app, all with
`--options runtime` + a secure timestamp, then `notarytool submit --wait` and
`stapler staple`. Verify a downloaded artifact opens cleanly:

```bash
spctl --assess --type execute --verbose=4 /Applications/Burnbar.app   # → accepted
codesign --verify --deep --strict --options=runtime --verbose=2 /Applications/Burnbar.app
```

After this ships, drop the `postflight`/quarantine-strip from `Casks/burnbar.rb`
(it is only needed for ad-hoc builds).

> Status: the Developer ID / notarization path is **operator-verified only** — it
> has not been run end-to-end in CI because that needs the cert + credentials
> above. The ad-hoc path remains fully tested and is the default until 6b is done.

## 7. Landing-page screenshots (#177)

The website's "See Burnbar in action" section is **asset-gated**: it ships
hidden until real app PNGs exist, because screenshots can't be captured in CI
(no Screen Recording permission, and the popover needs a live display). Only you
can produce them.

1. On a Mac, grant Screen Recording to your terminal: System Settings → Privacy
   & Security → Screen Recording → enable for Terminal/iTerm/VS Code, then quit
   and reopen that terminal so the permission takes effect.
2. Run the capture tool — it builds + launches `Burnbar.app` and walks you
   through each shot:

   ```bash
   ./Scripts/capture_screenshots.sh   # → web/site/public/screenshots/*.png
   ```

   It saves `menubar.png`, `popover.png`, `empty-state.png`, and `settings.png`.
   Filenames + recommended dimensions are in
   `web/site/public/screenshots/README.md`.
3. **Privacy check:** Burnbar's UI can surface project names/paths. Use a clean
   demo profile and eyeball every PNG before committing — no real paths, project
   names, git branches, or prompts may ship.
4. Set `const HAS_SCREENSHOTS = false;` → `true` in `web/site/app/page.tsx`, and
   flip each `available: false` → `true` for the images you added. Run
   `cd web/site && pnpm typecheck && pnpm build` to confirm it's still green and
   static, then commit the PNGs + the flip. Once live, close #177.
