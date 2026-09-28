#!/usr/bin/env bash
# Runs on the macOS HOST. Creates (or reuses) the OrbStack machine the cert-hygiene
# lab runs in, installs the packages the in-VM scripts need, and proves the machine
# sees this working tree at the same path -- the lab runs straight from it.
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$DEMO"
require_cmd orb

orb status 2>/dev/null | grep -qx Running || { log "starting OrbStack"; orb start; }

if orb list 2>/dev/null | awk '{print $1}' | grep -qx "$LAB_VM"; then
  log "$LAB_VM exists; reusing it"
else
  # No -a: the machine gets the host's architecture. An amd64 guest on Apple Silicon
  # is emulated and unusably slow (see demos/spiffe-cross-boundary/README-ORBSTACK.md).
  log "creating $LAB_VM"
  orb create --cpus "$LAB_CPUS" --memory "$LAB_MEM" --disk "$LAB_DISK" ubuntu:24.04 "$LAB_VM"
fi

host_arch="$(detect_arch)"
case "$(orb -m "$LAB_VM" uname -m)" in
  aarch64|arm64) vm_arch=arm64 ;;
  x86_64|amd64)  vm_arch=amd64 ;;
  *) die "unrecognised architecture in $LAB_VM: $(orb -m "$LAB_VM" uname -m)" ;;
esac
[ "$vm_arch" = "$host_arch" ] || die "$LAB_VM is $vm_arch but this host is $host_arch.
  An emulated guest makes every timing in the lab meaningless. Delete it
  (just demo cert-hygiene lab-down) and run lab-up again."

log "installing packages in $LAB_VM"
orb -m "$LAB_VM" bash -lc 'sudo apt-get update -qq && sudo apt-get install -y -qq curl jq openssl gettext-base shellcheck'

# OrbStack shows Mac files at the same paths inside machines. Every in-VM script
# depends on that, so prove it instead of assuming it.
orb -m "$LAB_VM" test -f "$DEMO/config.example.env" || die "$LAB_VM cannot see $DEMO.
  The lab runs from the working tree through OrbStack's file sharing
  (https://docs.orbstack.dev/machines/file-sharing); without it nothing else works."

log "$LAB_VM ready ($vm_arch); it sees $DEMO"
