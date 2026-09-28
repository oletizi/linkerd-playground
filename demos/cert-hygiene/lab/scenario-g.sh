#!/usr/bin/env bash
# Scenario G (design section 4, slice 4): a healthy installation whose sp-validator
# (profileValidator) webhook serving certificate -- time-valid, correctly chained to its
# configured caBundle -- is swapped for one signed with an algorithm the API server
# refuses (SHA-1; slice 4 Task 3's finding), probed under failurePolicy=Fail, then
# restored to a normally-signed certificate. Structured like N (lab/scenario-n.sh): a
# T_mark fault/recover pair over the shared timeline, the same admission-probe set, the
# same lab-webhook helpers, wait_pods_gone shared rather than copied (collect-state.sh).
# The only cause under test is the certificate's signature algorithm, never its dates --
# g-timevalid (lib-evidence-rules.sh) is what makes that provable. Task 3 used the
# sp-validator webhook specifically for its small blast radius: a refused proxy-injector
# certificate under Fail would fail every pod creation in injected namespaces, and a run
# that cannot recover is a lost run. Source after lab/scenario-common.sh; do not execute.
# shellcheck source=/dev/null
. "$LAB_DIR/admission.sh"

# Read only by scenario_post_window_end (scenario-common.sh), not by this file itself.
# shellcheck disable=SC2034
POST_EXPIRY_WINDOW_S="$G_FAULT_WINDOW_S"   # the post window is G's own fault window

G_BACKING_DEPLOYS=()

scenario_mark_epoch() { # T_mark: when the sp-validator certificate is swapped
  echo $(( $(date -u +%s) + FAULT_LEAD_S ))
}

# _g_utc_from EPOCH: the ISO string of an already-sampled epoch. g-timevalid's whole
# purpose is to make time-validity provable, so its own record must never carry a second,
# separately-sampled clock read next to the first: Task 3's own timevalidity/*.txt paired
# an epoch and an ISO string from two separate `date` calls and disagreed with itself by a
# second (a concern for Task 4, design section 4's "the recorded findings" reading).
_g_utc_from() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# _g_timevalid TICK: timevalidity/TICK.txt -- g-timevalid's per-tick record (design
# section 4): the live profileValidator Secret certificate's notAfter, the seconds
# remaining at this tick's one sampled instant, and its signature algorithm as the
# certificate itself reports it (never assumed from what was asked for). Read every tick,
# whichever certificate is live at that moment -- the original before the swap, the
# refused one during and after it, the restored original again at verify.
_g_timevalid() {
  local tick="${1:?_g_timevalid: TICK required}"
  local f="$RUN_DIR/timevalidity/$tick.txt" now crt notafter epoch alg remain checkend_rc=0
  mkdir -p "$RUN_DIR/timevalidity"
  now="$(date -u +%s)"
  crt="$(mktemp)"
  if ! kubectl -n linkerd get secret "$(webhook_secret profileValidator)" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
      | base64 -d > "$crt" 2>/dev/null || [ ! -s "$crt" ]; then
    { printf 'observed_epoch=%s\nobserved_utc=%s\n' "$now" "$(_g_utc_from "$now")"
      printf '[profileValidator certificate unreadable]\n'; } > "$f"
    rm -f "$crt"
    return 0
  fi
  notafter="$(openssl x509 -noout -enddate -in "$crt" 2>/dev/null)"; notafter="${notafter#notAfter=}"
  if [ -z "$notafter" ]; then
    { printf 'observed_epoch=%s\nobserved_utc=%s\n' "$now" "$(_g_utc_from "$now")"
      printf '[profileValidator certificate unreadable: no notAfter]\n'; } > "$f"
    rm -f "$crt"
    return 0
  fi
  epoch="$(date -u -d "$notafter" +%s)"
  alg="$(openssl x509 -noout -text -in "$crt" | awk '/Signature Algorithm/ { print $NF; exit }')"
  remain=$(( epoch - now ))
  openssl x509 -checkend 0 -noout -in "$crt" > /dev/null 2>&1; checkend_rc=$?
  {
    printf 'observed_epoch=%s\n' "$now"
    printf 'observed_utc=%s\n' "$(_g_utc_from "$now")"
    printf 'notAfter=%s\n' "$notafter"
    printf 'notAfter_epoch=%s\n' "$epoch"
    printf 'seconds_until_notAfter=%s\n' "$remain"
    printf 'signature_algorithm=%s\n' "${alg:--}"
    printf 'openssl_x509_checkend_0_exit=%s\n' "$checkend_rc"
  } > "$f"
  rm -f "$crt"
}

