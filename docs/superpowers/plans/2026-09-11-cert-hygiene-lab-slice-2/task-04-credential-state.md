# Task 4: Collector split and credential state

Part of the [slice 2 plan](README.md). Read its Global Constraints first.

**Goal:** The collecting half of design § 1.3. Every tick writes `credentials/<tick>.txt`: the trust-roots ConfigMap's SHA-256, the issuer certificate's identity, and each webhook serving certificate's identity (DER SHA-256, serial, `notAfter`, SANs), plus a combined webhook fingerprint that the plan walk compares. Runs that supply webhook certificates record them in `certs/`. `collect.sh` (221 lines, growing in Task 5) is split into three files first.

**Files:**
- Create: `demos/cert-hygiene/lab/collect-state.sh`, `demos/cert-hygiene/lab/collect-logs.sh`
- Modify: `demos/cert-hygiene/lab/collect.sh` (move functions out; source the two new files; `tick` writes credential state)
- Modify: `demos/cert-hygiene/lab/scenario-common.sh` (write supplied webhook certificates to `certs/`)

**Interfaces:**
- Consumes: Task 1 (`WEBHOOK_COMPONENTS`, `webhook_secret`), Task 2 (`cert_facts`), `_record` and `capture` (collector).
- Produces:
  - `collect-state.sh`: `_decode_cert`, `snap_secret`, `snap_trust` (moved unchanged); `_cert_from_secret PREFIX SECRET JSONPATH_KEY`; `snap_credentials NAME`.
  - `collect-logs.sh`: `snap_logs`, `snap_journal`, `snap_probes` (moved unchanged here; Tasks 5–6 change them).
  - `credentials/<tick>.txt` (contract read by `credential_state_key`): `sampled_at_epoch=`, `trust_roots_sha256=`, the five `issuer_*` facts, the five `webhook_<component>_*` facts per component, and `webhooks_sha256=<sha256 of "<pi>,<pv>,<sp>" DER fingerprints in WEBHOOK_COMPONENTS order>`. A failed read appears as a `[<what> failed: exit N] …` line, never as a blank value.
  - `tick NAME` also writes `credentials/NAME.txt`.
  - Runs whose profile sets `WEBHOOK_CERT_LIFETIMES` write `certs/webhook-ca.{pem,txt}` and `certs/webhook-<component>.{pem,txt}`.

- [ ] **Step 1: Create `demos/cert-hygiene/lab/collect-logs.sh`**

Header:

```bash
#!/usr/bin/env bash
# Log collection for cert-hygiene scenarios: control-plane and lab-pod container logs,
# the k3s journal (supplementary evidence only, design section 1.4), and per-pod probe
# history. Sourced by lab/collect.sh; do not execute. Failed commands are recorded.
```

Below it, **move** from `collect.sh` unchanged: `snap_logs` (with its comment), `snap_journal`, `snap_probes`.

- [ ] **Step 2: Create `demos/cert-hygiene/lab/collect-state.sh`**

Header, then **move** from `collect.sh` unchanged: `_decode_cert`, `snap_secret`, `snap_trust`. Then append the new functions:

```bash
#!/usr/bin/env bash
# Credential and configuration state for cert-hygiene scenarios: the issuer Secret, the
# trust roots, and the credential state the plan walk reads (design section 1.3).
# Sourced by lab/collect.sh; do not execute. Only certificate fields are ever read from
# a Secret, never a key field; assert_no_keys proves it for every run.
```

```bash
_b64_cert_facts() { base64 -d < "$2" | cert_facts "$1"; } # PREFIX B64_FILE

# _cert_from_secret PREFIX SECRET JSONPATH_KEY: cert_facts of the certificate held
# under JSONPATH_KEY (escaped, e.g. 'tls\.crt') in the linkerd-namespace Secret SECRET.
_cert_from_secret() {
  local prefix="$1" secret="$2" key="$3" tmp
  tmp="$(mktemp)"
  if _record "$secret $key read" kubectl -n linkerd get secret "$secret" -o jsonpath="{.data.$key}" > "$tmp"; then
    _record "$secret certificate decode and inspection" _b64_cert_facts "$prefix" "$tmp" || true
  else
    cat "$tmp"
  fi
  rm -f "$tmp"
}

# snap_credentials NAME: the credential state (design section 1.3) -> credentials/NAME.txt.
snap_credentials() {
  local f="$RUN_DIR/credentials/$1.txt" tmp comp fp joined=""
  mkdir -p "$RUN_DIR/credentials"
  tmp="$(mktemp)"
  {
    printf 'sampled_at_epoch=%s\n' "$(date -u +%s)"
    if _record "trust-roots ConfigMap read" kubectl -n linkerd get cm linkerd-identity-trust-roots \
        -o jsonpath='{.data.ca-bundle\.crt}' > "$tmp"; then
      printf 'trust_roots_sha256=%s\n' "$(sha256sum < "$tmp" | cut -d' ' -f1)"
    else
      cat "$tmp"
    fi
    _cert_from_secret issuer linkerd-identity-issuer 'crt\.pem'
    for comp in "${WEBHOOK_COMPONENTS[@]}"; do
      _cert_from_secret "webhook_$comp" "$(webhook_secret "$comp")" 'tls\.crt'
    done
  } > "$f"
  rm -f "$tmp"
  for comp in "${WEBHOOK_COMPONENTS[@]}"; do
    fp="$(awk -F= -v k="webhook_${comp}_sha256" '$1 == k { print $2; exit }' "$f")"
    if [ -z "$fp" ]; then
      printf '[webhooks_sha256 not computed: no webhook_%s_sha256 in this snapshot]\n' "$comp" >> "$f"
      return 0
    fi
    joined="${joined:+$joined,}$fp"
  done
  printf 'webhooks_sha256=%s\n' "$(printf '%s' "$joined" | sha256sum | cut -d' ' -f1)" >> "$f"
}
```

