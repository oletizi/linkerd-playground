#!/usr/bin/env bash
# Runs INSIDE the lab VM. The private-key guard for a directory, e.g. a run directory
# before it is committed, valid or not (an aborted run keeps its files). It runs key_scan,
# the same scan assert_no_keys runs: PEM key text, and base64 that decodes to a private
# key through up to three layers. Prints each hit and exits 1 on any hit, or when DIR is
# missing or cannot be read; otherwise prints "key-guard: clean DIR".
# Usage: key-guard.sh DIR   (or: just demo cert-hygiene key-guard DIR)
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"

dir="${1:?usage: key-guard.sh DIR}"
[ -d "$dir" ] || die "key-guard: no directory $dir"
if hits="$(key_scan "$dir")"; then
  echo "key-guard: clean $dir"
else
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; fi
  die "key-guard: private key material under $dir, or it could not be scanned"
fi
