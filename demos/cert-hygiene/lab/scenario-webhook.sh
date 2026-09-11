#!/usr/bin/env bash
# Scenario W, shared by 02-webhook-expiry-ignore and 02-webhook-expiry-fail (design
# section 3). Lab-supplied webhook serving certificates expire 10 minutes apart:
# proxy-injector at T1 (= T_mark), policy-validator at T2, sp-validator at T3. Admission
# probes run at baseline and on every tick; each reaches exactly one webhook. At T3 +
# W_POST_WINDOW_S (scenario_post_window_end) the forced-reconnect phase restarts the
# Deployments behind the webhooks and probes for W_RECONNECT_WINDOW_S; recovery then
# starts and is observed as it branches. Source after lab/scenario-common.sh; do not execute.
# shellcheck source=/dev/null
. "$LAB_DIR/admission.sh"

W_EXPIRED_MARKED=""
W_RECONNECT_EPOCH=""   # when the reconnect rollouts finished; reconnect-NNNN counts from it

_w_not_after() { cert_not_after_epoch "$CERTS/webhooks/$1.crt"; } # COMPONENT

scenario_mark_epoch() { # T1: the proxy-injector certificate's notAfter
  _w_not_after proxyInjector
}

scenario_post_window_end() { # T3 + W's own post-expiry window (design section 3)
  echo $(( $(_w_not_after profileValidator) + W_POST_WINDOW_S ))
}

_w_phase() { # TICK: the admission phase for a probe set taken now
  local now
  now="$(date -u +%s)"
  case "$1" in
    baseline) echo baseline ;;
    verify|recover-*) echo recovered ;;
    reconnect-*) printf 'reconnect-%04d\n' $(( now - W_RECONNECT_EPOCH )) ;;
    *) if [ "$now" -lt "$T_MARK" ]; then echo pre-expiry; else printf 'post-%04d\n' $(( now - T_MARK )); fi ;;
  esac
}

_w_mark_expiries() { # TICK: mark each webhook's expiry phase at the first tick that STARTED
  # after it (TICK_START_EPOCH), so that tick's linkerd check ran after the expiry
  local comp exp
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    exp="$(_w_not_after "$comp")"
    if [ "$TICK_START_EPOCH" -ge "$exp" ] && [[ " $W_EXPIRED_MARKED " != *" $comp "* ]]; then
      mark webhook-expired "$comp notAfter=$(date -u -d "@$exp" +%Y-%m-%dT%H:%M:%SZ); first tick starting after it: $1, started $(date -u -d "@$TICK_START_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
      W_EXPIRED_MARKED="$W_EXPIRED_MARKED $comp"
    fi
  done
}

scenario_tick_extra() { # NAME: admission probes on every tick, in the tick's phase
  _w_mark_expiries "$1"
  admission_probes "$(_w_phase "$1")" "$1"
  if [ "$1" = baseline ]; then
    _write_result admission-baseline.txt admission_proof_check "$RUN_DIR/admission/baseline" baseline \
      "$POLICY_VALIDATOR_WEBHOOK_NAME" "$SP_VALIDATOR_WEBHOOK_NAME" \
      || die "the healthy baseline did not prove every admission probe; see admission-baseline.txt"
  fi
}

scenario_post_actions() { # T_mark + 60s: admission probes instead of new workloads
  admission_probes "$(_w_phase post-actions)" post-actions
  mark admission-probes post-actions
}

_w_render_apply() { # LABEL [linkerd upgrade args...]: render into the VM-only cert set and
  # redact there; scan the redacted copy (key_scan) and die on any hit (fails closed).
  # Only a clean copy reaches RUN_DIR, and only then is the manifest applied.
  local label="$1" m="$CERTS/recover-$1.yaml" r="$CERTS/recover-$1-redacted.yaml" hits
  shift
  capture "recover/$label-render.txt" bash -o pipefail -c "$(_w_upgrade_cmd "$m" "$@")"
  redact_manifest "$m" > "$r" || die "_w_render_apply: cannot redact $m"
  hits="$(key_scan "$r")" \
    || die "_w_render_apply: the redacted $label manifest still holds private key material ($hits); not recorded, not applied"
  cp "$r" "$RUN_DIR/recover/$label-manifest.yaml"
  capture "recover/$label-apply.txt" kubectl apply -f "$m"
}

