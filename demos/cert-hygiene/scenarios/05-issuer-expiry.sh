#!/usr/bin/env bash
# Scenario #5 (design spec section 4): the identity issuer expires mid-run while the
# trust anchor and its key stay valid. T_mark is the issuer's notAfter. Recovery signs
# a replacement issuer from the SAME anchor and applies it the documented way; restarts
# happen only in recorded stages, and only if recovery has not happened on its own.
# Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

scenario_mark_epoch() {
  cert_not_after_epoch "$CERTS/issuer.crt"
}

_recovered_now() { # TICK: the recovery gate -- new-connection probes ok, and both
  # post-expiry workloads rolled out. Every input it reads (each probe's latest line,
  # both rollout statuses, with exit codes) and its verdict go to recover/TICK-gate.txt.
  # The stream probe is excluded: it fails closed, so once its connection is gone it
  # never reports ok again, by design.
  local f="$RUN_DIR/recover/$1-gate.txt" p d out rc pass=yes
  [ ! -e "$f" ] || die "_recovered_now: $f exists; evidence is written once"
  mkdir -p "$RUN_DIR/recover"
  printf 'sampled_at=%s\n' "$(_utc)" > "$f"
  for p in probe-http probe-tcp-new; do
    rc=0
    out="$(kubectl -n "$LAB_NS" logs "deploy/$p" -c probe --tail=1 2>&1)" || rc=$?
    printf '$ kubectl -n %s logs deploy/%s -c probe --tail=1\n%s\n[exit %s]\n' "$LAB_NS" "$p" "$out" "$rc" >> "$f"
    if [ "$rc" -ne 0 ] || ! grep -qE ' seq=[0-9]+ ok( |$)' <<< "$out"; then pass=no; fi
  done
  for d in restart-target probe-new; do
    rc=0
    out="$(kubectl -n "$LAB_NS" rollout status "deploy/$d" --timeout=1s 2>&1)" || rc=$?
    printf '$ kubectl -n %s rollout status deploy/%s --timeout=1s\n%s\n[exit %s]\n' "$LAB_NS" "$d" "$out" "$rc" >> "$f"
    [ "$rc" -eq 0 ] || pass=no
  done
  if [ "$pass" = yes ]; then echo gate=pass >> "$f"; return 0; fi
  echo gate=fail >> "$f"
  return 1
}

_before_restart() { # LABEL: capture the pods a restart stage is about to replace
  snap_logs "$1"
  snap_probes "$1"
}

_recover_ticks() { # PREFIX TIMEOUT_S: tick until recovered (return 0) or timed out (return 1)
  local prefix="$1" deadline=$(( $(date -u +%s) + $2 )) n=1
  while :; do
    tick "$prefix-$n"
    post_expiry_hook "$prefix-$n"
    snap_secret "$prefix-$n"
    if _recovered_now "$prefix-$n"; then mark recovered "at tick $prefix-$n"; return 0; fi
    [ "$(date -u +%s)" -lt "$deadline" ] || return 1
    n=$((n + 1))
    sleep "$OBSERVE_INTERVAL_S"
  done
}

_wait_issuer_updated() { # TIMEOUT_S: record when (or whether) identity reloaded the issuer
  local t0 deadline
  t0="$(date -u +%s)"
  deadline=$(( t0 + $1 ))
  until kubectl -n linkerd get events --field-selector reason=IssuerUpdated -o name 2>/dev/null | grep -q .; do
    if [ "$(date -u +%s)" -ge "$deadline" ]; then
      mark issuer-updated "no IssuerUpdated event within ${1}s"
      return 0
    fi
    sleep 5
  done
  mark issuer-updated "IssuerUpdated event seen $(( $(date -u +%s) - t0 ))s after apply"
}

scenario_recover() {
  local rep="$CERTS/replacement"
  # Invariant (spec 4.3): the replacement is signed by the EXISTING anchor, and
  # nothing here touches the trust roots. trust/*.txt snapshots verify it.
  make_issuer "$rep" "$REPLACEMENT_ISSUER_LIFETIME" "$CERTS"
  write_cert issuer-replacement "$rep/issuer.crt"
  mark recover-apply "linkerd upgrade with the replacement issuer; no trust-anchor flag"
  capture recover/linkerd-upgrade.txt bash -o pipefail -c \
    "linkerd upgrade --identity-issuer-certificate-file='$rep/issuer.crt' --identity-issuer-key-file='$rep/issuer.key' | kubectl apply -f -"
  _wait_issuer_updated 180
  snap_events issuer-updated

  if _recover_ticks recover "$RECOVER_WINDOW_S"; then
    mark recovery "no workload restarts"
    return 0
  fi
  _before_restart pre-stage1
  mark restart "stage 1: the workloads that never became Ready (probe-new, restart-target)"
  capture recover/restart-stage1.txt kubectl -n "$LAB_NS" rollout restart deploy/probe-new deploy/restart-target
  if _recover_ticks recover-s1 "$RECOVER_WINDOW_S"; then
    mark recovery "after stage-1 restarts"
    return 0
  fi
  _before_restart pre-stage2
  mark restart "stage 2: every lab Deployment, as Linkerd's issuer-rotation guide directs"
  capture recover/restart-stage2.txt kubectl -n "$LAB_NS" rollout restart deploy
  if _recover_ticks recover-s2 "$RECOVER_WINDOW_S"; then
    mark recovery "after stage-2 restarts"
    return 0
  fi
  mark recovery "not recovered after stage-2 restarts"
}

run_scenario 05-issuer-expiry issuer-short "${1:?usage: 05-issuer-expiry.sh <run-dir>}"
