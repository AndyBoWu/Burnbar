import type { Metadata } from "next";
import Link from "next/link";

import { LEADERBOARD_ROLLING_OUT } from "@/app/lib/api";

const PRIVACY_TITLE = "Privacy Policy — Burnbar";
const PRIVACY_DESCRIPTION =
  "What Burnbar collects, what it never touches, how long data is kept, and how to opt out or delete everything.";

export const metadata: Metadata = {
  title: PRIVACY_TITLE,
  description: PRIVACY_DESCRIPTION,
  // Self-canonical so this page is not collapsed under the site root.
  alternates: {
    canonical: "/privacy",
  },
  openGraph: {
    title: PRIVACY_TITLE,
    description: PRIVACY_DESCRIPTION,
    url: "/privacy",
  },
  twitter: {
    title: PRIVACY_TITLE,
    description: PRIVACY_DESCRIPTION,
  },
};

// Static page — no data fetching, fully prerendered at build time.
export const dynamic = "force-static";

// Single source of truth for the contact channel so it stays consistent.
const REPO_URL = "https://github.com/AndyBoWu/Burnbar";
const ISSUES_URL = `${REPO_URL}/issues`;
const CONTACT_EMAIL = "bwu2sfu@gmail.com";

// Reflects the upload payload accepted by the Worker's validateUsage()
// allowlist (web/src/app.ts) plus the GitHub identity stored in the users
// table (web/migrations/0001_create_users.sql).
const COLLECTED: { field: string; detail: string }[] = [
  {
    field: "date",
    detail: "The calendar day a usage total belongs to (YYYY-MM-DD).",
  },
  {
    field: "provider",
    detail: 'Which CLI the usage came from — only "claude" or "codex".',
  },
  {
    field: "tokens",
    detail: "A single aggregate token count for that day and provider.",
  },
  {
    field: "cost_usd",
    detail: "The estimated US-dollar cost for that day and provider.",
  },
  {
    field: "github_id / github_login",
    detail:
      "Your public GitHub numeric id and username, used only to identify your row on the leaderboard.",
  },
];

// Mirrors docs/data-sources.md "What Burnbar never reads (everywhere)" and the
// server-side privacy gate in web/src/app.ts (validateUsage rejects any key
// outside the four-field allowlist).
const NEVER_COLLECTED: { title: string; detail: string }[] = [
  {
    title: "Prompt and response content",
    detail:
      "Never. We skip message.content / message.text, first_user_message, preview, title, and history.jsonl entirely. The text of what you ask or what the models reply is never read, stored, or uploaded.",
  },
  {
    title: "Filesystem and repository identifiers",
    detail:
      "Never. We never upload cwd (working directory), git_branch, git_origin_url, git_sha, project directory names, or rollout paths.",
  },
  {
    title: "Machine identifiers",
    detail:
      "Never. Cross-device totals are reconciled on your Mac before upload, so per-machine ids never leave your device and never reach the leaderboard.",
  },
  {
    title: "Raw model names",
    detail:
      "Never. The upload carries a single per-provider token total, not which specific model (for example a dated Opus or Sonnet build) produced it.",
  },
  {
    title: "Browser data",
    detail:
      "Never. Burnbar does not read browser cookies, Local Storage, IndexedDB, or any browser-managed secrets. This is the core reason Burnbar exists.",
  },
  {
    title: "Third-party Keychain items",
    detail:
      "Never. Burnbar uses the macOS Keychain only for its own GitHub token (service ids prefixed xyz.andybowu.Burnbar). It never touches any other app's Keychain items.",
  },
];

