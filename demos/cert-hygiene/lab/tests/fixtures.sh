#!/usr/bin/env bash
# Fixture runs for the lab's unit tests. Source after lab/lib-evidence.sh; do not execute.

# make_run DIR SCENARIO COMMIT HARNESS DIRTY: a complete run directory that
# evaluate_validity accepts for SCENARIO (given a valid control at HARNESS, where the
# scenario needs one). Tests then break one thing at a time.
make_run() {
  local d="$1" scenario="$2" t f
  mkdir -p "$d"/{certs,checks,metrics,pods,credentials,webhooks,controlplane,logs/final,logs/pre-recover}
  printf 'demo_repo_commit=%s\ndemo_repo_dirty=%s\nharness_tree_sha256=%s\n' "$3" "$5" "$4" > "$d/git-state.txt"
  printf 'linkerd_cli_version=edge-26.9.1\nlinkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1\n' > "$d/versions.txt"
  printf '2026-09-10T10:00:00Z reset\n2026-09-10T10:05:00Z tick baseline\n2026-09-10T10:40:00Z tick verify\n2026-09-10T10:41:00Z done\n' > "$d/timeline.log"
  for t in baseline verify; do
    for f in "checks/$t-check.txt" "checks/$t-check-proxy.txt" "metrics/$t.txt" "pods/$t.txt" \
        "credentials/$t.txt" "webhooks/$t.txt" "controlplane/$t.txt"; do
      echo x > "$d/$f"
    done
  done
  # -e, not -s: this loop only guarantees every required file exists; it must never
  # overwrite content already written above, including a deliberately empty file.
  while read -r f; do
    [ -e "$d/$f" ] || { mkdir -p "$(dirname "$d/$f")"; echo x > "$d/$f"; }
  done < <(scenario_required_files "$scenario")
  printf 'result=ok\n' > "$d/leaf-lifetime.txt"
  printf 'result=ok\n' > "$d/credential-plan.txt"
  printf 'result=ok\n' > "$d/control-criteria.txt"
  printf 'result=ok\n' > "$d/admission-baseline.txt"
  printf 'result=ok\n' > "$d/admission-restored.txt"
  printf 'result=ok\n' > "$d/k-remaining.txt"
  printf 'result=ok\nok: tap events observed while the certificate was valid\n' > "$d/tap-baseline.txt"
  mkdir -p "$d/s-hard" "$d/recover" "$d/reconnect" "$d/scale"
  printf 'result=met\n' > "$d/s-hard/stage1-condition.txt"
  printf 'component=proxyInjector service=linkerd-proxy-injector deployment=linkerd-proxy-injector\n' > "$d/scale/backing.txt"
  printf '$ kubectl -n linkerd scale deploy/linkerd-proxy-injector --replicas=0\ndeployment.apps/linkerd-proxy-injector scaled\n[exit 0]\n' > "$d/scale/scale-down.txt"
  printf '$ bash -c ... capture_rollouts linkerd linkerd-proxy-injector\n[exit 0]\n' > "$d/scale/rollout-down.txt"
  printf '$ bash -c ... pods-gone linkerd component=proxy-injector\n[exit 0]\n' > "$d/scale/pods-gone.txt"
  printf '$ bash -c ... scale-up linkerd linkerd-proxy-injector=1\ndeployment.apps/linkerd-proxy-injector scaled\n[exit 0]\n' > "$d/scale/scale-up.txt"
  printf '$ bash -c ... capture_rollouts linkerd linkerd-proxy-injector\n[exit 0]\n' > "$d/scale/rollout-up.txt"
  if [ "$scenario" = 30-tap-expiry ]; then
    # V's reconnect has one component (tap), whose Service and namespace are derived from
    # the live APIService rather than a fixed table, so the fixture names them directly.
    printf 'component=tap service=tap deployment=tap\n' > "$d/reconnect/backing.txt"
    printf '$ kubectl -n linkerd-viz rollout restart deploy/tap\ndeployment.apps/tap restarted\n[exit 0]\n' > "$d/reconnect/restart.txt"
    printf '$ bash -c ... capture_rollouts linkerd-viz tap\n[exit 0]\n' > "$d/reconnect/rollout.txt"
  else
    printf 'component=%s service=%s deployment=%s\n' proxyInjector linkerd-proxy-injector linkerd-proxy-injector \
      policyValidator linkerd-policy-validator linkerd-destination profileValidator linkerd-sp-validator linkerd-destination \
      > "$d/reconnect/backing.txt"
    printf '$ kubectl -n linkerd rollout restart deploy/linkerd-proxy-injector deploy/linkerd-destination\ndeployment.apps/linkerd-destination restarted\n[exit 0]\n' > "$d/reconnect/restart.txt"
    printf '$ bash -c ... capture_rollouts linkerd linkerd-proxy-injector linkerd-destination\n[exit 0]\n' > "$d/reconnect/rollout.txt"
  fi
  if [ "$scenario" = 41-webhook-algorithm ]; then
    # G's certificate swap (design section 4): every swap/*.txt must end [exit 0]
    # (g-timevalid's own _exit0_reasons check), and every recorded tick's live
    # certificate must show time remaining -- both ticks here (baseline, verify) get a
    # timevalidity file with a ten-year certificate, matching the profile's own scale.
    mkdir -p "$d/swap" "$d/timevalidity"
    printf 'component=profileValidator service=linkerd-sp-validator deployment=linkerd-destination\n' > "$d/swap/backing.txt"
    for f in patch-fault restart-fault rollout-fault pods-gone-fault patch-restore restart-restore rollout-restore pods-gone-restore; do
      printf '$ kubectl ...\ndone\n[exit 0]\n' > "$d/swap/$f.txt"
    done
    # Self-consistent, not merely plausible: notAfter_epoch is the actual epoch of the
    # notAfter string (date -u -d "Aug 25 15:46:40 2036 GMT" +%s = 2103292000), and
    # seconds_until_notAfter is notAfter_epoch - observed_epoch exactly -- a record that
    # disagrees with itself is the one thing the brief told this task to keep out.
    for t in baseline verify; do
      printf 'observed_epoch=1000000000\nobserved_utc=2001-09-09T01:46:40Z\nnotAfter=Aug 25 15:46:40 2036 GMT\nnotAfter_epoch=2103292000\nseconds_until_notAfter=1103292000\nsignature_algorithm=sha1WithRSAEncryption\nopenssl_x509_checkend_0_exit=0\n' \
        > "$d/timevalidity/$t.txt"
    done
  fi
  printf '$ linkerd upgrade ... | kubectl apply -f -\nsecret/linkerd-identity-issuer configured\n[exit 0]\n' > "$d/recover/linkerd-upgrade.txt"
  printf '$ bash -o pipefail -c linkerd upgrade > m.yaml\n[exit 0]\n' > "$d/recover/plain-render.txt"
  printf '$ kubectl apply -f m.yaml\nsecret/linkerd-proxy-injector-k8s-tls created\n[exit 0]\n' > "$d/recover/plain-apply.txt"
  for f in identity identity-proxy k3s-journal server-1-http server-1-echo server-1-linkerd-proxy server-1-linkerd-init; do
    echo x > "$d/logs/final/$f.txt"
  done
  for f in probe-http-1-probe probe-http-1-probe-previous probe-http-1-linkerd-proxy; do
    echo x > "$d/logs/pre-recover/$f.txt"
  done
  printf 'pod=server-1 proxy=yes containers=linkerd-init,linkerd-proxy,http,echo\n' > "$d/logs/final/pods.txt"
  printf 'pod=probe-http-1 proxy=yes containers=linkerd-proxy,probe\n' > "$d/logs/pre-recover/pods.txt"
}