scenario_tick_extra() { # NAME: admission probes and G's timevalidity record, every tick,
  # in the tick's phase; the baseline and post-restore probes are also G's evidence
  # (g-baseline, and admission-restored.txt, recorded but not gated -- design section 4
  # lists no g-restored rule, only g-baseline and g-timevalid).
  admission_probes "$(fault_phase "$1")" "$1"
  _g_timevalid "$1"
  case "$1" in
    baseline)
      _write_result admission-baseline.txt admission_proof_check "$RUN_DIR/admission/baseline" baseline \
        "$POLICY_VALIDATOR_WEBHOOK_NAME" "$SP_VALIDATOR_WEBHOOK_NAME" \
        || die "the healthy baseline did not prove every admission probe; see admission-baseline.txt" ;;
    verify)
      # Not fatal, unlike the baseline: by the verify tick the run is nearly finished, and
      # a failed restore is itself a finding worth the rest of _scenario_finish's evidence
      # rather than an early die. Not validity-gated either (design section 4): recorded.
      _write_result admission-restored.txt admission_proof_check "$RUN_DIR/admission/restored" verify \
        "$POLICY_VALIDATOR_WEBHOOK_NAME" "$SP_VALIDATOR_WEBHOOK_NAME" || true ;;
  esac
}

scenario_post_actions() { # T_mark + 60s: admission probes instead of new workloads (as N)
  admission_probes "$(fault_phase post-actions)" post-actions
  mark admission-probes post-actions
}

# _g_probe_state: refused|serving|other -- a throwaway dry-run against sp-validator (no
# object is ever created), classified by the same pure helpers admission proof-checking
# already uses (admission_refused_by_algorithm, admission_denied_by;
# lib-evidence-scenarios.sh), so the classification logic itself is unit-tested there
# rather than only ever exercised live.
_g_probe_state() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  admission_render serviceprofile-invalid propagation-probe > "$tmp/sp.yaml"
  kubectl create --dry-run=server -f "$tmp/sp.yaml" > "$tmp/sp.resp" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc" >> "$tmp/sp.resp"
  if admission_refused_by_algorithm "$tmp/sp.resp"; then echo refused
  elif admission_denied_by "$SP_VALIDATOR_WEBHOOK_NAME" "$tmp/sp.resp"; then echo serving
  else echo other; fi
  rm -rf "$tmp"
}

# _g_backing_pods: the current pod name(s) of every Deployment in G_BACKING_DEPLOYS
# (deploy_selector, collect-state.sh, shared with N), one per line. Read BEFORE a
# restart, so _g_wait_gone can wait for exactly those names -- unlike N's scale-to-zero
# fault, a rolling restart always leaves a live replacement pod matching the same
# selector, so waiting on the selector itself (wait_pods_gone, N's own shared helper)
# would wait on a pod that is never going to be deleted. Pinning to captured names is
# what N's scale-to-zero case gets for free from having no replacement at all.
_g_backing_pods() {
  local d
  for d in "${G_BACKING_DEPLOYS[@]}"; do
    kubectl -n linkerd get pods -l "$(deploy_selector linkerd "$d")" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
  done
}

# _g_wait_gone LABEL PODS: swap/pods-gone-LABEL.txt -- wait for exactly the pod names in
# PODS (one per line, captured by _g_backing_pods before the restart that is meant to
# replace them) to actually be deleted. `kubectl rollout status` alone is not enough: it
# can report success while the old pod is still Running and serving the old certificate
# (the same gap N's own review required wait_pods_gone to close). PODS empty is not a
# state to tolerate: everything around this point already died loudly on the same
# condition (scenario_fault dies when the backing derivation names no Deployment,
# deploy_selector dies on an empty selector), and a backing Deployment with zero pods
# here contradicts the baseline admission probe that already passed against it -- a
# harness failure, never a "nothing to wait for" success.
_g_wait_gone() {
  local label="$1" pods="$2"
  local f="swap/pods-gone-$label.txt" p args=()
  while IFS= read -r p; do [ -n "$p" ] && args+=("pod/$p"); done <<< "$pods"
  [ "${#args[@]}" -ge 1 ] \
    || die "_g_wait_gone: no pre-restart pod found for ${G_BACKING_DEPLOYS[*]}; see swap/backing.txt"
  capture "$f" kubectl -n linkerd wait --for=delete "${args[@]}" --timeout=120s
}

