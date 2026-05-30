import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";

const SITE_NAME = "Burnbar";
const SITE_DESCRIPTION =
  "The global leaderboard for Claude Code and OpenAI Codex token usage.";

export const metadata: Metadata = {
  // Absolute base for OG/Twitter image and canonical URL resolution. Required
  // for `opengraph-image` and relative `alternates` to resolve to full URLs.
  metadataBase: new URL("https://burnbar.andybowu.xyz"),
  title: "Burnbar Leaderboard",
  description: SITE_DESCRIPTION,
  applicationName: SITE_NAME,
  alternates: {
    canonical: "/",
  },
  openGraph: {
    type: "website",
    siteName: SITE_NAME,
    title: "Burnbar Leaderboard",
    description: SITE_DESCRIPTION,
    url: "/",
    // The default opengraph-image (app/opengraph-image.tsx) is attached
    // automatically by Next; per-page images override it where present.
  },
  twitter: {
    card: "summary_large_image",
    title: "Burnbar Leaderboard",
    description: SITE_DESCRIPTION,
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-zinc-950 text-zinc-100 antialiased">
        {children}
        <footer className="border-t border-zinc-900 px-6 py-6 text-center text-sm text-zinc-500">
          <Link
            href="/privacy"
            className="underline underline-offset-4 hover:text-zinc-300"
          >
            Privacy policy
          </Link>
        </footer>
      </body>
    </html>
  );
}
