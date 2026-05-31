import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import {
  fetchLeaderboard,
  isPeriod,
  LEADERBOARD_ROLLING_OUT,
  NOT_CONFIGURED,
  type NotConfigured,
  PERIOD_LABELS,
  PERIODS,
  type LeaderboardEntry,
  type Period,
} from "@/app/lib/api";

// Pre-render the three valid period routes; reject everything else with 404.
export function generateStaticParams(): { period: Period }[] {
  return PERIODS.map((period) => ({ period }));
}

export const dynamicParams = false;

// Refresh the ranking every 5 minutes (matches fetch revalidation).
export const revalidate = 300;

export function generateMetadata({
  params,
}: {
  params: { period: string };
}): Metadata {
  if (!isPeriod(params.period)) return { title: "Burnbar Leaderboard" };
  const title = `${PERIOD_LABELS[params.period]} leaderboard — Burnbar`;
  const description = `Top token usage for Claude Code and OpenAI Codex — ${PERIOD_LABELS[params.period].toLowerCase()}.`;
  return {
    title,
    description,
    // Period-specific canonical so each of daily/weekly/monthly is its own
    // indexable URL (and the bare /leaderboard 308 has a canonical target).
    alternates: {
      canonical: `/leaderboard/${params.period}`,
    },
    openGraph: {
      title,
      description,
      url: `/leaderboard/${params.period}`,
    },
    twitter: {
      title,
      description,
    },
  };
}

const numberFmt = new Intl.NumberFormat("en-US");
const usdFmt = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
});

export default async function LeaderboardPage({
  params,
}: {
  params: { period: string };
}) {
  const { period } = params;
  if (!isPeriod(period)) notFound();

  const entries = await fetchLeaderboard(period);

  return (
    <main className="mx-auto flex min-h-screen max-w-3xl flex-col gap-8 px-6 py-12">
      <header className="flex flex-col gap-4">
        <h1 className="text-3xl font-bold tracking-tight text-orange-500">
          Burnbar leaderboard
        </h1>
        <nav className="flex gap-2" aria-label="Leaderboard period">
          {PERIODS.map((p) => {
            const active = p === period;
            return (
              <Link
                key={p}
                href={`/leaderboard/${p}`}
                aria-current={active ? "page" : undefined}
                className={
                  active
                    ? "rounded-full bg-orange-500 px-4 py-1.5 text-sm font-semibold text-zinc-950"
                    : "rounded-full bg-zinc-800 px-4 py-1.5 text-sm font-medium text-zinc-300 hover:bg-zinc-700"
                }
              >
                {PERIOD_LABELS[p]}
              </Link>
            );
          })}
        </nav>
      </header>

      <Rankings entries={entries} />
    </main>
  );
}

function Rankings({
  entries,
}: {
  entries: LeaderboardEntry[] | NotConfigured | null;
}) {
  // Pre-deploy: no real API origin configured yet. Show the intentional
  // "coming soon" state — never the scary generic error.
  if (entries === NOT_CONFIGURED) {
    return (
      <p className="rounded-lg border border-zinc-800 bg-zinc-900/40 px-4 py-6 text-center text-zinc-400">
        {LEADERBOARD_ROLLING_OUT} Opt in from the Burnbar menu bar app and
        you&apos;ll show up here once it&apos;s live.
      </p>
    );
  }

  // Configured API but it failed (network/HTTP/shape) → genuine transient error.
  if (entries === null) {
    return (
      <p className="rounded-lg border border-red-900/60 bg-red-950/40 px-4 py-6 text-center text-red-300">
        Couldn&apos;t load the leaderboard right now. Please try again later.
      </p>
    );
  }

  if (entries.length === 0) {
    return (
      <p className="rounded-lg border border-zinc-800 bg-zinc-900/40 px-4 py-6 text-center text-zinc-400">
        No entries yet. Be the first to opt in from the Burnbar menu bar app.
      </p>
    );
  }

  return (
    <table className="w-full border-collapse text-left text-sm">
      <thead>
        <tr className="border-b border-zinc-800 text-xs uppercase tracking-wide text-zinc-500">
          <th scope="col" className="py-2 pr-4 font-medium">
            #
          </th>
          <th scope="col" className="py-2 pr-4 font-medium">
            User
          </th>
          <th scope="col" className="py-2 pr-4 text-right font-medium">
            Tokens
          </th>
          <th scope="col" className="py-2 text-right font-medium">
            Cost
          </th>
        </tr>
      </thead>
      <tbody>
        {entries.map((entry, index) => (
          <tr
            key={entry.github_login}
            className="border-b border-zinc-900 hover:bg-zinc-900/40"
          >
            <td className="py-3 pr-4 tabular-nums text-zinc-500">
              {index + 1}
            </td>
            <td className="py-3 pr-4">
              <Link
                href={`/u/${entry.github_login}`}
                className="font-medium text-zinc-100 hover:text-orange-400 hover:underline"
              >
                {entry.github_login}
              </Link>
            </td>
            <td className="py-3 pr-4 text-right tabular-nums text-zinc-300">
              {numberFmt.format(entry.tokens)}
            </td>
            <td className="py-3 text-right tabular-nums text-zinc-300">
              {usdFmt.format(entry.cost_usd)}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
