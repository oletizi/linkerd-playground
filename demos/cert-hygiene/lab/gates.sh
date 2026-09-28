#!/usr/bin/env bash
# Restart-stage gates and samples (design section 1.6). After a stage restarts its
# workloads, the gate waits until every restarted workload is Ready with its old pods
# gone, serving (where it has a Service of its own name), carrying the current trust
# bundle, holding a leaf obtained since it started, and with its application containers
# Ready. Then every client->server pair gets GATE_SAMPLES fresh-connection samples. A gate
# that times out leaves the stage's cells unclassified, with the unmet conditions; it
# never invalidates a run. Source after lab/collect.sh with RUN_DIR set; do not execute.

GATE_PAIRS=("A probe-tcp-new server" "B probe-tcp-new-b server") # pair client server

lab_deployments() { kubectl -n "$LAB_NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }

_gate_file() { echo "$RUN_DIR/gates/$1.txt"; }
_yn() { if [ "$1" = "$2" ]; then echo yes; else echo no; fi; } # A B: yes when equal
_csv_or_dash() { if [ $# -eq 0 ]; then echo -; else (IFS=,; echo "$*"); fi; } # ITEM...

_trust_now() { # the trust-roots ConfigMap hash, as pods' trust-root-sha256 annotations
  # carry it (hashed from a file: a command substitution would strip the final newline);
  # "-" when unreadable, which leaves the trust condition unmet
  local tmp
  tmp="$(mktemp)"
  if kubectl -n linkerd get cm linkerd-identity-trust-roots -o jsonpath='{.data.ca-bundle\.crt}' > "$tmp" 2>/dev/null; then
    sha256sum < "$tmp" | cut -d' ' -f1
  else
    echo -
  fi
  rm -f "$tmp"
}

_trust_yn() { # WANT GOT: yes when WANT is a real hash (not "-") and equals GOT; two failed
  # reads (WANT and GOT both "-") must never compare equal and count as met
  if [ "$1" != - ] && [ "$1" = "$2" ]; then echo yes; else echo no; fi
}

_deploy_pods() { # DEPLOY: "name uid start_epoch deleting ready trust app_ready" per pod;
  # nothing when the pod list is unreadable
  local js
  js="$(kubectl -n "$LAB_NS" get pods -l "app=$1" -o json 2>/dev/null)" || return 0
  jq -r '.items[] | [
      .metadata.name, .metadata.uid,
      ((.status.startTime // "") | if . == "" then "0" else (fromdateiso8601 | tostring) end),
      (if .metadata.deletionTimestamp then "yes" else "no" end),
      (([.status.conditions[]? | select(.type == "Ready") | .status] | first) // "False"),
      (.metadata.annotations["linkerd.io/trust-root-sha256"] // "-"),
      (if ([.status.containerStatuses[]?.ready] | length) > 0 and ([.status.containerStatuses[]?.ready] | all)
       then "yes" else "no" end)
    ] | join(" ")' <<< "$js"
}

_current_pod() { _deploy_pods "$1" | awk '$4 == "no" { p = $1 } END { print p }'; } # DEPLOY

_leaf_state() { # POD: "refresh expiry ok err" from its proxy's metrics; "- - - -" if unreadable
  local body
  if ! body="$(kubectl get --raw "/api/v1/namespaces/$LAB_NS/pods/$1:4191/proxy/metrics" 2>/dev/null)"; then
    echo "- - - -"; return 0
  fi
  awk '$1 == "control_identity_cert_refresh_timestamp_seconds" { r = $2 }
       $1 == "control_identity_cert_expiration_timestamp_seconds" { e = $2 }
       $1 == "control_identity_cert_refreshes_total{result=\"ok\"}" { ok = $2 }
       $1 == "control_identity_cert_refreshes_total{result=\"error\"}" { er = $2 }
       END { printf "%s %s %s %s\n", (r == "" ? "-" : r), (e == "" ? "-" : e), (ok == "" ? "-" : ok), (er == "" ? "-" : er) }' <<< "$body"
}

_serving() { # DEPLOY POD: yes|no when a Service named DEPLOY exists, n/a otherwise
  local n
  kubectl -n "$LAB_NS" get svc "$1" >/dev/null 2>&1 || { echo n/a; return 0; }
  n="$(kubectl -n "$LAB_NS" get endpointslices -l "kubernetes.io/service-name=$1" -o json 2>/dev/null \
    | jq --arg p "$2" '[.items[].endpoints[]? | select(.targetRef.name == $p and .conditions.ready == true)] | length' || true)"
  if [ "${n:-0}" -gt 0 ]; then
    echo yes
  else
    echo no
  fi
}

_gate_check() { # STAGE DEPLOY TRUST: one check line; returns 0 when all five conditions hold
  local stage="$1" d="$2" trust="$3" before now name uid start del ready ptrust app trust_yn
  local new=- nstart=0 nready=False ntrust=- napp=no old=no serving=n/a refresh=- expiry=- unmet=() leaf=no
  before="$(awk -v d="$d" '$1 == "before" && $2 == d { print $4 }' "$(_gate_file "$stage")")"
  now="$(date -u +%s)"
  while read -r name uid start del ready ptrust app; do
    [ -n "$name" ] || continue
    if grep -qx "$uid" <<< "$before"; then old=yes
    elif [ "$del" = no ]; then new="$name"; nstart="$start"; nready="$ready"; ntrust="$ptrust"; napp="$app"; fi
  done < <(_deploy_pods "$d")
  if [ "$new" = - ] || [ "$nready" != True ] || [ "$old" = yes ]; then unmet+=(ready); fi
  if [ "$new" != - ]; then
    serving="$(_serving "$d" "$new")"
    read -r refresh expiry _ _ < <(_leaf_state "$new")
    if awk -v r="$refresh" -v e="$expiry" -v s="$nstart" -v n="$now" \
        'BEGIN { exit !(r != "-" && e != "-" && r + 0 > s + 0 && e + 0 > n + 0) }'; then leaf=yes; fi
  else
    serving=unknown # no new pod yet: serving cannot be checked, so it is never met
  fi
  case "$serving" in yes | n/a) ;; *) unmet+=(serving) ;; esac
  trust_yn="$(_trust_yn "$trust" "$ntrust")"
  [ "$trust_yn" = yes ] || unmet+=(trust)
  [ "$leaf" = yes ] || unmet+=(leaf)
  [ "$napp" = yes ] || unmet+=(app-ready)
  printf 'check %s %s pod=%s ready=%s old_gone=%s serving=%s trust=%s leaf=%s app_ready=%s refresh=%s expiry=%s unmet=%s\n' \
    "$(_utc)" "$d" "$new" "$(_yn "$nready" True)" "$(_yn "$old" no)" \
    "$serving" "$trust_yn" "$leaf" "$napp" "$refresh" "$expiry" "$(_csv_or_dash "${unmet[@]}")"
  [ ${#unmet[@]} -eq 0 ]
}

# restart_and_gate STAGE DEPLOY...: restart DEPLOYs, gate them, then sample every pair.
restart_and_gate() {
  local stage="$1" f d line trust pass deadline args=() unmet=()
  shift
  [ $# -ge 1 ] || die "restart_and_gate: at least one DEPLOY required"
  f="$(_gate_file "$stage")"
  [ ! -e "$f" ] || die "restart_and_gate: $f exists; evidence is written once"
  mkdir -p "$RUN_DIR/gates"
  {
    printf 'stage=%s\nrestarted=%s\nstarted_at=%s\nstarted_epoch=%s\n' "$stage" "$(IFS=,; echo "$*")" "$(_utc)" "$(date -u +%s)"
    for d in "$@"; do _deploy_pods "$d" | awk -v d="$d" '{ print "before", d, $1, $2 }'; done
  } > "$f"
  for d in "$@"; do args+=("deploy/$d"); done
  mark restart "$stage: $*"
  capture "restarts/$stage.txt" kubectl -n "$LAB_NS" rollout restart "${args[@]}"
  deadline=$(( $(date -u +%s) + GATE_TIMEOUT_S ))
  while :; do
    trust="$(_trust_now)"
    pass=yes; unmet=()
    for d in "$@"; do
      if line="$(_gate_check "$stage" "$d" "$trust")"; then :; else pass=no; unmet+=("$d:${line##* unmet=}"); fi
      echo "$line" >> "$f"
    done
    [ "$pass" = no ] || break
    [ "$(date -u +%s)" -lt "$deadline" ] || break
    sleep "$GATE_POLL_S"
  done
  printf 'expected_trust_sha256=%s\n' "$trust" >> "$f"
  if [ "$pass" = yes ]; then
    printf 'gate=pass\ngate_at=%s\ngate_epoch=%s\n' "$(_utc)" "$(date -u +%s)" >> "$f"
    mark gate "$stage pass"
  else
    printf 'gate=timeout\nunmet=%s\ngate_at=%s\ngate_epoch=%s\n' "$(IFS=' '; echo "${unmet[*]}")" "$(_utc)" "$(date -u +%s)" >> "$f"
    mark gate "$stage timeout after ${GATE_TIMEOUT_S}s: ${unmet[*]}"
  fi
  stage_samples "$stage"
}

# stage_samples STAGE: GATE_SAMPLES fresh-connection samples per pair, the pairs'
# endpoint certificate state, and one cell line per pair.
stage_samples() {
  local stage="$1" f gate status pair name client server cpod spod n out ok fail role d state
  f="$(_gate_file "$stage")"
  if [ ! -e "$f" ]; then
    mkdir -p "$RUN_DIR/gates"
    printf 'stage=%s\nrestarted=-\nstarted_at=%s\nstarted_epoch=%s\ngate=none\n' "$stage" "$(_utc)" "$(date -u +%s)" > "$f"
    mark stage "$stage: samples, no restarts"
  fi
  gate="$(awk -F= '$1 == "gate" { v = $2 } END { print v }' "$f")"
  status=classified
  [ "$gate" != timeout ] || status=unclassified
  for pair in "${GATE_PAIRS[@]}"; do
    read -r name client server <<< "$pair"
    cpod="$(_current_pod "$client")"; spod="$(_current_pod "$server")"
    ok=0; fail=0
    for ((n = 1; n <= GATE_SAMPLES; n++)); do
      out="$(timeout 20 kubectl -n "$LAB_NS" exec "$cpod" -c probe -- sh /probes/sample-once.sh "$n" 2>&1)" \
        || out="fail exec_rc=$? $(tr '\n' ' ' <<< "$out")"
      if [ "$out" = ok ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
      printf 'sample %s pair=%s client=%s server=%s n=%s %s\n' "$(_utc)" "$name" "$cpod" "$spod" "$n" "$(tr '\n' ' ' <<< "$out")" >> "$f"
      sleep "$GATE_SAMPLE_INTERVAL_S"
    done
    printf 'cell pair=%s ok=%s fail=%s status=%s\n' "$name" "$ok" "$fail" "$status" >> "$f"
  done
  for role in clientA:probe-tcp-new clientB:probe-tcp-new-b server:server; do
    d="${role#*:}"; cpod="$(_current_pod "$d")"
    read -r -a state < <(_leaf_state "$cpod")
    printf 'leaf %s role=%s pod=%s refresh=%s expiry=%s ok=%s err=%s\n' \
      "$(_utc)" "${role%%:*}" "$cpod" "${state[0]}" "${state[1]}" "${state[2]}" "${state[3]}" >> "$f"
  done
}
