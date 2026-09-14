#!/usr/bin/env bash
# Upload one recorded run to the evidence bucket, in both layouts, and write the
# manifest that stays in the repository.
#
# Two layouts, because they answer different needs:
#   loose files  - every cited file keeps its path and gets its own CDN URL
#   one archive  - materialising a whole run is a single request, not thousands
#
# The B2 key used here can write but not read or list, which is deliberate: reads
# are rate-limited, so nothing reads through the B2 API. Verification happens
# separately, through the CDN (see evidence-verify.sh).
#
# Usage: evidence-upload.sh <run-dir> [<run-dir>...]
#   run-dir is relative to demos/cert-hygiene, e.g. runs/00-baseline-control/20260912T065110Z
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$ROOT/demos/cert-hygiene"
REMOTE="b2s3:linkerd-playground"
IMMUTABLE="Cache-Control: public, max-age=31536000, immutable"
# A write-only key cannot check the bucket or HEAD an object; these flags stop
# rclone from trying, which it otherwise does before every transfer.
RCLONE_OPTS=(--s3-no-check-bucket --s3-no-head --s3-no-head-object --no-check-dest
  --header-upload "$IMMUTABLE" --transfers 24 --checkers 24 --retries 3)

[ $# -ge 1 ] || { echo "usage: evidence-upload.sh <run-dir> [<run-dir>...]" >&2; exit 2; }

for rel in "$@"; do
  dir="$DEMO/$rel"
  [ -d "$dir" ] || { echo "no such run: $rel" >&2; exit 2; }

  files=$(find "$dir" -type f | wc -l | tr -d ' ')
  echo "== $rel ($files files)"

  # The manifest is the repository's record of what the bucket should hold: every
  # path, its size and its checksum. It is what makes a downloaded file provable
  # without trusting the CDN, the bucket, or this script.
  manifest="$dir.manifest.txt"
  {
    echo "run=$rel"
    echo "files=$files"
    echo "uploaded_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -f "$dir/validity.txt" ]; then sed 's/^/validity_/' "$dir/validity.txt"; fi
    if [ -f "$dir/git-state.txt" ]; then grep '^harness_tree_sha256' "$dir/git-state.txt" || true; fi
    echo "archive=$rel.tar.gz"
    echo "---"
    ( cd "$dir" && find . -type f | sed 's|^\./||' | sort | while IFS= read -r f; do
        printf '%s  %s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$(wc -c < "$f" | tr -d ' ')" "$f"
      done )
  } > "$manifest"
  echo "   manifest: $(wc -l < "$manifest" | tr -d ' ') lines"

  # One archive per run, built reproducibly enough that its checksum is meaningful.
  archive="$dir.tar.gz"
  ( cd "$(dirname "$dir")" && tar -czf "$(basename "$archive")" "$(basename "$dir")" )
  echo "   archive:  $(du -h "$archive" | cut -f1)  sha256 $(shasum -a 256 "$archive" | cut -d' ' -f1)"

  echo "   uploading loose files..."
  rclone copy "$dir" "$REMOTE/$rel" "${RCLONE_OPTS[@]}"
  echo "   uploading archive and manifest..."
  rclone copyto "$archive" "$REMOTE/$rel.tar.gz" "${RCLONE_OPTS[@]}"
  rclone copyto "$manifest" "$REMOTE/$rel.manifest.txt" "${RCLONE_OPTS[@]}"

  rm -f "$archive"
  echo "   done"
done
