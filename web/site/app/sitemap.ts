import type { MetadataRoute } from "next";
import { PERIODS } from "@/app/lib/api";

// Canonical origin for the public site. Mirrors `metadataBase` in app/layout.tsx.
const BASE_URL = "https://burnbar.andybowu.xyz";

// Public, indexable routes only. Per-user profile routes (`/u/:login`) are
// intentionally excluded: they are user-generated, may be opted out (Epic 3.5.1),
// and exposing them here would leak the member list. The bare `/leaderboard`
// route just 308s to `/leaderboard/daily`, so we list the canonical period URLs.
export default function sitemap(): MetadataRoute.Sitemap {
  const now = new Date();

  const leaderboard: MetadataRoute.Sitemap = PERIODS.map((period) => ({
    url: `${BASE_URL}/leaderboard/${period}`,
    lastModified: now,
    changeFrequency: "hourly",
    priority: 0.8,
  }));

  return [
    {
      url: BASE_URL,
      lastModified: now,
      changeFrequency: "weekly",
      priority: 1,
    },
    ...leaderboard,
    {
      url: `${BASE_URL}/privacy`,
      lastModified: now,
      changeFrequency: "monthly",
      priority: 0.5,
    },
  ];
}
