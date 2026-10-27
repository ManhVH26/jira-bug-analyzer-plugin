#!/usr/bin/env bash
# fetch-media-links.sh — turn screenshot/video LINKS in ticket text into local files for [MEDIA].
#
# QA often pastes a share link (prnt.sc / Lightshot, ibb.co, imgur page, …) in the description or a
# comment instead of attaching the file. Those links return an HTML page, not the image, so a plain
# download gets HTML. This script finds the links, resolves a page to its og:image / og:video, and
# saves the real media file — then Fix-5 analyzes it like any Jira attachment.
#
# Usage:
#   fetch-media-links.sh list  <text-file>             # print the media links found (no network)
#   fetch-media-links.sh fetch <text-file> <out-dir>   # download each one
# <text-file> = the ticket description + comments dumped to a file.
# Output (fetch): MEDIA=<saved path> SOURCE=<link>   or   LINK_ERROR=<link> REASON=<why>
# Downloads are untrusted data: only image/* and video/* files are kept (checked by magic, not by name),
# size capped at MEDIA_MAX_BYTES (default 50 MB). Never executes or opens what it downloads.
set -euo pipefail

CMD="${1:-}"; TEXT="${2:-}"
[ -n "$CMD" ] && [ -f "$TEXT" ] || { echo "usage: fetch-media-links.sh {list <text-file> | fetch <text-file> <out-dir>}"; exit 2; }
# Identify honestly as this tool — never impersonate a browser to get past a site's bot protection.
# A host that still refuses this agent gets LINK_ERROR, and the dev pastes/attaches the image instead.
UA="jira-bug-analyzer/1.15.3 (+https://github.com/hung-apero/jira-bug-analyzer-plugin)"
MAX="${MEDIA_MAX_BYTES:-52428800}"

# Share-page hosts (resolve via og:image) + direct media URLs by extension.
links() {
  grep -oE '(https?|file)://[^][ "<>|)}]+' "$TEXT" \
    | sed -E 's/[.,;:!?]+$//' \
    | grep -Ei '(prnt\.sc|prntscr\.com|lightshot|ibb\.co|imgbb\.com|imgur\.com|postimg\.cc|gyazo\.com|\.(png|jpe?g|gif|webp|mp4|mov|webm)(\?|$))' \
    | awk '!seen[$0]++' || true
}

[ "$CMD" = "list" ] && { links; exit 0; }
[ "$CMD" = "fetch" ] || { echo "usage: fetch-media-links.sh {list|fetch} …"; exit 2; }
OUT="${3:?fetch needs <out-dir>}"; mkdir -p "$OUT"

get() { curl -sS -L --max-time 60 --max-filesize "$MAX" -A "$UA" -o "$2" "$1"; }
kind() { file -b --mime-type "$1" 2>/dev/null || echo unknown; }

og_media() { # print the og:video[:url] or og:image URL of a saved HTML page (attribute order varies)
  python3 - "$1" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8", errors="replace").read()
found = {}
for tag in re.findall(r"<meta\b[^>]*>", html, re.I):  # attribute order varies between hosts
    prop = re.search(r'(?:property|name)\s*=\s*["\']og:(video:url|video|image)["\']', tag, re.I)
    val = re.search(r'content\s*=\s*["\']([^"\']+)["\']', tag, re.I)
    if prop and val:
        found.setdefault(prop.group(1).lower(), val.group(1))
print(found.get("video:url") or found.get("video") or found.get("image") or "")
PY
}

n=0
while IFS= read -r url; do
  [ -z "$url" ] && continue
  n=$((n + 1)); tmp="$OUT/.link-$n"
  if ! get "$url" "$tmp" 2>/dev/null; then echo "LINK_ERROR=$url REASON=download failed"; rm -f "$tmp"; continue; fi
  mime="$(kind "$tmp")"
  if [[ "$mime" == text/html* || "$mime" == application/xhtml* ]]; then
    # Share page: take og:video first (a recording is the better repro), else og:image.
    media="$(og_media "$tmp")"
    rm -f "$tmp"
    [ -z "$media" ] && { echo "LINK_ERROR=$url REASON=no og:image/og:video on the page (deleted, private or blocked)"; continue; }
    if ! get "$media" "$tmp" 2>/dev/null; then echo "LINK_ERROR=$url REASON=media download failed ($media)"; rm -f "$tmp"; continue; fi
    mime="$(kind "$tmp")"
  fi
  case "$mime" in
    image/png) ext=png ;; image/jpeg) ext=jpg ;; image/gif) ext=gif ;; image/webp) ext=webp ;;
    video/mp4) ext=mp4 ;; video/quicktime) ext=mov ;; video/webm) ext=webm ;;
    *) echo "LINK_ERROR=$url REASON=not an image/video ($mime)"; rm -f "$tmp"; continue ;;
  esac
  dest="$OUT/link-$n.$ext"; mv "$tmp" "$dest"
  echo "MEDIA=$dest SOURCE=$url"
done < <(links)
[ "$n" -eq 0 ] && echo "NO_LINKS"
exit 0
