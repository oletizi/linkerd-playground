# Task 3: Is a certificate refused for its algorithm? (**stop gate**)

Part of the [slice 4 plan](README.md). Read its Global Constraints first, then the [design](../../specs/2026-09-14-cert-hygiene-lab-slice-4-design.md) § 4.

**Goal:** find out whether this cluster's API server refuses a webhook serving certificate because of its signature algorithm or key, and if so, record the exact error. This is a question, not a build. Its output is an answer.

**Why it is a gate.** Scenario G assumes such a certificate exists and is refused. Two things make that uncertain: the lab signs with `step`, which will not emit a deprecated signature algorithm, and the Go behaviour this relies on has moved — SHA-1 verification was first gated behind a runtime flag and later removed outright, so what a given API server does depends on the Go it was built with. Nobody has checked on this cluster.

**This is throwaway work.** Do it outside the harness, in the session scratchpad. Do not add a scenario, do not add a profile, do not modify anything under `lib/` or `demos/cert-hygiene/`. The harness is untouched by this task.

**Steps:**

1. Record what the cluster is: the k3s version and, if it can be determined, the Go version its API server was built with (`kubectl version`, the k3s binary's build info). This is context for whatever you find, and for a reader asking whether it still holds.

2. Build candidates with `openssl`, since `step` will not produce them. Try in this order, stopping when one is refused for its algorithm:
   - a leaf signed with SHA-1 (`-sha1`) by a normally-generated CA;
   - a leaf with an undersized RSA key (512 bits);
   - a leaf signed with MD5.

   Each candidate must be **time-valid and correctly chained** — a long `notAfter`, the right SAN for the webhook Service, signed by a CA whose certificate is the configured `caBundle`. If a candidate is refused for being expired or for a bad chain, that is a broken candidate, not a result.

3. Install the candidate as one webhook's serving credential and exercise the matching admission path. Capture the API server's response verbatim, and the k3s journal around it.

4. **Answer these, each with the artifact that answers it:**
   - Was any candidate refused, and which?
   - Does the error name the algorithm or key, and does it contain any time-validity language? G1 turns on the second half.
   - What does `linkerd check` say about that webhook's certificate row while the certificate is installed and being refused? Capture the whole transcript and its exit status. **This is the most valuable thing this task can produce** — it is G3, and it is answerable before G is ever built.
   - Is the certificate demonstrably time-valid at the moment of refusal, from its own `notAfter`?

5. Write the findings to `demos/cert-hygiene/runs/_discovery/<stamp>-algorithm/FINDINGS.md`, with the transcripts beside it, following the existing discovery runs' shape. Record observations, not conclusions: what was run, what came back. Do not state a verdict on G1–G4.

6. **The gate.** If no candidate is refused for its algorithm, say so plainly and stop: G is not runnable as designed, Tasks 4 and 7 are dropped, and the controller decides what the slice does instead. A clean negative is a good outcome for this task — it costs an hour and saves building a scenario that cannot produce its own evidence. Do not improvise a different fault to keep G alive.

7. Commit the discovery artifacts and push.

**Do not** leave the cluster with a broken webhook: restore the normal credential before you finish, and confirm the admission path works again.
