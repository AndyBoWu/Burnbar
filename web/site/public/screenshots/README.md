# Landing-page app screenshots (issue #177)

Real screenshots of the Burnbar menu-bar app, rendered by the "See Burnbar in
action" section of [`app/page.tsx`](../../app/page.tsx).

The section is **asset-gated**: it stays hidden until the PNGs below exist. Until
then this folder ships only this README, and `app/page.tsx` has
`const HAS_SCREENSHOTS = false;` so the live site renders nothing for the
section. Drop the PNGs in here, set `HAS_SCREENSHOTS = true`, and the section
turns on. No binary images are committed in the gated state — do not commit
placeholders.

## How to produce them

The committed PNGs are rendered from the app's real SwiftUI views (the `popover`
tiles + burn bars are the genuine `ProviderTileView` / `BurnBarView`) via SwiftUI's
`ImageRenderer` — **no Screen Recording permission and no `screencapture`**. They
are fed synthetic sample data (token counts + known model ids only; never a real
prompt, path, or project). Regenerate them with:

```bash
./Scripts/render_screenshots.sh
```

It runs the `BurnbarScreenshotTests` target (hosted by the app, `@testable import`)
and copies the PNGs into this folder. `ImageRenderer` can't draw AppKit-backed
controls (`Form`, segmented `Picker`, `Toggle`), so the `settings` shot and the
popover's mode picker use clearly-representative SwiftUI stand-ins; everything with
real data is the production view.

A legacy interactive capture path also exists for a Mac **with Screen Recording
permission** (System Settings → Privacy & Security → Screen Recording):

```bash
./Scripts/capture_screenshots.sh
```

It builds + launches `Burnbar.app` and walks you through capturing each shot into
this folder. See the script header for the permission requirement and the privacy
checklist.

## Required files

| File               | What it shows                                  | Used as            |
| ------------------ | ---------------------------------------------- | ------------------ |
| `menubar.png`      | The 🔥 status item live in the macOS menu bar  | Wide hero frame    |
| `popover.png`      | The popover with usage data (the everyday view)| Primary frame      |
| `empty-state.png`  | The popover's actionable "no data yet" state   | Secondary frame    |
| `settings.png`     | The Settings window (providers, leaderboard)   | Secondary frame    |

All four are optional individually — the section renders whichever exist, so you
can ship `popover.png` first and add the rest later. (`HAS_SCREENSHOTS` only
needs to be `true` and at least one image present.)

## Recommended dimensions

Capture on a Retina display, then these are good targets. The page constrains
display width with CSS, so larger is fine — these are floors, not exact sizes.

| File              | Aspect ratio | Suggested size (px, @2x) | Notes                                  |
| ----------------- | ------------ | ------------------------ | -------------------------------------- |
| `menubar.png`     | wide / banner| ~1600 × 200              | Crop tight to the status item + a bit of bar context. |
| `popover.png`     | ~3:4 portrait| ~720 × 960               | The popover is tall and narrow.        |
| `empty-state.png` | ~3:4 portrait| ~720 × 960               | Same frame size as `popover.png`.      |
| `settings.png`    | ~4:3 / 3:2   | ~1280 × 900              | The Settings window is wider than tall.|

- Keep file sizes lean (PNG, ideally < ~400 KB each) so the page stays fast.
- The page lazy-loads these images and sets explicit dimensions to avoid layout
  shift; if your real assets differ in ratio, update the `width`/`height` on the
  corresponding `<img>` in `app/page.tsx` to match (keeps CLS at zero).

## Privacy (load-bearing — see repo `CLAUDE.md`)

These images are public. Burnbar's UI can surface project directory names and
paths. **Never** ship a screenshot that exposes a real project name, file path,
git branch, or prompt. Capture on a clean demo profile and eyeball every PNG
before committing.
