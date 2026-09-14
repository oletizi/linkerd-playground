#!/usr/bin/env bash
# Verify an uploaded run by reading it back through the CDN — never through the
# B2 API, which is rate-limited and which the upload key cannot read anyway.
#
# Two checks, because the two layouts can fail independently:
#   archive - fetched whole and compared file by file against the local run
#   loose   - a sample of individual files fetched by their own URL and checked
#             against the checksum recorded in the manifest
#
# Usage: evidence-verify.sh <run-dir> [sample-size]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$ROOT/demos/cert-hygiene"
BASE="${EVIDENCE_BASE_URL:-https://linkerd-evidence.oletizi.workers.dev}"

rel="${1:?usage: evidence-verify.sh <run-dir> [sample-size]}"
sample="${2:-10}"
dir="$DEMO/$rel"
manifest="$dir.manifest.txt"
[ -f "$manifest" ] || { echo "no manifest for $rel" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

echo "== $rel"

echo "-- archive"
if ! curl -fsS -o "$tmp/run.tar.gz" "$BASE/$rel.tar.gz"; then
  echo "   FAIL: archive not retrievable"; exit 1
fi
mkdir -p "$tmp/x" && tar -xzf "$tmp/run.tar.gz" -C "$tmp/x"
extracted="$tmp/x/$(basename "$rel")"
if [ -d "$dir" ]; then
  if diff -r --brief "$dir" "$extracted" > "$tmp/diff.txt" 2>&1; then
    echo "   ok: archive matches the local run exactly ($(find "$extracted" -type f | wc -l | tr -d ' ') files)"
  else
    echo "   FAIL: archive differs from local:"; head -5 "$tmp/diff.txt"; fail=1
  fi
else
  # The local copy is gone, so the manifest is the reference instead.
  while read -r sha size path; do
    [ -f "$extracted/$path" ] || { echo "   FAIL: missing in archive: $path"; fail=1; continue; }
    got="$(shasum -a 256 "$extracted/$path" | cut -d' ' -f1)"
    [ "$got" = "$sha" ] || { echo "   FAIL: checksum differs: $path"; fail=1; }
  done < <(sed -n '/^---$/,$p' "$manifest" | tail -n +2)
  [ "$fail" -eq 0 ] && echo "   ok: archive matches every checksum in the manifest"
fi

echo "-- loose files (sample of $sample)"
n=0; bad=0
while read -r sha size path; do
  url="$BASE/$rel/$path"
  if ! curl -fsS -o "$tmp/one" "$url"; then
    echo "   FAIL: not retrievable: $path"; bad=$((bad + 1)); continue
  fi
  got="$(shasum -a 256 "$tmp/one" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    echo "   FAIL: checksum differs: $path"; bad=$((bad + 1))
  fi
  n=$((n + 1))
done < <(sed -n '/^---$/,$p' "$manifest" | tail -n +2 | awk 'NF==3' | sort -R | head -n "$sample")
echo "   checked $n files, $bad bad"
[ "$bad" -eq 0 ] || fail=1

echo "-- cache behaviour"
# Written to a file rather than piped into an early-exiting reader: under
# `set -o pipefail`, a reader that closes the pipe first makes the whole pipeline
# fail, which silently killed this script before it could report anything.
sed -n '/^---$/,$p' "$manifest" | tail -n +2 | awk 'NF==3{print $3}' > "$tmp/paths"
probe="$(head -n 1 "$tmp/paths")"
curl -fsS -o /dev/null "$BASE/$rel/$probe" || true
state="$(curl -fsS -D- -o /dev/null "$BASE/$rel/$probe" | awk -F': ' 'tolower($1)=="x-evidence-cache"{print $2}' | tr -d '\r')"
echo "   second read served from: ${state:-unknown}"
[ "$state" = "hit" ] || { echo "   FAIL: expected a cache hit, so reads are not touching B2"; fail=1; }

[ "$fail" -eq 0 ] && echo "== $rel verified" || { echo "== $rel FAILED"; exit 1; }