The fingerprint lookup uses `awk`, which exits 0 when the key is missing. A `grep | cut` pipeline would fail under `set -e` and `pipefail` and end an hour-long run on one failed Secret read, instead of recording it.

`trust_roots_sha256` is computed exactly as `snap_trust`'s `configmap_sha256`, which equals the pods' `linkerd.io/trust-root-sha256` annotation (slice-1 run `runs/05-issuer-expiry/20260911T021157Z/trust/baseline.txt`).

- [ ] **Step 3: Trim `demos/cert-hygiene/lab/collect.sh` and extend `tick`**

Delete the moved functions (`_decode_cert`, `snap_secret`, `snap_trust`, `snap_logs`, `snap_journal`, `snap_probes`). Append at the end of the file:

```bash

# The rest of the collector, split by concern to keep each file short.
_COLLECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_COLLECT_DIR/collect-state.sh"
# shellcheck source=/dev/null
. "$_COLLECT_DIR/collect-logs.sh"
```

Replace `tick` with:

```bash
tick() { # NAME: the files every tick must have (see evaluate_validity)
  local name="$1"
  mark tick "$name"
  capture "checks/$name-check.txt" linkerd check --wait 20s &
  capture "checks/$name-check-proxy.txt" linkerd check --proxy --wait 20s &
  snap_metrics "$name"
  capture "pods/$name.txt" kubectl get pods -A -o wide
  snap_credentials "$name"
  wait
}
```

- [ ] **Step 4: Record supplied webhook certificates in `scenario-common.sh`**

In `run_scenario`, after the line `write_cert issuer-initial "$CERTS/issuer.crt"`, add:

```bash
  if [ -n "$WEBHOOK_CERT_LIFETIMES" ]; then
    write_cert webhook-ca "$CERTS/webhooks/ca.crt"
    for comp in "${WEBHOOK_COMPONENTS[@]}"; do write_cert "webhook-$comp" "$CERTS/webhooks/$comp.crt"; done
  fi
```

and add `comp` to the `local` line of `run_scenario`.

- [ ] **Step 5: Syntax, shellcheck, tests, line counts**

Run: `cd demos/cert-hygiene && for f in lab/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done && wc -l lab/collect*.sh && bash scripts/in-lab.sh lab/shell.sh -c 'shellcheck -x lab/*.sh scenarios/*.sh'`
Expected: no syntax errors; each `collect*.sh` under 300 lines; no shellcheck findings.

Run: `just demo cert-hygiene test`
Expected: four `PASS:` lines.

- [ ] **Step 6: Exercise it against a live lab**

Run: `just demo cert-hygiene reset long` (repeat `bash demos/cert-hygiene/scripts/wait-log.sh .lab-logs/reset.log 540` if the wait times out), then `just demo cert-hygiene deploy baseline`, then `just demo cert-hygiene snapshot`.
Expected: the snapshot command ends `snapshot written to .lab-logs/snapshot-<stamp>`.

Run: `cat demos/cert-hygiene/.lab-logs/snapshot-<stamp>/credentials/manual.txt`
Expected: no line starting `[`; `trust_roots_sha256=`, five `issuer_*` lines (`issuer_sans=` may be `-`), five lines per webhook component with `webhook_proxyInjector_sans=DNS:linkerd-proxy-injector.linkerd.svc` (Linkerd-generated certificates carry the Service name), and a final `webhooks_sha256=` line.

Run: `bash demos/cert-hygiene/scripts/in-lab.sh lab/shell.sh -c '. lab/lib-lab.sh && credential_state_key .lab-logs/snapshot-<stamp>/credentials/manual.txt trust issuer webhooks'`
Expected: one line `trust=<hex> issuer=<hex> webhooks=<hex>`.

`.lab-logs/` is not evidence and is not committed.

- [ ] **Step 7: Commit**

```bash
git add demos/cert-hygiene/lab
git commit -m "cert-hygiene record credential state on every tick"
git push
```
