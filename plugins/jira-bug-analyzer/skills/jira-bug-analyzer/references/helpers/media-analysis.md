# Media analysis — human-mcp first, native-vision fallback (`[MEDIA]`)

> How the skill turns an image/video into a TEXT understanding — for Jira attachments (Phase 3 Fix-5) AND on-device verify observation (Phase 5 / the verifiers). **Primary path = human-mcp** (`eyes_analyze` / `eyes_compare`): pass a **file path**, get **text** back — the raw pixels/frames NEVER enter Claude's context, so there is no per-image token cost and no need to resize/keyframe on the primary path. **Fallback = Claude-native vision** (only when human-mcp is unavailable), which DOES Read bytes into context → then the shrink recipe in `media-preprocessing.md` applies.

## Primary — human-mcp (`eyes_analyze` / `eyes_compare`)
- **Analyze one media** (Jira attachment image OR video, or a device screencap): `mcp__human-mcp__eyes_analyze({ source: "<file-path-or-url>", detail: "detailed", focus: "<what to look for — the bug / UI state / repro step>" })` → returns a text description. Use its text; do NOT also Read the file.
- **Compare two images** (verify device shot ⟷ Figma reference — the design-diff): `mcp__human-mcp__eyes_compare({ image1: "<device.png>", image2: "<figma.png>", focus: "differences" })` → returns the delta as text.
- **Video is a first-class input to `eyes_analyze`** — pass the mp4 path directly (no ffmpeg frame-extraction needed on this path; human-mcp handles the video). Still resolve hosted links to a real file first (the Fix-5 fetch ladder).
- Bytes stay out of context → **media analysis on this path does NOT need the `[TOKEN]` subagent isolation for cost reasons** (the returned text is small). Subagent isolation still applies to the *other* heavy reads (uiautomator XML, logcat) and to keep investigation off the main loop.

## Keys — a LIST that human-mcp rotates INTERNALLY
The dev injects a comma-separated Gemini key list into **`.claude/.env`** as **`HUMAN_MCP_GEMINI_KEYS`**; human-mcp's server is configured to rotate through them itself (the skill does NOT pick a key — `eyes_*` take no key argument). The skill only tracks whether human-mcp is currently usable (below).

## Availability cache + daily reset (`.jira-bug/human-mcp-state.json`)
So the run doesn't hammer a dead quota all day, the skill caches human-mcp's availability per repo (untracked file):
```json
{ "provider": "human-mcp", "status": "available | exhausted", "since": "<YYYY-MM-DD>", "reason": "<e.g. gemini quota — all keys exhausted>" }
```
At each media step, BEFORE calling human-mcp:
1. **Read the state.** Missing / `status: available` → use human-mcp.
2. **`status: exhausted` AND `since == today`** → skip human-mcp, go straight to the native-vision fallback (all keys already known exhausted today).
3. **`status: exhausted` AND `since < today`** → **daily reset**: rewrite `status: available` (Gemini quotas renew daily) and try human-mcp again.

On a human-mcp call that fails with a **quota / auth / all-keys-exhausted** error: write `{ status: "exhausted", since: <today>, reason }`, then fall back to native vision for this item and the rest of today. A transient/one-off error (network blip) → retry once, do NOT mark exhausted.

## Fallback — Claude-native vision (only when human-mcp is unavailable)
When step 2 says exhausted-today, or human-mcp isn't configured at all: analyze with **Claude-native vision**, and because that Reads bytes into context, **apply `references/helpers/media-preprocessing.md`** (resize images ≤1280px, extract video keyframes, read docs by section). This is the ONLY path where the shrink recipe matters.

## Where this is used
- **Phase 3 Fix-5** (`references/phase3-analyze.md`) — Jira attachment image/video → `eyes_analyze`. **Share links in the ticket text** (prnt.sc / Lightshot, ibb.co, imgur, gyazo, postimg, direct media URLs) are first turned into files by `assets/fetch-media-links.sh` (resolves a share page to its `og:video`/`og:image`, keeps only real image/video files by magic bytes), then analyzed the same way.
- **Phase 5 verify** (`references/phase5-verify.md`) + **`android-ui-verify`** / **`android-self-verify`** — observe a device screencap → `eyes_analyze`; the device⟷Figma design-diff → `eyes_compare`. Evidence files are still SAVED to disk for the PR/Jira regardless of which path analyzed them.
