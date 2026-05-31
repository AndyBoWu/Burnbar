// Build-time resolver for the latest Burnbar macOS release.
//
// The landing-page Download CTA must link DIRECTLY to the latest recommended
// macOS artifact rather than dumping the user on the GitHub Releases page where
// they have to guess which asset to pick (issue #168). Release assets are
// VERSIONED (`Burnbar-vX.Y.Z.dmg` / `.zip`), so a hardcoded direct link goes
// stale on every release — instead we resolve the recommended asset from the
// GitHub Releases API at build time.
//
// This module is server-only (no "use client"): it runs during `next build`
// and the resolved URL is baked into the statically rendered HTML. It mirrors
// the fetch conventions in `app/lib/api.ts` (try/catch + graceful fallback,
// `next.revalidate`) so a failed/offline/rate-limited fetch NEVER crashes the
// build — it falls back to `/releases/latest`.
//
// The returned metadata (version, published date, asset size, sha256 digest)
// is intentionally richer than the CTA needs so issue #178 (trust signals) can
// reuse `getLatestRelease()` for the version/date/size/checksum badges.

const OWNER = "AndyBoWu";
const REPO = "Burnbar";

/** GitHub Releases API endpoint for the latest published (non-draft) release. */
const LATEST_RELEASE_API_URL = `https://api.github.com/repos/${OWNER}/${REPO}/releases/latest`;

/**
 * Human-facing "latest release" page. Used as the SECONDARY "release notes"
 * link and as the graceful CTA fallback when the API can't be reached at build
 * time — GitHub redirects this to the newest tag, so it's always current.
 */
export const RELEASES_LATEST_URL = `https://github.com/${OWNER}/${REPO}/releases/latest`;

/** All releases — the SECONDARY "View all releases" link target. */
export const RELEASES_URL = `https://github.com/${OWNER}/${REPO}/releases`;

/** Build-time fetch budget. Short enough to keep CI snappy if GitHub is slow. */
const FETCH_TIMEOUT_MS = 8000;

/** A single downloadable artifact attached to a release. */
export interface ReleaseAsset {
  /** Asset filename, e.g. `Burnbar-v0.1.0.dmg`. */
  name: string;
  /** Direct download URL for the asset. */
  browserDownloadUrl: string;
  /** Asset size in bytes (for "X MB" trust signals — issue #178). */
  size: number;
  /**
   * SHA-256 of the asset, as `"sha256:<hex>"` when GitHub exposes the `digest`
   * field, else `null`. Surfaced as a checksum trust signal (issue #178).
   */
  digest: string | null;
}

/** Structured view of the latest release plus the resolved recommended asset. */
export interface LatestRelease {
  /** Git tag, e.g. `v0.1.0`. */
  tag: string;
  /**
   * Tag with any leading `v` stripped, e.g. `0.1.0`. Convenient for display
   * (`Download for macOS (0.1.0)`).
   */
  version: string;
  /** ISO-8601 published timestamp, or `null` if the API omitted it. */
  publishedAt: string | null;
  /** Every asset attached to the release (may be empty). */
  assets: ReleaseAsset[];
  /**
   * The recommended download asset: the `.dmg` if present (preferred for
   * non-technical macOS users — drag-to-Applications), else the `.zip`, else
   * `null` when the release has no recognized macOS artifact.
   */
  recommendedAsset: ReleaseAsset | null;
  /**
   * The href the PRIMARY Download CTA should use. The recommended asset's
   * direct download URL when one was resolved; otherwise the `/releases/latest`
   * page so the button always works.
   */
  downloadUrl: string;
  /**
   * True when `downloadUrl` is a direct artifact link, false when it fell back
   * to the releases page (API failure, or a release with no macOS asset).
   */
  isDirectDownload: boolean;
}

/**
 * The value returned when the GitHub API can't be reached or returns an
 * unusable payload at build time. The CTA still works — it points at the
 * always-current `/releases/latest` page.
 */
const FALLBACK: LatestRelease = {
  tag: "",
  version: "",
  publishedAt: null,
  assets: [],
  recommendedAsset: null,
  downloadUrl: RELEASES_LATEST_URL,
  isDirectDownload: false,
};

/**
 * Resolve the latest release and its recommended macOS download at build time.
 *
 * Recommended-asset preference: `.dmg` (best for non-technical users) → `.zip`.
 * Right now `v0.1.0` ships only a `.zip`, so that's selected; once a release
 * attaches a `.dmg` it is picked automatically with no code change.
 *
 * NEVER throws: any network/timeout/HTTP/shape error resolves to `FALLBACK`
 * (CTA → `/releases/latest`) so the static build always succeeds.
 */
export async function getLatestRelease(): Promise<LatestRelease> {
  try {
    const res = await fetch(LATEST_RELEASE_API_URL, {
      headers: {
        accept: "application/vnd.github+json",
        // GitHub requires a UA; without it the API responds 403.
        "user-agent": "burnbar-site-build",
      },
      // Revalidate daily so a long-lived/ISR deploy still picks up new
      // releases without a rebuild; build-time fetch bakes in the first value.
      next: { revalidate: 86400 },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) return FALLBACK;
    const data: unknown = await res.json();
    return parseRelease(data);
  } catch {
    return FALLBACK;
  }
}

/** Pick the recommended asset: prefer `.dmg`, then `.zip`, else `null`. */
function pickRecommendedAsset(assets: ReleaseAsset[]): ReleaseAsset | null {
  const lower = (name: string) => name.toLowerCase();
  return (
    assets.find((a) => lower(a.name).endsWith(".dmg")) ??
    assets.find((a) => lower(a.name).endsWith(".zip")) ??
    null
  );
}

/**
 * Validate the GitHub Releases payload defensively and project it onto our
 * typed shape. Returns `FALLBACK` on any mismatch so a schema change upstream
 * degrades to the releases-page link instead of crashing the build.
 */
function parseRelease(data: unknown): LatestRelease {
  if (typeof data !== "object" || data === null) return FALLBACK;
  const record = data as Record<string, unknown>;

  const tag = typeof record.tag_name === "string" ? record.tag_name : "";
  if (tag === "") return FALLBACK;

  const publishedAt =
    typeof record.published_at === "string" ? record.published_at : null;

  const assets: ReleaseAsset[] = [];
  if (Array.isArray(record.assets)) {
    for (const item of record.assets) {
      if (typeof item !== "object" || item === null) continue;
      const asset = item as Record<string, unknown>;
      const name = asset.name;
      const browserDownloadUrl = asset.browser_download_url;
      if (
        typeof name !== "string" ||
        typeof browserDownloadUrl !== "string"
      ) {
        continue;
      }
      assets.push({
        name,
        browserDownloadUrl,
        size: typeof asset.size === "number" ? asset.size : 0,
        digest: typeof asset.digest === "string" ? asset.digest : null,
      });
    }
  }

  const recommendedAsset = pickRecommendedAsset(assets);

  return {
    tag,
    version: tag.replace(/^v/, ""),
    publishedAt,
    assets,
    recommendedAsset,
    downloadUrl: recommendedAsset
      ? recommendedAsset.browserDownloadUrl
      : RELEASES_LATEST_URL,
    isDirectDownload: recommendedAsset !== null,
  };
}
