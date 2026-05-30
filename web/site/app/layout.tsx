import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";

export const metadata: Metadata = {
  title: "Burnbar Leaderboard",
  description:
    "The global leaderboard for Claude Code and OpenAI Codex token usage.",
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
