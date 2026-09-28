# Task 3: SPIFFE before/after comparison

Compares `runs/_refactor-check/before/` (Task 2, original inline SPIFFE
scripts) against `runs/_refactor-check/after/` (Task 3, thin SPIFFE scripts
calling `lib/certs.sh`, `lib/k3s.sh`, `lib/linkerd.sh`), via
`demos/cert-hygiene/scripts/refactor-compare.sh runs/_refactor-check/before runs/_refactor-check/after`.

**Compare's final line:**

```
[refactor-compare.sh] exit statuses, linkerd check, versions and pod set all match
```

Exit code: 0.

## Comparison method note

`linkerd-check.txt` lists control-plane and viz proxy pod names in its
"proxies are up-to-date" sections. Those names carry a Kubernetes
ReplicaSet-hash and pod-suffix that differ on every independent install --
even with byte-identical scripts -- because the pod template embeds a
`checksum/config` / `linkerd.io/trust-root-sha256` annotation derived from
the freshly, randomly generated trust anchor certificate (verified directly
against the live cluster: `kubectl -n linkerd get deploy linkerd-destination
-o jsonpath='{.spec.template.metadata.annotations}'` showed a
`trust-root-sha256` value tied to that run's certificate). `pods.txt` was
already normalized this way (`pod_shape`, comparing namespace/READY/STATUS
counts only); `linkerd-check.txt` was not, and an unconditional `diff -u`
against it was guaranteed to fail on every run regardless of refactor
correctness.

`refactor-compare.sh` was changed to normalize pod-name suffixes out of
`linkerd-check.txt` before diffing it (`normalize_pods()`, using `perl`
because macOS's BSD `awk` lacks reliable `{n,m}` interval regexes), while
every other check -- exit-status tail lines, `linkerd-version.txt`'s exact
diff, and the pod-shape diff -- is unchanged from the brief.

## Diff hunk classes seen

### `gen-certs.log`
- certificate serials, fingerprints, and validity timestamps -- the
  `Serial:`, `Valid from:`/`to:` lines change every run (fresh CA).
- Outside the five documented classes, but harmless: `step`'s own
  "Your certificate has been saved in ..." lines print the full path
  (`/home/orion/linkerd-certs/ca.crt`) in `after` vs the bare filename
  (`ca.crt`) in `before`. Cause: the original inline script did `cd "$DIR"`
  before invoking `step`, so `step` echoed relative names; `lib/certs.sh`
  does not `cd` and passes `"$dir/ca.crt"` explicitly (per the brief's Step 1
  content). Same file, same location, same content -- only the path string
  `step` prints back differs. Not a behaviour change.

### `install-k3s.log`
- timing -- node `AGE` reads `5s` in `before` vs `7s` in `after` at the
  moment `kubectl get nodes -o wide` ran.

### `install-linkerd.log`
- download and progress output -- curl progress-bar percentages/rates during
  the edge-CLI install differ run to run.
- timing -- one `rollout status` intermediate polling line
  ("0 out of 1 new replicas have been updated...") appears in `before` but
  not `after` (a poll landed on a different intermediate state); another
  poll line for `linkerd-proxy-injector` appears in `after` but not
  `before`. Both are `wait_rollouts`' informational polling output racing
  real cluster state -- harmless, matches the "timing" class.
- pod hash suffixes -- the embedded `linkerd check` output inside this log
  lists the same proxy pod names discussed above (unnormalized here, since
  this loop is the per-log diff printed for human review, not a gate).

### `linkerd-check.txt` (compared with pod-name suffixes normalized)
- pod hash suffixes -- after normalization, no difference remains. This was
  the only content that ever differed in this file.

### `linkerd-version.txt` and pod-shape (`pods.txt`)
- no difference (exact match).

## Verdict

SPIFFE cluster-side behaviour is unchanged by the `lib/` refactor. Every
difference between the before and after records falls into a documented,
expected class (certificate serials/timestamps, download/progress output,
timing, pod hash suffixes) or is a cosmetic, non-behavioural artifact of the
refactor (absolute vs. relative path in `step`'s own printed message,
because `lib/certs.sh` does not `cd` into the working directory the way the
original inline script did). `linkerd-version.txt` and the pod-shape
(namespace/READY/STATUS) all matched exactly, and every script's exit status
matched. No apt/dpkg-output-class differences were observed in this run.
