#!/usr/bin/env bash
#
# Developer ID signing + notarization for Burnbar (#167).
#
# Two modes, selected automatically by which credentials are present:
#
#   * Developer ID mode — when a signing identity is configured (env
#     DEVELOPER_ID_APPLICATION, e.g. "Developer ID Application: Andy Wu (TEAMID)").
#     Signs the embedded BurnbarCore.framework + the bundled Sparkle code FIRST,
#     then the app, all with `--options runtime` (hardened runtime) + a secure
#     timestamp, then (if notary creds are present) notarizes and staples the
#     archive(s), and verifies with spctl + codesign.
#
#   * Ad-hoc fallback — when DEVELOPER_ID_APPLICATION is empty/unset, this script
#     is a no-op signer: callers (package_app.sh / make_dmg.sh) keep their
#     existing `codesign --sign -` behavior. Local builds and CI without secrets
#     are therefore unchanged.
#
# Usage (two entry points):
#
#   # 1. Sign an .app in place (called by package_app.sh / make_dmg.sh):
#   ./Scripts/sign_and_notarize.sh sign-app  path/to/Burnbar.app
#
#   # 2. Notarize + staple a built archive (.zip or .dmg) (called after packaging):
#   ./Scripts/sign_and_notarize.sh notarize  path/to/Burnbar-vX.Y.Z.dmg
#
# Helper predicates (used by the callers to branch ad-hoc vs Developer ID):
#   ./Scripts/sign_and_notarize.sh can-sign       # exit 0 if Developer ID identity is set
#   ./Scripts/sign_and_notarize.sh can-notarize   # exit 0 if notary credentials are set
#
# Required env for the Developer ID path:
#   DEVELOPER_ID_APPLICATION   Codesign identity string OR SHA-1 hash of the
#                              "Developer ID Application" cert in the keychain.
# Required env for notarization (notarytool):
#   Either a stored keychain profile:
#     NOTARY_KEYCHAIN_PROFILE  Name of a profile created with
#                              `xcrun notarytool store-credentials`.
#   Or App-Store-Connect creds (used when NOTARY_KEYCHAIN_PROFILE is empty):
#     APPLE_ID                 Apple ID email of the Developer account.
#     APPLE_TEAM_ID            10-char Team ID.
#     APPLE_APP_SPECIFIC_PASSWORD  App-specific password (appleid.apple.com).
# Optional:
#   CODESIGN_ENTITLEMENTS      Path to the hardened-runtime entitlements plist
#                              (default: Scripts/Burnbar.entitlements).
#
# NOTE: This Developer ID / notarization path is OPERATOR-VERIFIED ONLY — it has
# not been run end-to-end here because that needs an Apple Developer ID cert and
# notary credentials. It implements Apple's documented flow
# (developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
#
set -euo pipefail
cd "$(dirname "$0")/.."

ENTITLEMENTS="${CODESIGN_ENTITLEMENTS:-Scripts/Burnbar.entitlements}"

# --- predicates --------------------------------------------------------------

# True when a Developer ID Application identity is configured.
can_sign() {
  [ -n "${DEVELOPER_ID_APPLICATION:-}" ]
}

# True when notarytool has credentials to submit with (either a stored keychain
# profile, or the App-Store-Connect Apple-ID triplet).
can_notarize() {
  if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    return 0
  fi
  [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]
}

# --- signing -----------------------------------------------------------------

# Codesign the app bundle with Developer ID + hardened runtime, signing all
# nested code (BurnbarCore.framework, Sparkle.framework and its embedded
# Autoupdate / Updater.app / XPC services, plus any stray dylibs) from the
# inside out. `--deep` is deliberately AVOIDED: Apple documents it as unreliable
# for nested helpers and it does not apply entitlements per-nested-binary, so we
# walk the bundle explicitly.
sign_app() {
  local app="$1"
  [ -d "$app" ] || { echo "error: not an app bundle: $app" >&2; exit 1; }
  [ -f "$ENTITLEMENTS" ] || { echo "error: entitlements not found: $ENTITLEMENTS" >&2; exit 1; }

  local id="$DEVELOPER_ID_APPLICATION"
  echo "==> Developer ID signing $app"
  echo "    identity:     $id"
  echo "    entitlements: $ENTITLEMENTS"

  # Strip extended attributes first so the seal is computed over a clean bundle
  # (mirrors the ad-hoc path in package_app.sh — #171).
  xattr -cr "$app"

  # 1) Sign every nested Mach-O (dylibs, frameworks, helper apps, XPC services)
  #    BEFORE the outer app, deepest first. `find ... -depth` yields children
  #    ahead of parents so inner code is sealed before the bundle that contains
  #    it. Hardened runtime (`--options runtime`) + secure timestamp on each.
  local nested
  while IFS= read -r -d '' nested; do
    echo "    sign (nested): ${nested#"$app"/}"
    codesign --force --timestamp --options runtime \
      --sign "$id" "$nested"
  done < <(
    find "$app/Contents" -depth \
      \( -name "*.dylib" -o -name "*.framework" -o -name "*.app" \
         -o -name "*.xpc" -o -name "*.appex" -o -name "*.bundle" \) \
      -print0
  )

  # 2) Sign the bundled Sparkle "Autoupdate" CLI helper if present (it lives
  #    inside Sparkle.framework's Versions and is a bare Mach-O, not a bundle,
  #    so the bundle-suffix sweep above can miss it). No-op if absent.
  local autoupdate
  while IFS= read -r -d '' autoupdate; do
    echo "    sign (helper): ${autoupdate#"$app"/}"
    codesign --force --timestamp --options runtime \
      --sign "$id" "$autoupdate"
  done < <(find "$app/Contents" -type f -name "Autoupdate" -print0)

  # 3) Finally sign the outer app with the hardened-runtime entitlements.
  echo "    sign (app):   ${app##*/}"
  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$id" "$app"

  echo "==> Verifying signature (strict, hardened runtime)"
  codesign --verify --deep --strict --verbose=2 "$app"
  codesign -dvvv "$app" 2>&1 | grep -E 'Authority|TeamIdentifier|Signature|flags|Runtime' || true

  # Gatekeeper assessment. On an unnotarized build this prints "rejected" until
  # the archive is notarized + stapled (done in notarize()); we surface but do
  # not fail on it here so the app can still be packaged before submission.
  echo "==> Gatekeeper pre-check (spctl) — expected to PASS only after notarization+staple"
  spctl --assess --type execute --verbose=4 "$app" || \
    echo "note: spctl rejected (expected pre-notarization); will re-verify after staple"
}

