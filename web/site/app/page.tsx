import type { Metadata } from "next";
import Link from "next/link";

const RELEASES_URL = "https://github.com/AndyBoWu/Burnbar/releases";

export const metadata: Metadata = {
  title: "Burnbar — Track AI-coding token burn in your menu bar",
  description:
    "Burnbar is a native macOS menu-bar app that tracks your Claude Code and OpenAI Codex token usage by reading only local CLI logs. No browser data, no third-party Keychain access.",
};

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

export default function HomePage() {
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
              href={RELEASES_URL}
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
            Native macOS menu-bar app
          </p>
          <h1
            id="hero-heading"
            className="max-w-3xl text-balance text-4xl font-bold tracking-tight text-zinc-50 sm:text-6xl"
          >
            Track AI-coding token burn in your menu bar
          </h1>
          <p className="max-w-2xl text-lg text-zinc-300 sm:text-xl">
            Burnbar shows exactly how many tokens and dollars your Claude Code
            and OpenAI Codex sessions cost — built from the logs already on your
            Mac.
          </p>
          <div className="mt-2 flex flex-col items-center gap-4 sm:flex-row">
            <a
              href={RELEASES_URL}
              className="rounded-md bg-orange-500 px-6 py-3 text-base font-semibold text-zinc-950 transition-colors hover:bg-orange-400"
            >
              Download for macOS
            </a>
            <Link
              href="/leaderboard"
              className="rounded-md border border-zinc-700 px-6 py-3 text-base font-semibold text-zinc-100 transition-colors hover:border-zinc-500"
            >
              View the leaderboard
            </Link>
          </div>
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
              Free and open source. Download the latest build and start tracking
              in minutes.
            </p>
            <a
              href={RELEASES_URL}
              className="rounded-md bg-orange-500 px-6 py-3 text-base font-semibold text-zinc-950 transition-colors hover:bg-orange-400"
            >
              Download for macOS
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