_w_serving_now() { # one line: whether each webhook serves correctly (server-side dry runs)
  local tmp inj=no pol=no sp=no rc
  tmp="$(mktemp -d)"
  admission_render inject-probe propagation-probe > "$tmp/pod.yaml"
  admission_render policy-invalid propagation-probe > "$tmp/pol.yaml"
  admission_render serviceprofile-invalid propagation-probe > "$tmp/sp.yaml"
  if kubectl create --dry-run=server -o yaml -f "$tmp/pod.yaml" 2>&1 | grep -qE 'name: linkerd-proxy$'; then inj=yes; fi
  rc=0; kubectl create --dry-run=server -f "$tmp/pol.yaml" > "$tmp/pol.resp" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc" >> "$tmp/pol.resp"
  if admission_denied_by "$POLICY_VALIDATOR_WEBHOOK_NAME" "$tmp/pol.resp"; then pol=yes; fi
  rc=0; kubectl create --dry-run=server -f "$tmp/sp.yaml" > "$tmp/sp.resp" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc" >> "$tmp/sp.resp"
  if admission_denied_by "$SP_VALIDATOR_WEBHOOK_NAME" "$tmp/sp.resp"; then sp=yes; fi
  rm -rf "$tmp"
  echo "injection=$inj policy_denied=$pol sp_denied=$sp"
}

_w_settle() { # LABEL: control-plane rollouts, webhook propagation, then the state
  local f="$RUN_DIR/recover/$1-propagation.txt" deadline s
  capture_cp_rollouts "recover/$1-rollout.txt"
  deadline=$(( $(date -u +%s) + W_PROPAGATION_TIMEOUT_S ))
  while :; do
    s="$(_w_serving_now)"
    printf '%s %s\n' "$(_utc)" "$s" >> "$f"
    if [ "$s" = "injection=yes policy_denied=yes sp_denied=yes" ]; then mark propagated "$1: all three webhooks serving"; break; fi
    if [ "$(date -u +%s)" -ge "$deadline" ]; then mark propagated "$1: not all serving after ${W_PROPAGATION_TIMEOUT_S}s: $s"; break; fi
    sleep 10
  done
  capture "recover/$1-check.txt" linkerd check --wait 20s
  snap_controlplane "recover-$1"
  snap_webhooks "recover-$1"
}

_w_facts() { # LABEL SUPPLIED_DIR: recover/LABEL-facts.txt, the inputs of w_branch_classify.
  # Cluster reads are recorded, never fatal: w_fact_line records a missing Secret
  # certificate as "-" and one that is not a readable certificate as "unreadable".
  local label="$1" sup="$2" f="$RUN_DIR/recover/$1-facts.txt" tmp i comp sfp now
  tmp="$(mktemp -d)"
  now="$(date -u +%s)"
  : > "$f"
  for i in "${!WEBHOOK_COMPONENTS[@]}"; do
    comp="${WEBHOOK_COMPONENTS[i]}"
    sfp="$(cert_facts s < "$sup/$comp.crt" | awk -F= '$1 == "s_sha256" { print $2 }')" \
      || die "_w_facts: cannot read the lab-supplied certificate $sup/$comp.crt"
    kubectl -n linkerd get secret "$(webhook_secret "$comp")" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
      | base64 -d > "$tmp/$comp.crt" 2>/dev/null || true
    kubectl get "${WEBHOOK_CONFIGS[i]}" -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null \
      | base64 -d > "$tmp/$comp-ca.pem" 2>/dev/null || true
    w_fact_line "$comp" "$sfp" "$tmp/$comp.crt" "$tmp/$comp-ca.pem" "$now" >> "$f"
  done
  rm -rf "$tmp"
  admission_probes recovered "recover-$label"
  if admission_proof_check "$RUN_DIR/admission/recovered" "recover-$label" \
      "$POLICY_VALIDATOR_WEBHOOK_NAME" "$SP_VALIDATOR_WEBHOOK_NAME" >> "$f"; then
    echo admission=healthy >> "$f"
  else
    echo admission=unhealthy >> "$f"
  fi
}

