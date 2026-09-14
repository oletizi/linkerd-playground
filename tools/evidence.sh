#!/usr/bin/env bash
# Read recorded lab evidence that lives in the bucket rather than in this
# repository.
#
# Reads go through the CDN, never the B2 API, which is rate-limited. Repeat reads
# are served from cache and never reach the bucket at all.
#
# Usage:
#   evidence.sh cat   <run> <path>   print one recorded file
#   evidence.sh fetch <run> [dest]   download a whole run (one request) and verify it
#   evidence.sh runs                 list the runs this repository has manifests for
#
#   <run> is a run directory as cited in the notes, e.g.
#         runs/06-anchor-expiry/20260912T125027Z
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$ROOT/demos/cert-hygiene"
BASE="${EVIDENCE_BASE_URL:-https://linkerd-evidence.oletizi.workers.dev}"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd="${1:-}"
case "$cmd" in
  runs)
    ( cd "$DEMO" && ls runs/*/*.manifest.txt 2>/dev/null | sed 's|\.manifest\.txt$||' )
    ;;

  cat)
    run="${2:?usage: evidence.sh cat <run> <path>}"
    path="${3:?usage: evidence.sh cat <run> <path>}"
    manifest="$DEMO/$run.manifest.txt"
    if [ -f "$manifest" ]; then
      want="$(awk -v p="$path" '$3==p{print $1}' "$manifest" | tail -n 1)"
    else
      want=""
    fi
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    curl -fsS -o "$tmp" "$BASE/$run/$path"
    if [ -n "$want" ]; then
      got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
      [ "$got" = "$want" ] || { echo "checksum mismatch for $path" >&2; exit 1; }
    fi
    cat "$tmp"
    ;;

  fetch)
    run="${2:?usage: evidence.sh fetch <run> [dest]}"
    dest="${3:-$DEMO/$run}"
    manifest="$DEMO/$run.manifest.txt"
    [ -f "$manifest" ] || { echo "no manifest for $run in this repository" >&2; exit 2; }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    # One request for the whole run: fetching thousands of individual files would
    # be slower and would lean on the origin far harder on a cold cache.
    curl -fsS -o "$tmp/run.tar.gz" "$BASE/$run.tar.gz"
    mkdir -p "$tmp/x" && tar -xzf "$tmp/run.tar.gz" -C "$tmp/x"
    extracted="$tmp/x/$(basename "$run")"
    bad=0
    while read -r sha size path; do
      [ -f "$extracted/$path" ] || { echo "missing: $path" >&2; bad=1; continue; }
      got="$(shasum -a 256 "$extracted/$path" | cut -d' ' -f1)"
      [ "$got" = "$sha" ] || { echo "checksum mismatch: $path" >&2; bad=1; }
    done < <(sed -n '/^---$/,$p' "$manifest" | tail -n +2 | awk 'NF==3')
    [ "$bad" -eq 0 ] || { echo "run did not verify against its manifest" >&2; exit 1; }
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest" && mv "$extracted" "$dest"
    echo "$dest"
    ;;

  ''|-h|--help) usage 0 ;;
  *) echo "unknown command: $cmd" >&2; usage 2 ;;
esac