export default function PrivacyPage() {
  return (
    <main className="mx-auto max-w-3xl px-6 py-16">
      <article className="prose-invert">
        <header className="mb-12 border-b border-zinc-800 pb-8">
          <p className="mb-2 text-sm font-medium uppercase tracking-widest text-orange-500">
            Burnbar
          </p>
          <h1 className="text-4xl font-bold tracking-tight text-zinc-50">
            Privacy Policy
          </h1>
          <p className="mt-4 text-lg leading-relaxed text-zinc-400">
            Burnbar exists because measuring AI token usage should not require
            handing over your prompts, your code, or your browser secrets. This
            page states exactly what we collect, what we never touch, how long
            anything is kept, and how to remove it. Every claim here is reviewed
            against the actual upload, storage, and retention code.
          </p>
          <p className="mt-3 text-sm text-zinc-500">Last updated: May 2026</p>
        </header>

        <section aria-labelledby="collect-heading" className="mb-12">
          <h2
            id="collect-heading"
            className="mb-3 text-2xl font-semibold text-zinc-50"
          >
            What we collect
          </h2>
          <p className="mb-6 leading-relaxed text-zinc-300">
            Burnbar runs entirely on your Mac. The only data that would ever leave
            your machine is a small daily usage rollup you upload to the
            leaderboard after you opt in. {LEADERBOARD_ROLLING_OUT} This is the
            upload model it will use once live — that upload contains exactly
            these fields and nothing else, and the server rejects any extra key:
          </p>
          <dl className="space-y-4">
            {COLLECTED.map(({ field, detail }) => (
              <div
                key={field}
                className="rounded-lg border border-zinc-800 bg-zinc-900/40 p-4"
              >
                <dt className="font-mono text-sm font-semibold text-orange-400">
                  {field}
                </dt>
                <dd className="mt-1 text-sm leading-relaxed text-zinc-400">
                  {detail}
                </dd>
              </div>
            ))}
          </dl>
          <p className="mt-6 leading-relaxed text-zinc-300">
            The leaderboard supports two providers only — Claude Code and OpenAI
            Codex. No other tool is read or uploaded.
          </p>
        </section>

        <section aria-labelledby="never-heading" className="mb-12">
          <h2
            id="never-heading"
            className="mb-3 text-2xl font-semibold text-zinc-50"
          >
            What we never collect
          </h2>
          <p className="mb-6 leading-relaxed text-zinc-300">
            The following are never read, never stored, and never uploaded. This
            is enforced in code: Burnbar parses only token counts, models, and
            timestamps from local CLI logs, and the leaderboard server validates
            every upload against a strict four-field allowlist before it is
            saved.
          </p>
          <ul className="space-y-4">
            {NEVER_COLLECTED.map(({ title, detail }) => (
              <li
                key={title}
                className="rounded-lg border border-zinc-800 bg-zinc-900/40 p-4"
              >
                <p className="font-semibold text-zinc-100">{title}</p>
                <p className="mt-1 text-sm leading-relaxed text-zinc-400">
                  {detail}
                </p>
              </li>
            ))}
          </ul>
        </section>

        <section aria-labelledby="retention-heading" className="mb-12">
          <h2
            id="retention-heading"
            className="mb-3 text-2xl font-semibold text-zinc-50"
          >
            Retention
          </h2>
          <div className="space-y-4 leading-relaxed text-zinc-300">
            <p>
              <span className="font-semibold text-zinc-100">
                If you are opted in
              </span>{" "}
              to the public leaderboard, your daily usage rollups are retained
              indefinitely so your historical ranking stays intact.
            </p>
            <p>
              <span className="font-semibold text-zinc-100">
                If you are opted out
              </span>
              , any usage rows are automatically purged once they are older than
              90 days. A daily job removes opted-out data past that window, so
              opted-out usage never persists beyond about three months.
            </p>
            <p>
              You can delete everything immediately at any time — see below.
            </p>
          </div>
        </section>

        <section aria-labelledby="control-heading" className="mb-12">
          <h2
            id="control-heading"
            className="mb-3 text-2xl font-semibold text-zinc-50"
          >
            Opt out, hide, or delete your data
          </h2>
          <p className="mb-6 leading-relaxed text-zinc-300">
            You are in control from inside the Burnbar app. Nothing is uploaded
            until you choose to join the leaderboard.
          </p>
          <ul className="space-y-4">
            <li className="rounded-lg border border-zinc-800 bg-zinc-900/40 p-4">
              <p className="font-semibold text-zinc-100">Opt out</p>
              <p className="mt-1 text-sm leading-relaxed text-zinc-400">
                Turn off the leaderboard in Settings. Burnbar stops uploading and
                your existing data falls under the 90-day opted-out purge.
              </p>
            </li>
            <li className="rounded-lg border border-zinc-800 bg-zinc-900/40 p-4">
              <p className="font-semibold text-zinc-100">Hide</p>
              <p className="mt-1 text-sm leading-relaxed text-zinc-400">
                Stay opted in but mark yourself hidden to disappear from the
                public ranking while keeping your own history.
              </p>
            </li>
            <li className="rounded-lg border border-zinc-800 bg-zinc-900/40 p-4">
              <p className="font-semibold text-zinc-100">Delete everything</p>
              <p className="mt-1 text-sm leading-relaxed text-zinc-400">
                Use the delete control in Settings to wipe your account and every
                usage row immediately, regardless of age or opt-in status.
              </p>
            </li>
          </ul>
        </section>

        <section aria-labelledby="contact-heading">
          <h2
            id="contact-heading"
            className="mb-3 text-2xl font-semibold text-zinc-50"
          >
            Contact
          </h2>
          <p className="leading-relaxed text-zinc-300">
            Questions about your data or this policy? Open an issue on{" "}
            <a
              href={ISSUES_URL}
              className="font-medium text-orange-400 underline underline-offset-4 hover:text-orange-300"
            >
              GitHub
            </a>{" "}
            or email{" "}
            <a
              href={`mailto:${CONTACT_EMAIL}`}
              className="font-medium text-orange-400 underline underline-offset-4 hover:text-orange-300"
            >
              {CONTACT_EMAIL}
            </a>
            . Burnbar is open source — you can read the exact upload, storage,
            and retention code in the{" "}
            <a
              href={REPO_URL}
              className="font-medium text-orange-400 underline underline-offset-4 hover:text-orange-300"
            >
              repository
            </a>
            .
          </p>
          <p className="mt-10 border-t border-zinc-800 pt-6 text-sm text-zinc-500">
            <Link
              href="/"
              className="text-zinc-400 underline underline-offset-4 hover:text-zinc-200"
            >
              Back to Burnbar
            </Link>
          </p>
        </section>
      </article>
    </main>
  );
}
