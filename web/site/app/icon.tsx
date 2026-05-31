import { ImageResponse } from "next/og";

// Favicon for Burnbar, generated with next/og so it shares the brand with the
// OG card (app/opengraph-image.tsx): the 🔥 flame on a dark background. Next.js
// App Router serves this at /icon and injects <link rel="icon"> automatically —
// no static .ico file or manual <head> wiring needed.

export const runtime = "edge";

export const size = { width: 32, height: 32 };
export const contentType = "image/png";

export default function Icon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          background: "#0a0a0a",
          fontSize: 24,
          borderRadius: 6,
        }}
      >
        🔥
      </div>
    ),
    { ...size },
  );
}