_w_backing() { # reconnect/backing.txt: each webhook Service's backing Deployment(s), derived
  # now from its selector (w_backing_line); a failed read is recorded, never fatal
  local f="$RUN_DIR/reconnect/backing.txt" tmp comp svc derr=""
  tmp="$(mktemp -d)"
  mkdir -p "$RUN_DIR/reconnect"
  : > "$f"
  _record "linkerd Deployment listing" kubectl -n linkerd get deploy -o json > "$tmp/d.json" || derr="$(cat "$tmp/d.json")"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    svc="$(webhook_service "$comp")"
    if [ -n "$derr" ]; then w_backing_line "$comp" "$svc" "$tmp/d.json" "$tmp/d.json" "$derr" >> "$f"
    elif _record "Service $svc read" kubectl -n linkerd get svc "$svc" -o json > "$tmp/s.json"; then
      w_backing_line "$comp" "$svc" "$tmp/s.json" "$tmp/d.json" >> "$f"
    else w_backing_line "$comp" "$svc" "$tmp/s.json" "$tmp/d.json" "$(cat "$tmp/s.json")" >> "$f"; fi
  done
  rm -rf "$tmp"
}

_w_reconnect() { # the forced-reconnect phase (design section 3): restart each Deployment behind
  # the webhooks once, so the API server must open new connections, then probe. No lab
  # workload is restarted and no credential changes: the pods still mount the expired certs.
  local ds=()
  snap_controlplane reconnect-before
  _w_backing
  mark reconnect-backing "$(paste -sd';' "$RUN_DIR/reconnect/backing.txt")"
  mapfile -t ds < <(w_backing_deployments "$RUN_DIR/reconnect/backing.txt")
  mark reconnect-restart "kubectl rollout restart: ${ds[*]:-no backing Deployment}"
  if [ "${#ds[@]}" -gt 0 ]; then
    capture reconnect/restart.txt kubectl -n linkerd rollout restart "${ds[@]/#/deploy/}"
  else
    capture reconnect/restart.txt bash -c 'echo "no backing Deployment derived; see reconnect/backing.txt"; exit 1'
  fi
  capture_rollouts reconnect/rollout.txt "${ds[@]}"
  W_RECONNECT_EPOCH="$(date -u +%s)"
  mark reconnect-rolled-out "rollout.txt $(tail -n 1 "$RUN_DIR/reconnect/rollout.txt")"
  snap_controlplane reconnect-after
  admission_probes reconnect-0000 reconnect-0
  observe_until $(( W_RECONNECT_EPOCH + W_RECONNECT_WINDOW_S )) reconnect
  mark reconnect-end "after ${W_RECONNECT_WINDOW_S}s of reconnect probes; recovery follows"
}

scenario_recover() { # the forced-reconnect phase, then recovery
  local branch comp args=()
  _w_reconnect
  snap_controlplane recover-before
  snap_webhooks recover-before
  mark recover-delete "delete the three webhook Secrets (Linkerd's rotating-webhooks guide)"
  capture recover/delete-secrets.txt kubectl -n linkerd delete secret \
    "$(webhook_secret proxyInjector)" "$(webhook_secret policyValidator)" "$(webhook_secret profileValidator)"
  mark recover-plain "plain linkerd upgrade, rendered, redacted, applied"
  _w_render_apply plain
  _w_settle plain
  _w_facts plain "$CERTS/webhooks"
  branch="$(w_branch_classify "$RUN_DIR/recover/plain-facts.txt")"
  {
    echo "$branch"
    echo "rule: ii if every Secret certificate is the supplied one; i if none is and each is valid now, verifies against its caBundle, and the post-propagation admission probes proved all three webhooks; iii otherwise"
    cat "$RUN_DIR/recover/plain-facts.txt"
  } > "$RUN_DIR/recover/branch.txt"
  mark recover-branch "$branch"
  [ "$branch" != branch=i ] || return 0
  make_webhook_certs "$CERTS/webhooks-fresh" \
    "proxyInjector=$W_FRESH_WEBHOOK_LIFETIME policyValidator=$W_FRESH_WEBHOOK_LIFETIME profileValidator=$W_FRESH_WEBHOOK_LIFETIME"
  write_cert webhook-fresh-ca "$CERTS/webhooks-fresh/ca.crt"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do write_cert "webhook-fresh-$comp" "$CERTS/webhooks-fresh/$comp.crt"; done
  mapfile -t args < <(webhook_install_args "$CERTS/webhooks-fresh")
  mark recover-supplied "linkerd upgrade with freshly generated lab-supplied webhook credentials (--set-file)"
  _w_render_apply supplied "${args[@]}"
  _w_settle supplied
  _w_facts supplied "$CERTS/webhooks-fresh"
}
