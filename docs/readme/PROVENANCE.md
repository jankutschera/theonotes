# README screenshots: provenance

All four images show the app with made-up demo notes; no real library data. They are screenshots of
Theo Notes itself and fall under the same terms as the app's branding (see `BRANDING.md`): you may show
them to describe this project, not to brand another product.

| File | Source | Made | Already public as |
|---|---|---|---|
| `mac-library-light.png` | copy of `website/public/img/app/library-light.png` (private website repo), 1440 x 900 | Mac app screenshot, commit 15b261f8, 2026-11-03 | hero image on theonotes.app |
| `mac-note-dark.png` | copy of `website/public/img/app/rich-dark.png`, 1440 x 900 | same commit | theonotes.app |
| `mac-search-dark.png` | copy of `website/public/img/app/search-dark.png`, 1440 x 900 | same commit | theonotes.app |
| `iphone-recipe.png` | `docs/release/store-screenshots/1.0/iphone/02-recipe-editor.png` scaled to 1200 px high with `sips -Z 1200` | iPhone 17 simulator, Theo Notes 1.0.0 (3) Release build, 2026-11 | App Store listing of Theo Notes 1.0 |

Copied 2026-11-25 for the public README (OSS export).

## Added 2026-11-26 (launch prep)

| File | Source | Made |
|---|---|---|
| `claude-mcp.gif` | Replay of a real Claude Code session (`claude -p` with `theonotes mcp-server --data-dir` on a demo library of five made-up notes, built from this repository with `swift build`). The tool calls, their arguments and the answer are shortened from that session's log; the note panel on the right is an HTML rendering of the note's Markdown after the edit, not a screenshot of the app. Rendered with Playwright, converted with ffmpeg, 960 px wide, 21 s. | 2026-11-26 |
| `social-preview.png` | GitHub social preview, 1280 x 640, rendered from the website repository's `website/og/social-preview.html` with the app icon and the site's fonts and colours. | 2026-11-26 |
