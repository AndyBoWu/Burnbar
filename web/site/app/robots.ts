import type { MetadataRoute } from "next";

// Canonical origin for the public site. Mirrors `metadataBase` in app/layout.tsx.
const BASE_URL = "https://burnbar.andybowu.xyz";

// Allow crawling of the public landing + leaderboard pages. Disallow per-user
// profile routes (`/u/*`): they are user-generated and may be opted out
// (Epic 3.5.1), so they must not be indexed. The sitemap advertises only the
// indexable routes.
export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: "*",
      allow: "/",
      disallow: ["/u/"],
    },
    sitemap: `${BASE_URL}/sitemap.xml`,
    host: BASE_URL,
  };
}
