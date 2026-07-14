#!/usr/bin/env bash
# Ensure every official asset has a GitHub Releases streaming fallback, extend
# the Open Cinema schedule horizon, sign locally, verify, and publish. The key is
# password-encrypted and lives only on this machine — you enter the password
# ONCE (minisign prompts); it never leaves your Mac and is never stored.
#
# Usage:   ./scripts/refresh-official.sh [DAYS]      (default: 14)
#   e.g.   ./scripts/refresh-official.sh 30
#
# Override the key location if it isn't at the default:
#   FIVES_OFFICIAL_KEY=/path/to/registry.key ./scripts/refresh-official.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"          # .../5ives-registry
KEY="${FIVES_OFFICIAL_KEY:-$REPO_DIR/../secrets/official/registry.key}"
PUB="$REPO_DIR/keys/registry.pub"                                    # the published (== pinned) key
CONTENT_DIR="${FIVES_CONTENT_DIR:-$HOME/Library/Application Support/live.5ives.app/content}"
GITHUB_REPO="${FIVES_OFFICIAL_REPO:-kaigani/5ives-registry}"
DAYS="${1:-14}"

command -v minisign >/dev/null 2>&1 || { echo "error: minisign not found (brew install minisign)"; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "error: GitHub CLI not found (brew install gh)"; exit 1; }
[ -f "$KEY" ] || { echo "error: official key not found at: $KEY"; exit 1; }
[ -f "$PUB" ] || { echo "error: published key not found at: $PUB"; exit 1; }

# 1. Decrypt a throwaway copy of the key so signing many schedules needs only ONE
#    password prompt. The temp key is overwritten when supported, then deleted on
#    any exit. (Flash storage may retain physical copies despite an overwrite.)
TMPKEY="$(mktemp -t 5ives-official-key.XXXXXX)"
cleanup() {
  [ -e "$TMPKEY" ] || return 0
  chmod 600 "$TMPKEY" 2>/dev/null || true
  if command -v shred >/dev/null 2>&1; then
    shred -u "$TMPKEY" 2>/dev/null || rm -f "$TMPKEY"
  elif rm -P "$TMPKEY" 2>/dev/null; then
    :
  else
    rm -f "$TMPKEY"
  fi
}
trap cleanup EXIT INT TERM
cp "$KEY" "$TMPKEY"; chmod 600 "$TMPKEY"
echo "Unlock the official signing key (enter your recorded password):"
minisign -C -W -s "$TMPKEY"   # prompts once for the current password, writes the copy unencrypted

# 2. Put each package in an idempotent per-asset prerelease. GitHub is the HTTP
#    origin fallback; torrents/DHT remain the first-choice distribution path.
#    The exact release base is then included in the signed asset document.
while IFS= read -r doc; do
  asset_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["asset_id"])' "$doc")"
  package="$CONTENT_DIR/$asset_id"
  video="$package/video_1080p.mp4"
  poster="$package/poster.jpg"
  [ -f "$video" ] || { echo "error: media missing: $video"; exit 1; }
  [ -f "$poster" ] || { echo "error: media missing: $poster"; exit 1; }

  tag="media-$asset_id"
  if ! gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    gh release create "$tag" --repo "$GITHUB_REPO" --prerelease \
      --title "5ives media: $asset_id" \
      --notes "Streaming fallback managed by 5ives LIVE."
  fi

  sizes="$(gh api "repos/$GITHUB_REPO/releases/tags/$tag" | python3 -c '
import json, sys
assets = {a["name"]: a["size"] for a in json.load(sys.stdin).get("assets", [])}
print(assets.get("video_1080p.mp4", -1), assets.get("poster.jpg", -1))
')"
  read -r remote_video_size remote_poster_size <<< "$sizes"
  local_video_size="$(stat -f %z "$video")"
  local_poster_size="$(stat -f %z "$poster")"
  if [ "$remote_video_size" != "$local_video_size" ] || [ "$remote_poster_size" != "$local_poster_size" ]; then
    echo "Uploading streaming fallback for $asset_id…"
    gh release upload "$tag" --repo "$GITHUB_REPO" --clobber \
      "$video#video_1080p.mp4" "$poster#poster.jpg"
  fi

  mirror="https://github.com/$GITHUB_REPO/releases/download/$tag"
  changed="$(python3 - "$doc" "$mirror" <<'PY'
import json, sys
path, mirror = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    asset = json.load(fh)
urls = asset.setdefault("mirror_urls", [])
if mirror in urls:
    print("no")
else:
    urls.append(mirror)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(asset, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print("yes")
PY
)"
  if [ "$changed" = "yes" ]; then
    minisign -S -H -q -s "$TMPKEY" -m "$doc" -x "$doc.minisig"
  fi
done < <(find "$REPO_DIR/assets" -maxdepth 1 -name "*.json" -type f | sort)

# 3. Extend + sign the schedules forward from today (prehashed = app-compatible).
python3 "$REPO_DIR/scripts/refresh_schedules.py" --root "$REPO_DIR" --secret-key "$TMPKEY" --days "$DAYS"

# 4. Verify every changed trust document against the published key.
fail=0
while IFS= read -r sig; do
  doc="${sig%.minisig}"
  if ! minisign -V -H -p "$PUB" -m "$doc" >/dev/null 2>&1; then
    echo "VERIFY FAIL: $doc"; fail=1
  fi
done < <(find "$REPO_DIR/channels" "$REPO_DIR/assets" -name "*.minisig")
[ "$fail" -eq 0 ] || { echo "error: some documents failed verification — NOT publishing."; exit 1; }
echo "All channel and asset documents verify against the published key."

# 5. Publish only if something changed.
cd "$REPO_DIR"
if [ -z "$(git status --porcelain --untracked-files=normal -- channels assets)" ]; then
  echo "Streaming fallbacks and schedule horizon already current — nothing to publish."
else
  git add --all -- channels/*/schedules assets
  git commit -m "Refresh official media origins and schedules (+${DAYS}d)"
  git push
  echo "Published. Open Cinema has HTTP fallbacks and is live for the next ${DAYS} days."
fi
