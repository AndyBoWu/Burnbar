/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Bare `/leaderboard` defaults to the daily ranking. A config-level redirect
  // compiles to a real HTTP 308 in `.vercel/output/config.json`, which the
  // next-on-pages Cloudflare adapter serves directly — so non-JS clients
  // (curl, crawlers, agents) get a clean 3xx + `Location` header instead of an
  // RSC `NEXT_REDIRECT` 200 payload.
  async redirects() {
    return [
      {
        source: "/leaderboard",
        destination: "/leaderboard/daily",
        permanent: true,
      },
    ];
  },
};

export default nextConfig;
