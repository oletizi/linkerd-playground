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
  printf 'result=ok\n' > "$d/k-remaining.txt"
  mkdir -p "$d/s-hard" "$d/recover"
  printf 'result=met\n' > "$d/s-hard/stage1-condition.txt"
  printf '$ linkerd upgrade ... | kubectl apply -f -\nsecret/linkerd-identity-issuer configured\n[exit 0]\n' > "$d/recover/linkerd-upgrade.txt"
  printf '$ bash -o pipefail -c linkerd upgrade > m.yaml\n[exit 0]\n' > "$d/recover/plain-render.txt"
  printf '$ kubectl apply -f m.yaml\nsecret/linkerd-proxy-injector-k8s-tls created\n[exit 0]\n' > "$d/recover/plain-apply.txt"
  for f in identity identity-proxy k3s-journal server-1-http server-1-echo server-1-linkerd-proxy server-1-linkerd-init; do
    echo x > "$d/logs/final/$f.txt"
  done
  for f in probe-http-1-probe probe-http-1-probe-previous probe-http-1-linkerd-proxy; do
    echo x > "$d/logs/pre-recover/$f.txt"
  done
}
