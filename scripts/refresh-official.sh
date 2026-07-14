#!/usr/bin/env bash
# Extend the official Open Cinema looping schedule horizon, sign it locally with
# the official key, verify, and publish. The official signing key is
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
DAYS="${1:-14}"

command -v minisign >/dev/null 2>&1 || { echo "error: minisign not found (brew install minisign)"; exit 1; }
[ -f "$KEY" ] || { echo "error: official key not found at: $KEY"; exit 1; }
[ -f "$PUB" ] || { echo "error: published key not found at: $PUB"; exit 1; }

# 1. Decrypt a throwaway copy of the key so signing many schedules needs only ONE
#    password prompt. The temp key is shredded on any exit.
TMPKEY="$(mktemp -t 5ives-official-key.XXXXXX)"
cleanup() { rm -f "$TMPKEY" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
cp "$KEY" "$TMPKEY"; chmod 600 "$TMPKEY"
echo "Unlock the official signing key (enter your recorded password):"
minisign -C -W -s "$TMPKEY"   # prompts once for the current password, writes the copy unencrypted

# 2. Extend + sign the schedules forward from today (prehashed = app-compatible).
python3 "$REPO_DIR/scripts/refresh_schedules.py" --root "$REPO_DIR" --secret-key "$TMPKEY" --days "$DAYS"

# 3. Verify every channel signature against the published key (prehashed required).
fail=0
while IFS= read -r sig; do
  doc="${sig%.minisig}"
  if ! minisign -V -H -p "$PUB" -m "$doc" >/dev/null 2>&1; then
    echo "VERIFY FAIL: $doc"; fail=1
  fi
done < <(find "$REPO_DIR/channels" -name "*.minisig")
[ "$fail" -eq 0 ] || { echo "error: some documents failed verification — NOT publishing."; exit 1; }
echo "All channel documents verify against the published key."

# 4. Publish only if something changed.
cd "$REPO_DIR"
if git diff --quiet -- channels; then
  echo "Schedule horizon already current — nothing to publish."
else
  git add channels/*/schedules
  git commit -m "Extend official schedule horizon (+${DAYS}d)"
  git push
  echo "Published. Open Cinema is live for the next ${DAYS} days."
fi
