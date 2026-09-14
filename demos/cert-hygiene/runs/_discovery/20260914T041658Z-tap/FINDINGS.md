# Tap discovery findings

Slice 3 Task 1, Step 5 (design section 8, scenario V). Answers the stop-gate
question: does Linkerd serve the tap serving certificate the lab supplies, and
does tap work while that certificate is valid?

Run: `runs/_discovery/20260914T041658Z-tap`, against a lab reset with the
`tap-long` profile (`TAP_CERT_LIFETIME=24h`) and baseline workloads deployed.

## Does Linkerd serve the supplied tap certificate?

Yes, by every check this discovery ran:

- The `tap-k8s-tls` Secret in `linkerd-viz` holds our supplied certificate.
  `secret_matches_supplied=yes` (X.509 SHA-256 fingerprint comparison, not raw
  bytes -- see the note below).
- The `v1alpha1.tap.linkerd.io` APIService's `caBundle` matches our supplied
  lab CA. `cabundle_matches_supplied_ca=yes`, same fingerprint comparison.
- The `v1alpha1.tap.linkerd.io` APIService is `Available=True`
  (`apiservice_available=True`).
- `linkerd viz check` reports `tap API server has valid cert` and
  `tap API service is running` both passing. The one non-passing tap row,
  `tap API server cert is valid for at least 60 days`, is expected and not a
  failure: `tap-long`'s certificate is deliberately 24 hours, far short of 60
  days, exactly as the equivalent webhook-discovery warning is expected for
  `webhook-long`.
- Every other `linkerd viz check` row passes; the run ends
  `Status check results are OK`.

**SAN versus the actual backing Service** (the task step's instruction to
check before trusting the name): the `v1alpha1.tap.linkerd.io` APIService's
`spec.service` names `tap` in namespace `linkerd-viz`, i.e.
`tap.linkerd-viz.svc` -- exactly the SAN `make_tap_cert` signs.
`apiservice_backing_service=tap.linkerd-viz.svc`,
`tap_cert_san=tap.linkerd-viz.svc`, `san_matches_apiservice_service=yes`.
This was confirmed empirically (rendering `linkerd viz install` and reading
back the rendered APIService) before `make_tap_cert` was written to hardcode
that SAN.

**Fingerprint, not raw bytes:** as with the webhook discovery in slice 2, the
APIService's `caBundle` loses the PEM's trailing newline through the
Helm/API round trip, so a byte-for-byte comparison would report a mismatch for
what is the same certificate. `discover-tap.sh` compares X.509 SHA-256
fingerprints (`openssl x509 -noout -fingerprint -sha256`) throughout, never
raw bytes or a plain `sha256sum` of the PEM text.

## Does tap work while the supplied certificate is valid?

Yes. `linkerd viz tap deploy/server -n lab -o json`, run for 10 seconds while
the baseline probes' traffic was live, returned real, well-formed events:
`tap_event_count=2` complete events captured (a `requestInitEvent` and a
`responseInitEvent`, each compacted to one JSON line by `jq -c .`). Both
events show `probe-http` calling `server`, correctly attributed
(`"deployment":"probe-http"` as the source, `"deployment":"server"` as the
destination), with the mesh identity metadata linkerd-proxy attaches
(`client_id`, `tls`, `authz_name`, etc.) present and populated. This is not an
empty or error stream -- tap is doing real work against `server`'s live
traffic through the certificate we supplied.

(Note for later readers of this record: `linkerd viz tap` has no `--timeout`
flag -- an earlier discovery attempt with `--timeout 10s` failed with `Error:
unknown flag: --timeout`, and a first fix that used the shell's `timeout 10s`
still returned zero events because the command needs `-n lab` -- the baseline
workloads live in the `lab` namespace, not `default`, and `deployment.apps
"server" not found` was the real reason for the earlier empty capture, not an
absence of tap events. Both are fixed in the committed `discover-tap.sh`.)

## Stop gate: PASS

Per the task's stop-gate wording, none of the failure conditions held: the
served certificate is ours (by fingerprint), the APIService is Available, and
tap returned real events while healthy. **V can be run as designed** --
Task 1 is not blocked, and slice 3 proceeds to Task 2.

## Artifacts in this run directory

- `summary.txt` -- the machine-readable facts quoted above.
- `check.txt` -- full `linkerd viz check` transcript.
- `tap-events.json` -- the 2 captured tap events (jq-compacted, one per line).
- `tap-stderr.txt` -- empty in the final run (kept for the record; earlier
  attempts' stderr is what diagnosed the two bugs above, now fixed).
