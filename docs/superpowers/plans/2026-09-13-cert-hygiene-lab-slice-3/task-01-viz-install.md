# Task 1: Viz install and the tap credential

Part of the [slice 3 plan](README.md). Read its Global Constraints first.

**Goal:** the lab can install Linkerd Viz with a tap serving certificate the lab supplies and controls the lifetime of, the way `webhook-short` already does for the admission webhooks. Nothing in the harness installs Viz today.

**This task has a stop gate** (Step 5).

**Design:** slice 2 design § 8. `linkerd viz install --set-file` is recorded there as available, and the VM had about 5 GB free.

**Files:**
- Create: `demos/cert-hygiene/lab/profiles/tap-short.env`, `demos/cert-hygiene/lab/profiles/tap-long.env` (discovery only, 24-hour tap certificate so a slow check never races the expiry)
- Modify: `demos/cert-hygiene/lab/lib-webhook.sh` (tap is another lab-supplied serving credential; reuse the CA and signing helpers rather than writing new ones)
- Modify: `demos/cert-hygiene/lab/reset.sh` (install Viz when the profile asks for it), `demos/cert-hygiene/lab/lib-lab.sh` (`load_profile` validates the new key)
- Modify: `lib/linkerd.sh` (a `linkerd_viz_install` beside the existing install helper)
- Create: `demos/cert-hygiene/lab/discover-tap.sh`, and the discovery record under `demos/cert-hygiene/runs/_discovery/<stamp>-tap/`
- Modify: `demos/cert-hygiene/Justfile` (a `discover-tap` verb)

**Interfaces:**
- Profile key: `TAP_CERT_LIFETIME` — empty means no Viz, a duration means install Viz with a lab-supplied tap certificate of that lifetime. Every profile must define it, empty where unused, exactly as `WEBHOOK_CERT_LIFETIMES` is handled.
- `make_tap_cert DIR LIFETIME` signs `DIR/tap.{crt,key}` from the same lab CA `make_webhook_ca` creates, with SAN `tap.linkerd-viz.svc`. Check that name against the Service the tap APIService points at before trusting it; record what you found.
- `tap_install_args DIR` prints the `--set-file` arguments (`tap.crtPEM`, `tap.keyPEM`, `tap.caBundle`), one per line, as `webhook_install_args` does.
- Keys stay in the VM under `$CERTS_ROOT`; only certificates reach evidence.

**Steps:**

1. Read `lab/lib-webhook.sh`, `lab/reset.sh` and `lib/linkerd.sh` first. Follow their shape — this task adds a fourth lab-supplied credential, not a new mechanism.
2. Write the two profiles. `tap-short`: long-lived anchor and issuer (as `long.env`), `TAP_CERT_LIFETIME=15m`. `tap-long`: the same with `24h`, for discovery only.
3. Add `make_tap_cert` and `tap_install_args`; extend `load_profile` to require `TAP_CERT_LIFETIME`; add the key, empty, to every existing profile.
4. Extend `reset.sh`: when `TAP_CERT_LIFETIME` is non-empty, after the core install, sign the tap certificate and run `linkerd viz install` with its `--set-file` arguments, then wait for the viz Deployments to be ready. Viz's own pods are meshed, so this must happen after the control plane is serving.
5. **Discovery (stop gate).** Write `lab/discover-tap.sh`, run a reset with `tap-long`, deploy baseline workloads, then record: the tap Secret's certificate against the supplied one (compare X.509 fingerprints, never raw bytes — a caBundle loses its trailing newline through the API); the `v1alpha1.tap.linkerd.io` APIService's `Available` condition; `linkerd viz check`; and the output of `linkerd viz tap deploy/server -o json --timeout 10s` limited to a couple of events while traffic runs.
   Write `FINDINGS.md` with the Write tool (scratchpad then `cp` if it refuses the path), answering: does Linkerd serve the supplied tap certificate, and does tap work while it is valid.
   **STOP GATE:** if the served certificate is not ours, or the APIService is not Available, or tap returns no events while healthy, commit the discovery record and report BLOCKED. V cannot be run as designed.
6. `bash -n` and `shellcheck` clean; `just demo cert-hygiene test` still passes. Commit and push, and add the discovery record. No article README change.
