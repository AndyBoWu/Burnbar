import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import {
  getProfile,
  NOT_CONFIGURED,
  PROFILE_HISTORY_DAYS,
  type ProfilePoint,
  type PublicProfile,
} from "@/app/lib/api";

// Dynamic per-login route (no generateStaticParams), so it runs on Cloudflare
// Pages' Edge Runtime rather than being prerendered. Required by next-on-pages.
export const runtime = "edge";

// Refresh each profile every 5 minutes (matches the fetch revalidation).
export const revalidate = 300;

const numberFmt = new Intl.NumberFormat("en-US");
const usdFmt = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
});
const dateFmt = new Intl.DateTimeFormat("en-US", {
  month: "short",
  day: "numeric",
  timeZone: "UTC",
});

export function generateMetadata({
  params,
}: {
  params: { login: string };
}): Metadata {
  // Public identity only — the GitHub login is already public on GitHub.
  return {
    title: `${params.login} — Burnbar`,
    description: `Public ${PROFILE_HISTORY_DAYS}-day token burn for ${params.login} on the Burnbar leaderboard.`,
  };
}

export default async function ProfilePage({
  params,
}: {
  params: { login: string };
}) {
  const profile = await getProfile(params.login);

  // Pre-deploy: no real API origin configured yet. Show the intentional
  // "coming soon" state rather than the generic error or a misleading 404.
  if (profile === NOT_CONFIGURED) {
    return (
      <main className="mx-auto flex min-h-screen max-w-3xl flex-col gap-8 px-6 py-12">
        <p className="rounded-lg border border-zinc-800 bg-zinc-900/40 px-4 py-6 text-center text-zinc-400">
          Public profiles are rolling out soon. Check back once the leaderboard
          is live.
        </p>
      </main>
    );
  }

  // Hidden / opted-out / unknown users → a real 404 with no history rendered.
  if (profile === "not-found") notFound();

  // Network / shape error: distinct from 404 so we don't mask outages as "hidden".
  if (profile === null) {
    return (
      <main className="mx-auto flex min-h-screen max-w-3xl flex-col gap-8 px-6 py-12">
        <p className="rounded-lg border border-red-900/60 bg-red-950/40 px-4 py-6 text-center text-red-300">
          Couldn&apos;t load this profile right now. Please try again later.
        </p>
      </main>
    );
  }

  return (
    <main className="mx-auto flex min-h-screen max-w-3xl flex-col gap-10 px-6 py-12">
      <ProfileHeader profile={profile} />
      <BurnSummary history={profile.history} />
      <footer className="text-sm">
        <Link
          href="/leaderboard/daily"
          className="text-zinc-400 underline underline-offset-4 hover:text-zinc-200"
        >
          Back to leaderboard
        </Link>
      </footer>
    </main>
  );
}

function ProfileHeader({ profile }: { profile: PublicProfile }) {
  const { totalTokens, totalCost } = totals(profile.history);
  return (
    <header className="flex flex-col gap-6 sm:flex-row sm:items-center">
      {/* GitHub avatar is public identity only; plain <img> avoids next/image
          remote-host config. eslint-disable to keep the build clean. */}
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        src={`https://github.com/${encodeURIComponent(profile.github_login)}.png`}
        alt={`${profile.github_login} avatar`}
        width={88}
        height={88}
        className="h-[88px] w-[88px] rounded-full border border-zinc-800 bg-zinc-900"
      />
      <div className="flex flex-col gap-2">
        <p className="text-sm font-medium uppercase tracking-widest text-orange-500">
          Burnbar profile
        </p>
        <h1 className="text-3xl font-bold tracking-tight text-zinc-50">
          {profile.github_login}
        </h1>
        <dl className="mt-1 flex gap-8 text-sm">
          <div>
            <dt className="text-zinc-500">
              {PROFILE_HISTORY_DAYS}-day tokens
            </dt>
            <dd className="text-lg font-semibold tabular-nums text-zinc-100">
              {numberFmt.format(totalTokens)}
            </dd>
          </div>
          <div>
            <dt className="text-zinc-500">{PROFILE_HISTORY_DAYS}-day cost</dt>
            <dd className="text-lg font-semibold tabular-nums text-zinc-100">
              {usdFmt.format(totalCost)}
            </dd>
          </div>
        </dl>
      </div>
    </header>
  );
}

function BurnSummary({ history }: { history: ProfilePoint[] }) {
  if (history.length === 0) {
    return (
      <section aria-labelledby="burn-heading" className="flex flex-col gap-4">
        <h2 id="burn-heading" className="text-xl font-semibold text-zinc-50">
          Last {PROFILE_HISTORY_DAYS} days
        </h2>
        <p className="rounded-lg border border-zinc-800 bg-zinc-900/40 px-4 py-6 text-center text-zinc-400">
          No usage in the last {PROFILE_HISTORY_DAYS} days.
        </p>
      </section>
    );
  }

  const maxTokens = Math.max(...history.map((p) => p.tokens), 1);

  return (
    <section aria-labelledby="burn-heading" className="flex flex-col gap-4">
      <h2 id="burn-heading" className="text-xl font-semibold text-zinc-50">
        Last {PROFILE_HISTORY_DAYS} days
      </h2>
      {/* Dependency-free bar list: one row per active day, width ∝ tokens. */}
      <ul className="flex flex-col gap-1.5">
        {history.map((point) => {
          const pct = Math.max(2, Math.round((point.tokens / maxTokens) * 100));
          return (
            <li
              key={point.date}
              className="flex items-center gap-3 text-sm"
              title={`${point.date}: ${numberFmt.format(point.tokens)} tokens, ${usdFmt.format(point.cost_usd)}`}
            >
              <span className="w-14 shrink-0 tabular-nums text-zinc-500">
                {dateFmt.format(new Date(`${point.date}T00:00:00Z`))}
              </span>
              <span
                className="h-3 rounded-sm bg-orange-500"
                style={{ width: `${pct}%` }}
                aria-hidden="true"
              />
              <span className="shrink-0 tabular-nums text-zinc-400">
                {numberFmt.format(point.tokens)}
              </span>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

/** Sum the public series. Carries no provider/model/path detail by construction. */
function totals(history: ProfilePoint[]): {
  totalTokens: number;
  totalCost: number;
} {
  let totalTokens = 0;
  let totalCost = 0;
  for (const point of history) {
    totalTokens += point.tokens;
    totalCost += point.cost_usd;
  }
  return { totalTokens, totalCost };
}
