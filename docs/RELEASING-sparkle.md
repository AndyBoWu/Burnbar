# Releasing with Sparkle (deferred)

Status: **skeleton only (Epic 1.6.4).** Sparkle is linked into Burnbar.app, but
auto-update is **OFF** in v0 — there is no live appcast endpoint, no EdDSA key
in the bundle, and the app never instantiates an updater or makes update
network calls on launch. This document records the key-custody and release
procedure so a future milestone can turn auto-update on without re-deriving it.

## What ships in v0 (and what does not)

Present now:

- Sparkle 2.x linked + embedded as `Sparkle.framework` (SPM dependency in
  `project.yml`; resolves over the network on `xcodegen generate` + build).
- `Info.plist` placeholder keys: `SUEnableAutomaticChecks = NO`,
  `SUPublicEDKey` (placeholder), `SUFeedURL` (non-resolving placeholder).
- `release/appcast.xml` template with placeholder enclosure/version/signature
  fields.

Deliberately absent (do **not** add until enablement):

- No `SPUStandardUpdaterController` / `SPUUpdater` is instantiated or started.
- No real `SUFeedURL` — the placeholder never resolves, and automatic checks
  are off, so Sparkle issues **zero** network requests at launch.
- No EdDSA keypair is generated or committed. **Do not** run
  `bin/generate_keys` as part of normal development — it writes a private key
  into the login Keychain.

## EdDSA key generation + custody (run once, at enablement)

Sparkle signs each update with an EdDSA (Ed25519) keypair. The **private** key
must never enter the repo or any release artifact; only the **public** key is
embedded in the app.

1. Locate `generate_keys` inside the resolved Sparkle artifact. After a build,
   it is under Sparkle's SPM checkout, e.g.:

   ```
   find ~/Library/Developer/Xcode/DerivedData -path '*/Sparkle/bin/generate_keys' 2>/dev/null
   # or, if using a downloaded Sparkle release tarball: ./bin/generate_keys
   ```

2. Generate the keypair **once**, on the designated release machine:

   ```
   ./bin/generate_keys
   ```

   This writes the **private** key into the macOS **login Keychain** (service
   `https://sparkle-project.org`, account a Sparkle-managed identifier) and
   prints the base64 **public** key to stdout. This is the only Keychain item
   Burnbar's tooling touches, and it belongs to us — consistent with the
   project privacy thesis (we never read third-party Keychain items).

3. Back up the private key out-of-band (e.g. a password manager), then export
   the public key:

   ```
   ./bin/generate_keys -p   # prints the public key again, any time
   ```

4. **Custody rules:**
   - The private key lives only in the login Keychain on the release machine
     (and an out-of-band backup). It is **never** committed.
   - `.gitignore` already blocks `sparkle_ed_priv.key` and
     `sparkle_dsa_priv.pem`, plus `*.key` / `*.pem` — never disable these.
   - Anyone with the private key can ship a signed "update" to all users.
     Treat it like a code-signing identity.

## Enabling auto-update (future milestone — not v0)

When an update endpoint and (ideally) a Developer ID + notarization pipeline
exist:

1. Paste the base64 public key into `Info.plist` → `SUPublicEDKey`
   (replace the placeholder).
2. Set `SUFeedURL` to the real published appcast URL.
3. Set `SUEnableAutomaticChecks` → `YES` (or drive it from Settings).
4. Instantiate `SPUStandardUpdaterController` in the app and wire a
   "Check for Updates…" menu item.
5. For each release, fill in `release/appcast.xml` from the template:
   - Build + package the zip with `./Scripts/package_app.sh`
     (produces `dist/Burnbar-vX.Y.Z.zip`).
   - Sign it: `./bin/sign_update dist/Burnbar-vX.Y.Z.zip` → paste the output
     into `sparkle:edSignature`.
   - Fill `url`, `length` (byte size), `sparkle:version` (build number),
     `sparkle:shortVersionString`, and `pubDate`.
   - Publish the appcast at `SUFeedURL` and upload the zip to the enclosure
     `url`.

## References

- Sparkle docs: <https://sparkle-project.org/documentation/>
- `release/appcast.xml` — the appcast template this process fills in.
- `docs/PLAN.md` → Epic 1.6.4 and Decisions log
  ("Sparkle: skeleton only … no Apple Developer cert yet").
