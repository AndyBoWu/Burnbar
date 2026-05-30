import { ImageResponse } from "next/og";

// Default Open Graph / Twitter card image for every page that doesn't supply
// its own. Rendered at request time by `next/og` (Satori). Edge runtime is
// required by ImageResponse and matches the Cloudflare Pages deploy target.
export const runtime = "edge";

// Standard OG card dimensions; X (Twitter) renders summary_large_image at 1200x630.
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

// Static alt text — never derived from user content (privacy thesis).
export const alt = "Burnbar — token tracking for Claude Code and OpenAI Codex";

export default function OpengraphImage(): ImageResponse {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          padding: "80px",
          backgroundColor: "#09090b",
          backgroundImage:
            "radial-gradient(circle at 20% 0%, rgba(249,115,22,0.18), transparent 55%)",
        }}
      >
        <div
          style={{
            display: "flex",
            alignItems: "center",
            fontSize: 40,
            fontWeight: 700,
            color: "#f97316",
            letterSpacing: "-0.02em",
          }}
        >
          Burnbar
        </div>
        <div
          style={{
            display: "flex",
            marginTop: 36,
            fontSize: 74,
            fontWeight: 800,
            lineHeight: 1.05,
            color: "#fafafa",
            letterSpacing: "-0.03em",
            maxWidth: 980,
          }}
        >
          Track AI-coding token burn in your menu bar
        </div>
        <div
          style={{
            display: "flex",
            marginTop: 32,
            fontSize: 34,
            color: "#d4d4d8",
            maxWidth: 940,
          }}
        >
          Claude Code and OpenAI Codex token usage, built from local logs.
        </div>
      </div>
    ),
    { ...size },
  );
}
