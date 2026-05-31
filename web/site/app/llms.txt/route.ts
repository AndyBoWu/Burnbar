const SITE_URL = "https://burnbar.andybowu.xyz";
const REPO_URL = "https://github.com/AndyBoWu/Burnbar";

const LLMS_TXT = `# Burnbar

> Burnbar is an open-source native macOS menu-bar app for tracking Claude Code and OpenAI Codex token usage from local CLI logs, with an opt-in public leaderboard.

Burnbar reads local usage logs under ~/.claude and ~/.codex to calculate token and estimated cost totals. The app never reads prompts, responses, source code, browser data, project paths, git data, machine IDs, or third-party Keychain items.

Public crawl surface: landing page, leaderboard period pages, privacy policy, GitHub repository, and releases. Individual /u/{login} profile routes are intentionally excluded from robots.txt and from this file because they are user-generated and may be hidden or opted out.

## Public pages

- [Burnbar landing page](${SITE_URL}/): Overview, download links, privacy promises, and how the macOS app works.
- [Daily leaderboard](${SITE_URL}/leaderboard/daily): Public opt-in token usage ranking for today.
- [Weekly leaderboard](${SITE_URL}/leaderboard/weekly): Public opt-in token usage ranking for this week.
- [Monthly leaderboard](${SITE_URL}/leaderboard/monthly): Public opt-in token usage ranking for this month.
- [Privacy policy](${SITE_URL}/privacy): What Burnbar collects, what it never reads, retention, opt-out, hide, and delete controls.

## Project

- [GitHub repository](${REPO_URL}): Source code for the macOS app, leaderboard API, and public site.
- [Releases](${REPO_URL}/releases): Downloadable macOS builds.

## Optional

- [Sitemap](${SITE_URL}/sitemap.xml): XML list of indexable public routes.
- [Robots policy](${SITE_URL}/robots.txt): Crawler policy; allows public pages and disallows /u/.
`;

export const dynamic = "force-static";

export function GET() {
  return new Response(LLMS_TXT, {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "public, max-age=3600, s-maxage=86400",
    },
  });
}
