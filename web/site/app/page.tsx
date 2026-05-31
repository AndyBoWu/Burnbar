import type { Metadata } from "next";
import Link from "next/link";

import { getLatestRelease, RELEASES_URL } from "@/app/lib/release";

const LANDING_TITLE = "Burnbar — Track AI-coding token burn in your menu bar";
const LANDING_DESCRIPTION =
  "Burnbar is a native macOS menu-bar app that tracks your Claude Code and OpenAI Codex token usage by reading only local CLI logs. No browser data, no third-party Keychain access.";

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
    body: "Choose to share, and Burnbar uploads a tiny daily summary to climb the global leaderboard. Off by default, and you decide every time.",
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
    body: "If you join the leaderboard, Burnbar sends only { date, provider, tokens, cost } — no prompts, paths, project names, machine ids, or raw model names.",
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
              className="text-zinc-400 transition-colors hover:text-zinc-100"
            >
              Leaderboard
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
              className="rounded-md border border-zinc-700 px-6 py-3 text-base font-semibold text-zinc-100 transition-colors hover:border-zinc-500"
            >
              View the leaderboard
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
