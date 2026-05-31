import type { Metadata } from "next";
import Link from "next/link";

import {
  LEADERBOARD_ROLLING_OUT_SHORT,
  UPLOAD_PAYLOAD_FIELD_LIST,
} from "@/app/lib/api";
import {
  getLatestRelease,
  RELEASES_LATEST_URL,
  RELEASES_URL,
} from "@/app/lib/release";

/** Burnbar source on GitHub — the "View source" trust-signal link. */
const SOURCE_URL = "https://github.com/AndyBoWu/Burnbar";

/**
 * Format an ISO-8601 timestamp to a stable, locale-independent human date
 * (e.g. `May 30, 2026`). Pinned to `en-US` + UTC so the build-time-rendered
 * HTML is deterministic regardless of the build machine's locale/timezone.
 * Returns `null` when the timestamp is missing or unparseable, so callers can
 * omit the date rather than render `Invalid Date`.
 */
function formatReleaseDate(iso: string | null): string | null {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

/**
 * Format a byte count as `X.Y MB`. Returns `null` for non-positive/unknown
 * sizes (the resolver uses `0` when GitHub omits the size) so callers can
 * omit the row instead of rendering `0.0 MB` or `NaN`.
 */
function formatFileSize(bytes: number): string | null {
  if (!Number.isFinite(bytes) || bytes <= 0) return null;
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

/**
 * Split a `"sha256:<hex>"` digest into its hex value, or `null` when no digest
 * is present (older assets may lack one — handle that case by linking to the
 * release page instead of rendering `undefined`).
 */
function parseSha256(digest: string | null): string | null {
  if (!digest) return null;
  const hex = digest.startsWith("sha256:") ? digest.slice("sha256:".length) : digest;
  return hex !== "" ? hex : null;
}

const LANDING_TITLE = "Burnbar — Track AI-coding token burn in your menu bar";
const LANDING_DESCRIPTION =
  "Burnbar is a native macOS menu-bar app that tracks your Claude Code and OpenAI Codex token usage by reading only local CLI logs. No browser data, no third-party Keychain access.";

/** Minimum supported macOS version. Burnbar targets macOS 14+ (Sonoma). */
const MIN_MACOS = "macOS 14 (Sonoma)";

/**
 * Whether the shipped build is Apple-notarized. While `false`, the install
 * steps include the first-open Gatekeeper workaround (right-click → Open),
 * because ad-hoc-signed builds trip Gatekeeper on first launch.
 *
 * REMOVABILITY: once notarization ships (issue #167), flip this to `true`. The
 * right-click → Open step then disappears automatically — no other edits
 * needed. The macOS 14+ requirement and the move-to-Applications steps stay
 * regardless of notarization status.
 */
const IS_NOTARIZED = false;

/**
 * Whether real app screenshots have been added (issue #177).
 *
 * The "See Burnbar in action" section renders nothing while this is `false`, so
 * the live page stays clean until real assets exist — no broken images, no
 * empty frames. To turn the section on:
 *   1. Run `./Scripts/capture_screenshots.sh` on a Mac with Screen Recording
 *      permission (it drops PNGs into `public/screenshots/`).
 *   2. Review each PNG for stray paths/project names (privacy — see
 *      `public/screenshots/README.md`).
 *   3. Flip this to `true`. The section then renders whichever of the
 *      `SCREENSHOTS` below have a file present (mark `available: true`).
 * No other edits needed.
 */
const HAS_SCREENSHOTS = false;

type Screenshot = {
  /** Path under `public/` — e.g. `/screenshots/popover.png`. */
  src: string;
  /** Descriptive alt text (required for accessibility). */
  alt: string;
  /** Short caption shown under the frame. */
  caption: string;
  /**
   * Intrinsic pixel dimensions. Set explicit width/height so the browser
   * reserves space before the lazy image loads (zero layout shift). Update
   * these to match your real PNG's aspect ratio if it differs.
   */
  width: number;
  height: number;
  /** Span the full row (used for the wide menu-bar banner). */
  wide?: boolean;
  /** Flip to `true` once the matching PNG exists in `public/screenshots/`. */
  available: boolean;
};

// The app-preview gallery. Each entry maps to a file documented in
// `public/screenshots/README.md`. Only entries with `available: true` render,
// so the operator can ship images one at a time.
const SCREENSHOTS: Screenshot[] = [
  {
    src: "/screenshots/menubar.png",
    alt: "Burnbar's flame status item in the macOS menu bar, showing today's token spend next to the clock.",
    caption: "Lives in your menu bar — today's burn at a glance.",
    width: 1600,
    height: 200,
    wide: true,
    available: false,
  },
  {
    src: "/screenshots/popover.png",
    alt: "Burnbar's popover listing Claude Code and OpenAI Codex token usage with per-provider costs for today.",
    caption: "The popover: per-provider tokens and cost.",
    width: 720,
    height: 960,
    available: false,
  },
  {
    src: "/screenshots/empty-state.png",
    alt: "Burnbar's popover empty state, shown before any usage has been recorded, with guidance on getting started.",
    caption: "A friendly, actionable empty state on day one.",
    width: 720,
    height: 960,
    available: false,
  },
  {
    src: "/screenshots/settings.png",
    alt: "Burnbar's Settings window showing provider toggles and the opt-in leaderboard controls.",
    caption: "Settings: providers and the opt-in leaderboard.",
    width: 1280,
    height: 900,
    available: false,
  },
];

export const metadata: Metadata = {
  title: LANDING_TITLE,
  description: LANDING_DESCRIPTION,
  alternates: {
    canonical: "/",
  },
  // Explicit social title/description so the landing page's preview describes
  // the product, not the leaderboard (it must not inherit a generic default).
  openGraph: {
    title: LANDING_TITLE,
    description: LANDING_DESCRIPTION,
    url: "/",
  },
  twitter: {
    title: LANDING_TITLE,
    description: LANDING_DESCRIPTION,
  },
};

type Pillar = {
  emoji: string;
  title: string;
  body: string;
};

// The three pain points, each paired with Burnbar's answer.
const PILLARS: Pillar[] = [
  {
    emoji: "🛡️",
    title: "No browser snooping",
    body: "Trackers like CodexBar read your browser cookies and dig through your Keychain just to fetch your numbers. Burnbar never touches either — it reads only the local CLI logs Claude Code and Codex already write to ~/.claude and ~/.codex.",
  },
  {
    emoji: "🔒",
    title: "Your data stays on your Mac",
    body: "No account, no analytics, no server quietly collecting your usage. Everything is computed locally. The only thing that ever leaves is a tiny daily summary — and only if you choose to join the leaderboard.",
  },
  {
    emoji: "✨",
    title: "One number, zero clutter",
    body: "A native macOS app — not an Electron tab, not a dashboard you have to babysit. It shows your burn in the menu bar and gets out of the way. Open it and you’re done.",
  },
];

type Cell = "yes" | "no" | "na";

type CompareRow = {
  label: string;
  burnbar: Cell;
  others: Cell;
};

const COMPARISON: CompareRow[] = [
  { label: "Reads only local CLI logs", burnbar: "yes", others: "no" },
  { label: "Leaves your browser cookies alone", burnbar: "yes", others: "no" },
  { label: "Never touches your Keychain", burnbar: "yes", others: "no" },
  { label: "Your usage never leaves your Mac *", burnbar: "yes", others: "na" },
  { label: "Native, single-purpose menu-bar app", burnbar: "yes", others: "yes" },
];

type Step = {
  title: string;
  body: string;
};

const STEPS: Step[] = [
  {
    title: "Reads local logs",
    body: "Burnbar parses the usage logs Claude Code and OpenAI Codex already write to ~/.claude and ~/.codex. Token counts, models, and timestamps only — never your prompts or code.",
  },
  {
    title: "Syncs across devices",
    body: "Per-machine rollups sync privately through your own iCloud Drive, so usage from every Mac you code on adds up in one place. Nothing touches a Burnbar server.",
  },
  {
    title: "Opt-in leaderboard",
    body: "Choose to share, and Burnbar uploads a tiny daily summary to climb the global leaderboard. Off by default, and you decide every time. The public leaderboard is rolling out soon — opt in now and you'll appear once it's live.",
  },
];

type Promise = {
  label: string;
  body: string;
};

const PROMISES: Promise[] = [
  {
    label: "Local CLI logs only",
    body: "Burnbar reads only Claude Code and OpenAI Codex logs under ~/.claude and ~/.codex on your machine.",
  },
  {
    label: "Never your browser or Keychain",
    body: "No browser cookies, local storage, or third-party Keychain items. Burnbar touches only its own credentials.",
  },
  {
    label: "Never your content",
    body: "Prompts, code, project names, file paths, and git details are never read for upload — only counts, models, and dates.",
  },
  {
    label: "Minimal opt-in upload",
    body: `If you join the leaderboard, each uploaded row is only { ${UPLOAD_PAYLOAD_FIELD_LIST} } — no prompts, paths, project names, machine ids, or raw model names. Rows are tied to your public GitHub identity (github_id, github_login), read from your sign-in, so they can appear on the public leaderboard.`,
  },
];

function Mark({ value }: { value: Cell }) {
  if (value === "yes") {
    return (
      <span className="text-lg font-bold text-orange-400">
        <span aria-hidden="true">✓</span>
        <span className="sr-only">Yes</span>
      </span>
    );
  }
  if (value === "no") {
    return (
      <span className="text-lg text-zinc-500">
        <span aria-hidden="true">✗</span>
        <span className="sr-only">No</span>
      </span>
    );
  }
  return (
    <span className="text-zinc-600">
      <span aria-hidden="true">—</span>
      <span className="sr-only">Not applicable</span>
    </span>
  );
}

export default async function HomePage() {
  // Resolve the latest macOS artifact at build time so the primary CTAs link
  // DIRECTLY to the recommended download (issue #168). On any API failure this
  // falls back to the /releases/latest page, so the build never breaks.
  const release = await getLatestRelease();
  const downloadLabel = release.version
    ? `Download for macOS (${release.version})`
    : "Download for macOS";

  // Tailor the "unpack and move" step to whichever artifact the release ships.
  // The resolver prefers a .dmg (drag-to-Applications) and falls back to a .zip;
  // when neither is resolved (API fallback) we cover both so the copy is always
  // accurate.
  const assetName = release.recommendedAsset?.name.toLowerCase() ?? "";
  const unpackStep = assetName.endsWith(".dmg")
    ? "Open the downloaded .dmg and drag Burnbar.app into the Applications folder."
    : assetName.endsWith(".zip")
      ? "Unzip the download and move Burnbar.app into the Applications folder."
      : "Open the .dmg (or unzip the .zip) and move Burnbar.app into the Applications folder.";

  // Download trust signals (issue #178): version/date/size/checksum/signing.
  // Every value degrades gracefully — when the release API fell back or an
  // older asset lacks a digest, we omit the row or link to the release page
  // instead of ever rendering "undefined"/"NaN".
  const releaseDate = formatReleaseDate(release.publishedAt);
  const fileName = release.recommendedAsset?.name ?? null;
  const fileSize = release.recommendedAsset
    ? formatFileSize(release.recommendedAsset.size)
    : null;
  const sha256 = release.recommendedAsset
    ? parseSha256(release.recommendedAsset.digest)
    : null;
  const signingStatus = IS_NOTARIZED
    ? "Signed & notarized (Apple Developer ID)."
    : "Ad-hoc signed — notarization in progress. Right-click → Open on first launch.";
  // The specific release page; resolver falls back to /releases/latest.
  const releaseNotesUrl = release.htmlUrl;

  return (
    <div className="flex min-h-screen flex-col">
      <header>
        <nav
          aria-label="Primary"
          className="mx-auto flex max-w-5xl items-center justify-between px-6 py-5"
        >
          <span className="text-lg font-semibold tracking-tight text-orange-500">
            Burnbar
          </span>
          <div className="flex items-center gap-6 text-sm">
            <Link
              href="/leaderboard"
              className="flex items-center gap-2 text-zinc-400 transition-colors hover:text-zinc-100"
            >
              Leaderboard
              <span className="rounded-full border border-zinc-700 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-zinc-500">
                {LEADERBOARD_ROLLING_OUT_SHORT}
              </span>
            </Link>
            <a
              href={release.downloadUrl}
              {...(release.isDirectDownload ? { download: "" } : {})}
              className="rounded-md bg-orange-500 px-3 py-1.5 font-medium text-zinc-950 transition-colors hover:bg-orange-400"
            >
              Download
            </a>
          </div>
        </nav>
      </header>

      <main className="mx-auto w-full max-w-5xl flex-1 px-6">
        <section
          aria-labelledby="hero-heading"
          className="flex flex-col items-center gap-6 py-24 text-center sm:py-32"
        >
          <p className="rounded-full border border-zinc-800 px-3 py-1 text-xs font-medium uppercase tracking-wide text-zinc-400">
            Native macOS menu bar · Open source · Free
          </p>
          <h1
            id="hero-heading"
            className="max-w-3xl text-balance text-4xl font-bold tracking-tight text-zinc-50 sm:text-6xl"
          >
            Track your AI-coding token burn. Privately.
          </h1>
          <p className="max-w-2xl text-lg text-zinc-300 sm:text-xl">
            Claude Code and OpenAI Codex burn real tokens and real dollars — you
            just can’t see how much. Burnbar puts the number in your menu bar,
            read straight from the local CLI logs on your Mac. Never your
            browser, never your Keychain, never your code.
          </p>
          <div className="mt-2 flex flex-col items-center gap-4 sm:flex-row">
            <a
              href={release.downloadUrl}
              {...(release.isDirectDownload ? { download: "" } : {})}
              className="rounded-md bg-orange-500 px-6 py-3 text-base font-semibold text-zinc-950 transition-colors hover:bg-orange-400"
            >
              {downloadLabel}
            </a>
            <Link
              href="/leaderboard"
              className="flex items-center gap-2 rounded-md border border-zinc-700 px-6 py-3 text-base font-semibold text-zinc-100 transition-colors hover:border-zinc-500"
            >
              View the leaderboard
              <span className="rounded-full border border-zinc-700 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-zinc-400">
                {LEADERBOARD_ROLLING_OUT_SHORT}
              </span>
            </Link>
          </div>
          <p className="text-sm text-zinc-500">
            macOS 14+ ·{" "}
            <a
              href={RELEASES_URL}
              className="underline underline-offset-2 transition-colors hover:text-zinc-300"
            >
              View all releases
            </a>
          </p>
        </section>

        <section
          aria-labelledby="problem-heading"
          className="border-t border-zinc-900 py-20"
        >
          <h2
            id="problem-heading"
            className="text-2xl font-bold tracking-tight text-zinc-50 sm:text-3xl"
          >
            Most trackers spy to count
          </h2>
          <p className="mt-4 max-w-2xl text-zinc-300">
            There’s an easy way to see your AI usage, and a right way. The easy
            way reads your browser cookies and digs through your Keychain.
            Burnbar refuses to.
          </p>
          <div className="mt-10 grid gap-6 sm:grid-cols-3">
            {PILLARS.map((pillar) => (
              <div
                key={pillar.title}
                className="rounded-xl border border-zinc-800 bg-zinc-900/40 p-6"
              >
                <span
                  aria-hidden="true"
                  className="inline-flex h-10 w-10 items-center justify-center rounded-full bg-orange-500/10 text-xl"
                >
                  {pillar.emoji}
                </span>
                <h3 className="mt-4 text-lg font-semibold text-zinc-100">
                  {pillar.title}
                </h3>
                <p className="mt-2 text-sm leading-relaxed text-zinc-400">
                  {pillar.body}
                </p>
              </div>
            ))}
          </div>
        </section>

        <section
          aria-labelledby="compare-heading"
          className="border-t border-zinc-900 py-20"
        >
          <h2
            id="compare-heading"
            className="text-2xl font-bold tracking-tight text-zinc-50 sm:text-3xl"
          >
            Burnbar vs. browser-based trackers
          </h2>
          <p className="mt-4 max-w-2xl text-zinc-300">
            Same glanceable menu-bar number. A completely different deal with
            your privacy.
          </p>
          <div className="mt-10 overflow-x-auto rounded-xl border border-zinc-800 bg-zinc-900/40">
            <table className="w-full border-collapse text-left text-sm">
              <thead>
                <tr className="border-b border-zinc-800">
                  <th scope="col" className="px-6 py-4 font-medium text-zinc-400">
                    <span className="sr-only">Capability</span>
                  </th>
                  <th
                    scope="col"
                    className="px-4 py-4 text-center font-semibold text-orange-400"
                  >
                    Burnbar
                  </th>
                  <th
                    scope="col"
                    className="px-4 py-4 text-center font-medium text-zinc-400"
                  >
                    Browser-based trackers
                  </th>
                </tr>
              </thead>
              <tbody>
                {COMPARISON.map((row) => (
                  <tr
                    key={row.label}
                    className="border-b border-zinc-900 last:border-b-0"
                  >
                    <th
                      scope="row"
                      className="px-6 py-4 font-normal text-zinc-200"
                    >
                      {row.label}
                    </th>
                    <td className="px-4 py-4 text-center">
                      <Mark value={row.burnbar} />
                    </td>
                    <td className="px-4 py-4 text-center">
                      <Mark value={row.others} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="mt-4 max-w-2xl text-xs text-zinc-500">
            * Your usage never leaves your Mac apart from the optional daily
            leaderboard summary, which uploads only if you opt in.
          </p>
        </section>

        <section
          aria-labelledby="how-it-works-heading"
          className="border-t border-zinc-900 py-20"
        >
          <h2
            id="how-it-works-heading"
            className="text-2xl font-bold tracking-tight text-zinc-50 sm:text-3xl"
          >
            How it works
          </h2>
          <ol className="mt-10 grid gap-6 sm:grid-cols-3">
            {STEPS.map((step, index) => (
              <li
                key={step.title}
                className="rounded-xl border border-zinc-800 bg-zinc-900/40 p-6"
              >
                <span
                  aria-hidden="true"
                  className="inline-flex h-8 w-8 items-center justify-center rounded-full bg-orange-500/10 text-sm font-bold text-orange-400"
                >
                  {index + 1}
                </span>
                <h3 className="mt-4 text-lg font-semibold text-zinc-100">
                  {step.title}
                </h3>
                <p className="mt-2 text-sm leading-relaxed text-zinc-400">
                  {step.body}
                </p>
              </li>
            ))}
          </ol>
        </section>

        {/*
          App-preview gallery (issue #177). ASSET-GATED: renders only when
          HAS_SCREENSHOTS is true AND at least one screenshot is marked
          available. While false (the default), this whole section renders
          nothing, so the live page is unaffected and there are no broken
          images. Flip HAS_SCREENSHOTS once real PNGs land in
          public/screenshots/ — see that folder's README.

          Uses plain <img> (not next/image) with explicit width/height +
          loading="lazy": this keeps the page a fully static export under the
          next-on-pages / Cloudflare setup (no image-optimization loader), while
          still reserving layout space to keep CLS at zero. The responsive grid
          stacks to one column on mobile so nothing clips.
        */}
        {HAS_SCREENSHOTS && SCREENSHOTS.some((s) => s.available) && (
          <section
            aria-labelledby="preview-heading"
            className="border-t border-zinc-900 py-20"
          >
            <h2
              id="preview-heading"
              className="text-2xl font-bold tracking-tight text-zinc-50 sm:text-3xl"
            >
              See Burnbar in action
            </h2>
            <p className="mt-4 max-w-2xl text-zinc-300">
              A native menu-bar app — here’s exactly what shows up on your Mac.
            </p>
            <div className="mt-10 grid grid-cols-1 gap-6 sm:grid-cols-2">
              {SCREENSHOTS.filter((s) => s.available).map((shot) => (
                <figure
                  key={shot.src}
                  className={`overflow-hidden rounded-xl border border-zinc-800 bg-zinc-900/40 ${
                    shot.wide ? "sm:col-span-2" : ""
                  }`}
                >
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img
                    src={shot.src}
                    alt={shot.alt}
                    width={shot.width}
                    height={shot.height}
                    loading="lazy"
                    decoding="async"
                    className="h-auto w-full"
                  />
                  <figcaption className="border-t border-zinc-800 px-5 py-3 text-sm text-zinc-400">
                    {shot.caption}
                  </figcaption>
                </figure>
              ))}
            </div>
          </section>
        )}

        <section
          aria-labelledby="privacy-heading"
          className="border-t border-zinc-900 py-20"
        >
          <h2
            id="privacy-heading"
            className="text-2xl font-bold tracking-tight text-zinc-50 sm:text-3xl"
          >
            The privacy promise
          </h2>
          <p className="mt-4 max-w-2xl text-zinc-300">
            Privacy is the whole point. Burnbar measures your usage without ever
            seeing what you build.
          </p>
          <dl className="mt-10 grid gap-6 sm:grid-cols-2">
            {PROMISES.map((promise) => (
              <div
                key={promise.label}
                className="rounded-xl border border-zinc-800 bg-zinc-900/40 p-6"
              >
                <dt className="text-base font-semibold text-zinc-100">
                  {promise.label}
                </dt>
                <dd className="mt-2 text-sm leading-relaxed text-zinc-400">
                  {promise.body}
                </dd>
              </div>
            ))}
          </dl>
        </section>

        <section
          aria-labelledby="install-heading"
          className="border-t border-zinc-900 py-20"
        >
          <h2
            id="install-heading"
            className="text-2xl font-bold tracking-tight text-zinc-50 sm:text-3xl"
          >
            Installing Burnbar
          </h2>
          <p className="mt-4 max-w-2xl text-zinc-300">
            Requires {MIN_MACOS} or later. Burnbar lives in your menu bar — there
            is no Dock icon, so after launch look for it up top, next to the
            clock.
          </p>
          <ol className="mt-10 flex flex-col gap-4">
            <li className="flex gap-4 rounded-xl border border-zinc-800 bg-zinc-900/40 p-5">
              <span
                aria-hidden="true"
                className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-orange-500/10 text-sm font-bold text-orange-400"
              >
                1
              </span>
              <div>
                <h3 className="text-base font-semibold text-zinc-100">
                  Download Burnbar
                </h3>
                <p className="mt-1 text-sm leading-relaxed text-zinc-400">
                  Grab the latest macOS build using the Download button above.
                </p>
              </div>
            </li>
            <li className="flex gap-4 rounded-xl border border-zinc-800 bg-zinc-900/40 p-5">
              <span
                aria-hidden="true"
                className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-orange-500/10 text-sm font-bold text-orange-400"
              >
                2
              </span>
              <div>
                <h3 className="text-base font-semibold text-zinc-100">
                  Move it to Applications
                </h3>
                <p className="mt-1 text-sm leading-relaxed text-zinc-400">
                  {unpackStep}
                </p>
              </div>
            </li>
            {/*
              Gatekeeper note — gated on IS_NOTARIZED. This step renders only
              while the build is NOT notarized. After notarization ships
              (issue #167), flip IS_NOTARIZED to true and this whole step
              disappears; the steps above stay.
            */}
            {!IS_NOTARIZED && (
              <li className="flex gap-4 rounded-xl border border-zinc-800 bg-zinc-900/40 p-5">
                <span
                  aria-hidden="true"
                  className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-orange-500/10 text-sm font-bold text-orange-400"
                >
                  3
                </span>
                <div>
                  <h3 className="text-base font-semibold text-zinc-100">
                    Open it the first time
                  </h3>
                  <p className="mt-1 text-sm leading-relaxed text-zinc-400">
                    Right-click (or Control-click) Burnbar.app in Applications and
                    choose <span className="text-zinc-200">Open</span>, then
                    confirm in the dialog. This one-time step is needed because
                    this build isn’t notarized by Apple yet — after that, launch
                    it normally.
                  </p>
                </div>
              </li>
            )}
          </ol>

          {/*
            Download trust signals (issue #178). A compact, glanceable panel so
            users can verify what they're about to run: version + date, file
            size, SHA-256 (or a link to the release assets when the digest is
            absent), signing/notarization status, and release-notes/source
            links. Every field is rendered conditionally — nothing here ever
            shows "undefined"/"NaN" when the release API fell back.
          */}
          <dl className="mt-8 grid gap-x-8 gap-y-5 rounded-xl border border-zinc-800 bg-zinc-900/40 p-6 sm:grid-cols-2">
            <div>
              <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500">
                Version
              </dt>
              <dd className="mt-1 text-sm text-zinc-200">
                {release.version ? (
                  <>
                    <span className="font-semibold text-zinc-100">
                      {release.version}
                    </span>
                    {releaseDate ? (
                      <span className="text-zinc-400">
                        {" "}
                        · released {releaseDate}
                      </span>
                    ) : null}
                  </>
                ) : (
                  <a
                    href={RELEASES_LATEST_URL}
                    className="underline underline-offset-2 transition-colors hover:text-zinc-100"
                  >
                    See the latest release
                  </a>
                )}
              </dd>
            </div>

            <div>
              <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500">
                Download size
              </dt>
              <dd className="mt-1 text-sm text-zinc-200">
                {fileSize ? (
                  <>
                    <span className="font-semibold text-zinc-100">
                      {fileSize}
                    </span>
                    {fileName ? (
                      <span className="break-all text-zinc-400"> · {fileName}</span>
                    ) : null}
                  </>
                ) : (
                  <a
                    href={RELEASES_LATEST_URL}
                    className="underline underline-offset-2 transition-colors hover:text-zinc-100"
                  >
                    See the release assets
                  </a>
                )}
              </dd>
            </div>

            <div className="sm:col-span-2">
              <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500">
                SHA-256 checksum
              </dt>
              <dd className="mt-1 text-sm text-zinc-200">
                {sha256 ? (
                  <code className="block break-all rounded-md bg-zinc-950/70 px-3 py-2 font-mono text-xs text-zinc-300">
                    {sha256}
                  </code>
                ) : (
                  <span className="text-zinc-400">
                    Verify against the checksum listed on the{" "}
                    <a
                      href={releaseNotesUrl}
                      className="underline underline-offset-2 transition-colors hover:text-zinc-100"
                    >
                      release page
                    </a>
                    .
                  </span>
                )}
              </dd>
            </div>

            <div className="sm:col-span-2">
              <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500">
                Signing
              </dt>
              <dd className="mt-1 text-sm text-zinc-300">{signingStatus}</dd>
            </div>

            <div className="sm:col-span-2">
              <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500">
                Verify the source
              </dt>
              <dd className="mt-2 flex flex-wrap gap-x-5 gap-y-2 text-sm">
                <a
                  href={releaseNotesUrl}
                  className="text-zinc-300 underline underline-offset-2 transition-colors hover:text-zinc-100"
                >
                  Release notes
                </a>
                <a
                  href={SOURCE_URL}
                  className="text-zinc-300 underline underline-offset-2 transition-colors hover:text-zinc-100"
                >
                  View source on GitHub
                </a>
              </dd>
            </div>
          </dl>
        </section>

        <section
          aria-labelledby="download-heading"
          className="border-t border-zinc-900 py-20"
        >
          <div className="flex flex-col items-center gap-6 rounded-2xl border border-zinc-800 bg-zinc-900/40 px-6 py-16 text-center">
            <h2
              id="download-heading"
              className="text-2xl font-bold tracking-tight text-zinc-50 sm:text-3xl"
            >
              See where your tokens go
            </h2>
            <p className="max-w-xl text-zinc-300">
              Free and open source. See where your tokens go — without giving up
              your privacy.
            </p>
            <a
              href={release.downloadUrl}
              {...(release.isDirectDownload ? { download: "" } : {})}
              className="rounded-md bg-orange-500 px-6 py-3 text-base font-semibold text-zinc-950 transition-colors hover:bg-orange-400"
            >
              {downloadLabel}
            </a>
            <a
              href={RELEASES_URL}
              className="text-sm text-zinc-500 underline underline-offset-2 transition-colors hover:text-zinc-300"
            >
              View all releases
            </a>
          </div>
        </section>
      </main>

      <footer className="border-t border-zinc-900">
        <div className="mx-auto flex max-w-5xl flex-col items-center justify-between gap-3 px-6 py-8 text-sm text-zinc-500 sm:flex-row">
          <p>Burnbar — token tracking for Claude Code and OpenAI Codex.</p>
          <a
            href="https://github.com/AndyBoWu/Burnbar"
            className="transition-colors hover:text-zinc-300"
          >
            GitHub
          </a>
        </div>
      </footer>
    </div>
  );
}