# _g_apply_cert LABEL DIR: swap/patch-LABEL.txt -- patch profileValidator's Secret to
# DIR/profileValidator.{crt,key} through a JSON merge-patch file built under $CERTS
# (never $RUN_DIR, never printed on a command line: private keys never enter evidence or
# the shell history). Slice 4 Task 3's own install-sha1/patch-secret.txt used the same
# --patch-file shape against this same Secret.
_g_apply_cert() {
  local label="$1" dir="$2"
  local pf="$CERTS/secret-patch-$label.json"
  jq -n --arg crt "$(base64 < "$dir/profileValidator.crt" | tr -d '\n')" \
        --arg key "$(base64 < "$dir/profileValidator.key" | tr -d '\n')" \
    '{data:{"tls.crt":$crt,"tls.key":$key}}' > "$pf"
  capture "swap/patch-$label.txt" kubectl -n linkerd patch secret "$(webhook_secret profileValidator)" \
    --type merge --patch-file "$pf"
}

scenario_fault() { # build the refused certificate, patch it into the live Secret, and
  # restart the backing Deployment so it is actually served (a Secret update alone does
  # not make a running container re-read its mounted certificate)
  local dir="$CERTS/webhooks-algorithm" before_pods
  snap_controlplane fault-before
  mkdir -p "$dir"
  cp "$CERTS/webhooks/ca.crt" "$CERTS/webhooks/ca.key" "$dir/"
  make_webhook_cert_sha1 "$dir" profileValidator "$G_ALGORITHM_CERT_LIFETIME" \
    || die "scenario_fault: could not build the SHA-1-signed candidate; see $dir"
  write_cert webhook-profileValidator-algorithm "$dir/profileValidator.crt"
  mark fault-cert-built "profileValidator: SHA-1-signed leaf, $G_ALGORITHM_CERT_LIFETIME, signed by the configured caBundle CA"
  w_backing_write "$RUN_DIR/swap/backing.txt" profileValidator
  mark swap-backing "$(cat "$RUN_DIR/swap/backing.txt")"
  mapfile -t G_BACKING_DEPLOYS < <(w_backing_deployments "$RUN_DIR/swap/backing.txt")
  [ "${#G_BACKING_DEPLOYS[@]}" -ge 1 ] \
    || die "scenario_fault: profileValidator backing derivation named no Deployment; see swap/backing.txt"
  before_pods="$(_g_backing_pods)"
  _g_apply_cert fault "$dir"
  mark swap-restart "restarting ${G_BACKING_DEPLOYS[*]} so the new certificate is actually served"
  capture swap/restart-fault.txt kubectl -n linkerd rollout restart "${G_BACKING_DEPLOYS[@]/#/deploy/}"
  capture_rollouts swap/rollout-fault.txt linkerd "${G_BACKING_DEPLOYS[@]}"
  _g_wait_gone fault "$before_pods"
  snap_controlplane fault-after
  settle_poll swap/settle-fault.txt _g_probe_state refused "sp-validator fault"
}

scenario_recover() { # patch the original, normally-signed certificate back in, restart,
  # and settle before the verify tick judges it
  local orig="$CERTS/webhooks" before_pods
  mark swap-restore "restoring profileValidator's original, normally-signed certificate"
  before_pods="$(_g_backing_pods)"
  _g_apply_cert restore "$orig"
  mark swap-restart-restore "restarting ${G_BACKING_DEPLOYS[*]} so the original certificate is served again"
  capture swap/restart-restore.txt kubectl -n linkerd rollout restart "${G_BACKING_DEPLOYS[@]/#/deploy/}"
  capture_rollouts swap/rollout-restore.txt linkerd "${G_BACKING_DEPLOYS[@]}"
  _g_wait_gone restore "$before_pods"
  snap_controlplane recover-restore
  settle_poll swap/settle-restore.txt _g_probe_state serving "sp-validator restore"
}