# --- notarization ------------------------------------------------------------

# Submit an archive (.zip or .dmg) to the Apple notary service, wait for the
# result, staple the ticket, and re-verify. Operates on the distributable
# archive — for a .zip we staple the .app the zip was made from, then the caller
# re-zips; for a .dmg we staple the .dmg directly (the recommended container).
notarize() {
  local artifact="$1"
  [ -f "$artifact" ] || { echo "error: artifact not found: $artifact" >&2; exit 1; }

  # Build the notarytool credential arguments once.
  local -a cred
  if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    cred=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    echo "==> Notarizing with keychain profile: $NOTARY_KEYCHAIN_PROFILE"
  else
    cred=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
          --password "$APPLE_APP_SPECIFIC_PASSWORD")
    echo "==> Notarizing with Apple ID: $APPLE_ID (team $APPLE_TEAM_ID)"
  fi

  echo "==> Submitting $artifact to notary service (this can take a few minutes)"
  xcrun notarytool submit "$artifact" "${cred[@]}" --wait

  case "$artifact" in
    *.dmg)
      echo "==> Stapling ticket to $artifact"
      xcrun stapler staple "$artifact"
      xcrun stapler validate "$artifact"
      echo "==> Gatekeeper assessment of stapled DMG"
      spctl --assess --type open --context context:primary-signature --verbose=4 "$artifact"
      ;;
    *.zip)
      # A zip is a transport container, not a stapleable bundle. Notarization of
      # the zip registers the enclosed app with Apple; to ship an offline-openable
      # zip we staple the ticket onto the .app and let the caller re-zip it.
      echo "note: zip notarized. Staple the ENCLOSED .app, then re-zip — see"
      echo "      'staple-app' subcommand (package_app.sh handles the re-zip)."
      ;;
    *)
      echo "warning: unknown artifact type for $artifact — submitted but not stapled" >&2
      ;;
  esac
}

# Staple a notarization ticket onto an .app bundle (after the zip it came from
# was notarized) and verify with the full strict + hardened-runtime check.
staple_app() {
  local app="$1"
  [ -d "$app" ] || { echo "error: not an app bundle: $app" >&2; exit 1; }
  echo "==> Stapling ticket to $app"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  echo "==> Final verification (codesign strict + spctl execute)"
  codesign --verify --deep --strict --options=runtime --verbose=2 "$app"
  spctl --assess --type execute --verbose=4 "$app"
}

# --- dispatch ----------------------------------------------------------------

cmd="${1:-}"
case "$cmd" in
  can-sign)     can_sign ;;
  can-notarize) can_notarize ;;
  sign-app)
    shift
    [ $# -ge 1 ] || { echo "usage: $0 sign-app <Burnbar.app>" >&2; exit 2; }
    can_sign || { echo "error: DEVELOPER_ID_APPLICATION not set — nothing to do" >&2; exit 1; }
    sign_app "$1"
    ;;
  notarize)
    shift
    [ $# -ge 1 ] || { echo "usage: $0 notarize <artifact.zip|.dmg>" >&2; exit 2; }
    can_notarize || { echo "error: notary credentials not set — cannot notarize" >&2; exit 1; }
    notarize "$1"
    ;;
  staple-app)
    shift
    [ $# -ge 1 ] || { echo "usage: $0 staple-app <Burnbar.app>" >&2; exit 2; }
    staple_app "$1"
    ;;
  ""|-h|--help)
    grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
    ;;
  *)
    echo "error: unknown command: $cmd" >&2
    echo "commands: can-sign | can-notarize | sign-app <app> | notarize <archive> | staple-app <app>" >&2
    exit 2
    ;;
esac
