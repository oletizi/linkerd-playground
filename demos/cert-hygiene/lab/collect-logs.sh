#!/usr/bin/env bash
# Log collection for cert-hygiene scenarios: control-plane and lab-pod container logs,
# the k3s journal (supplementary evidence only, design section 1.4), and per-pod probe
# history. Sourced by lab/collect.sh; do not execute. Failed commands are recorded.

snap_logs() { # NAME: identity logs, then every container of every lab pod. The
  # linkerd-proxy is a native-sidecar INIT container, so both lists are walked.
  local dir="logs/$1" pod c
  capture "$dir/identity.txt" kubectl -n linkerd logs deploy/linkerd-identity -c identity --timestamps
  capture "$dir/identity-proxy.txt" kubectl -n linkerd logs deploy/linkerd-identity -c linkerd-proxy --timestamps
  for pod in $(_lab_pods); do
    for c in $(kubectl -n "$LAB_NS" get pod "$pod" \
        -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null); do
      capture "$dir/$pod-$c.txt" kubectl -n "$LAB_NS" logs "$pod" -c "$c" --timestamps
      capture "$dir/$pod-$c-previous.txt" kubectl -n "$LAB_NS" logs "$pod" -c "$c" --timestamps --previous
    done
  done
}

snap_journal() { # NAME SINCE_EPOCH: API-server side of the run window
  capture "logs/$1/k3s-journal.txt" sudo journalctl -u k3s --since "@$2" --no-pager
}

snap_probes() { # LABEL: probe output from EVERY pod of each probe -- Terminating pods
  # included -- current and previous container, into probes/LABEL/<pod>[-previous].log.
  # Per pod, because a restart replaces the pod that deploy/<probe> would read.
  local label="$1" sel='app in (probe-http,probe-tcp-new,probe-tcp-stream)' pod
  capture "probes/$label/pods.txt" kubectl -n "$LAB_NS" get pods -l "$sel" -o wide
  for pod in $(kubectl -n "$LAB_NS" get pods -l "$sel" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    capture "probes/$label/$pod.log" kubectl -n "$LAB_NS" logs "$pod" -c probe
    capture "probes/$label/$pod-previous.log" kubectl -n "$LAB_NS" logs "$pod" -c probe --previous
  done
}
