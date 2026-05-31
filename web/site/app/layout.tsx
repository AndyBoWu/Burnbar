import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";

const SITE_NAME = "Burnbar";
const SITE_URL = "https://burnbar.andybowu.xyz";
const REPO_URL = "https://github.com/AndyBoWu/Burnbar";
const RELEASES_URL = `${REPO_URL}/releases`;
// Neutral, product-accurate default. Used as the site-wide title and as the
// OG/Twitter fallback for any page that doesn't set its own. Pages that do set
// their own title/OG (landing, privacy, leaderboard, profiles) override these —
// so the default must describe the product itself, not the leaderboard alone.
// Previously this was "Burnbar Leaderboard", which leaked onto the landing and
// privacy pages' social previews.
const SITE_TITLE = "Burnbar — Track AI-coding token burn in your menu bar";
const SITE_DESCRIPTION =
  "Burnbar is a privacy-first native macOS menu-bar app that tracks your Claude Code and OpenAI Codex token usage by reading only local CLI logs.";
const STRUCTURED_DATA = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "WebSite",
      "@id": `${SITE_URL}/#website`,
      name: SITE_NAME,
      url: `${SITE_URL}/`,
      description: SITE_DESCRIPTION,
      inLanguage: "en",
      about: { "@id": `${SITE_URL}/#software` },
      hasPart: [
        {
          "@type": "WebPage",
          "@id": `${SITE_URL}/#homepage`,
          url: `${SITE_URL}/`,
          name: "Burnbar",
          description:
            "Overview, download links, privacy promises, and how the macOS app works.",
        },
        {
          "@type": "CollectionPage",
          "@id": `${SITE_URL}/leaderboard/daily#webpage`,
          url: `${SITE_URL}/leaderboard/daily`,
          name: "Burnbar daily leaderboard",
          description:
            "Public opt-in Claude Code and OpenAI Codex token usage ranking.",
        },
        {
          "@type": "CollectionPage",
          "@id": `${SITE_URL}/leaderboard/weekly#webpage`,
          url: `${SITE_URL}/leaderboard/weekly`,
          name: "Burnbar weekly leaderboard",
          description:
            "Public opt-in Claude Code and OpenAI Codex token usage ranking.",
        },
        {
          "@type": "CollectionPage",
          "@id": `${SITE_URL}/leaderboard/monthly#webpage`,
          url: `${SITE_URL}/leaderboard/monthly`,
          name: "Burnbar monthly leaderboard",
          description:
            "Public opt-in Claude Code and OpenAI Codex token usage ranking.",
        },
        {
          "@type": "WebPage",
          "@id": `${SITE_URL}/privacy#webpage`,
          url: `${SITE_URL}/privacy`,
          name: "Burnbar Privacy Policy",
          description:
            "What Burnbar collects, what it never reads, retention, and deletion controls.",
        },
      ],
    },
    {
      "@type": "SoftwareApplication",
      "@id": `${SITE_URL}/#software`,
      name: SITE_NAME,
      applicationCategory: "DeveloperApplication",
      operatingSystem: "macOS",
      url: `${SITE_URL}/`,
      description:
        "A native macOS menu-bar app that tracks Claude Code and OpenAI Codex token usage from local CLI logs.",
      codeRepository: REPO_URL,
      downloadUrl: RELEASES_URL,
      offers: {
        "@type": "Offer",
        price: "0",
        priceCurrency: "USD",
      },
      sameAs: [REPO_URL],
    },
  ],
} as const;

export const metadata: Metadata = {
  // Absolute base for OG/Twitter image and canonical URL resolution. Required
  // for `opengraph-image` and relative `alternates` to resolve to full URLs.
  metadataBase: new URL(SITE_URL),
  title: SITE_TITLE,
  description: SITE_DESCRIPTION,
  applicationName: SITE_NAME,
  // No site-wide `alternates.canonical` here: a global "/" canonical would leak
  // onto every page (e.g. /privacy would canonicalize to "/"). Each page sets
  // its own canonical instead.
  openGraph: {
    type: "website",
    siteName: SITE_NAME,
    title: SITE_TITLE,
    description: SITE_DESCRIPTION,
    // The default opengraph-image (app/opengraph-image.tsx) is attached
    // automatically by Next; per-page images override it where present.
  },
  twitter: {
    card: "summary_large_image",
    title: SITE_TITLE,
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
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{
            __html: JSON.stringify(STRUCTURED_DATA).replace(/</g, "\\u003c"),
          }}
        />
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
