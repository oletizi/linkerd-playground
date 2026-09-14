# Evidence: where linkerd check's 60-day issuer warning starts

- **Bisect runs (the measurement):** eight runs of `20-check-threshold` recorded on 2026-09-14 — `20260914T101656Z`, `20260914T102104Z`, `20260914T102506Z`, `20260914T102908Z`, `20260914T103638Z`, `20260914T104117Z`, `20260914T104509Z`, `20260914T104930Z`. Every one: `validity.txt`: `evidence_valid=yes`; `k-remaining.txt` line 1: `result=ok`; `git-state.txt`: `demo_repo_dirty=false` and the same `harness_tree_sha256=206cd4f55895d89011a65c131f03c09c911b06588547f3162a13bab440f7dfa3`.
- **First run:** `demos/cert-hygiene/runs/20-check-threshold/20260912T124246Z` — `validity.txt`: `evidence_valid=yes`; `k-remaining.txt` line 1: `result=ok`. Recorded at an earlier harness tree (`git-state.txt`: `harness_tree_sha256=e86c787e…`), which K's validity rules permit: K's rule list is `k-remaining` alone, because no probe outcome is judged, so no control at a matching tree is required.
- **Comparison runs:** `demos/cert-hygiene/runs/05-issuer-expiry/20260912T075503Z` (RA), `demos/cert-hygiene/runs/05-issuer-expiry/20260912T085431Z` (RB) — the 15-minute issuer, from Task 21.
- **Superseded, not evidence:** `demos/cert-hygiene/runs/20-check-threshold/20260912T143709Z` — `validity.txt`: `evidence_valid=no`, `reason=dirty harness tree, or git-state.txt missing` (`git-state.txt`: `demo_repo_dirty=true`). It was the only place the check had ever been seen to pass; the bisect runs replace it, and nothing in this note now depends on it. Kept below as history.
- **Versions:** identical in all nine evidence runs' `versions.txt`: `linkerd_cli_version=edge-26.9.1`, `linkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1`.
- **Issuers:** every run installs `config_ISSUER_LIFETIME=1439h50m` (1440h − 10m, the `minus` step) at reset, then applies a second issuer from the same anchor with the issuer-only `linkerd upgrade` (`timeline.log`: `k-apply issuer-only linkerd upgrade with a <lifetime> issuer from the same anchor`). That second lifetime, `config_K_PLUS_ISSUER_LIFETIME`, is the bisected variable: `1440h10m` in the first run and eight different values across the bisect.
- **Threshold:** `k/minus-calc.txt` and `k/plus-calc.txt` in every run: `threshold_s=5184000` (60 days), matching the source-derived value below.

This is a step-driven scenario with no T_mark; times below are the step markers from `timeline.log`, and every remaining-validity figure is `issuer_not_after_epoch` minus the relevant check timestamp from that run's own `k/<step>-calc.txt`.

## How a transcript bounds the threshold

Each `k/<step>-calc.txt` records four timestamps — `check_started_epoch`, `check_ended_epoch`, `check_proxy_started_epoch`, `check_proxy_ended_epoch` — that bracket the wall time of each command. The issuer row is evaluated at some unknown instant *inside* the command, so the remaining validity the check actually saw lies somewhere between the value computed at the command's end (the smallest) and the value computed at its start (the largest). The two differ by three to six seconds in these runs.

That asymmetry decides which number each transcript is allowed to contribute:

- **A transcript that warned (`‼`) proves the threshold is at least its END value.** The check might have evaluated at the last instant of the command, when the least validity remained; only that smallest value is certainly still on the warning side.
- **A transcript that passed (`√`) proves the threshold is below its START value.** The check might have evaluated at the first instant, when the most validity remained; only that largest value is certainly still on the passing side.

Taking the other value in either direction would claim a narrower bracket than the evidence supports. **This note applies that rule everywhere, including to the first run**: its plus step is quoted below at 5,184,553 s (its check's end), not the 5,184,557 s start value an earlier version of this note used. The point that run made — that a certificate with more than 60 days left still drew the fatal row — is unchanged by the four seconds; only the provable figure moves. A reader comparing this note to an older draft, or to the article, should expect warn figures to have shrunk by a few seconds and pass figures to have grown by a few, for this reason and no other.

The 15-minute comparison runs (RA, RB) record a single per-tick check with no start/end pair, so they are quoted as recorded; at about a quarter of an hour of remaining validity they sit nowhere near the boundary and bound nothing.

## The measured bracket

Across all thirty-two bisect transcripts (eight runs × two steps × `linkerd check` and `linkerd check --proxy`), plus the first run's four:

- **Largest remaining validity provably still warning: 5,187,538 s — 60 days + 58 m 58 s.** From `20260914T104930Z` (`config_K_PLUS_ISSUER_LIFETIME=1440h59m35s`), `k/plus-check.txt`, which printed `‼`; the value is `issuer_not_after_epoch − check_ended_epoch` = 1,794,570,695 − 1,789,383,157 = 5,187,538, and 5,187,538 − 5,184,000 = 3,538 s = 58 m 58 s. That run's `k/plus-check-proxy.txt` also warned, at an end value of 5,187,532 s (58 m 52 s), which is a weaker bound.
- **Smallest remaining validity provably still passing: 5,187,843 s — 60 days + 1 h 4 m 3 s.** From `20260914T104509Z` (`config_K_PLUS_ISSUER_LIFETIME=1441h5m`), `k/plus-check-proxy.txt`, which printed `√`; the value is `issuer_not_after_epoch − check_proxy_started_epoch` = 1,794,570,737 − 1,789,382,894 = 5,187,843, and 5,187,843 − 5,184,000 = 3,843 s = 1 h 4 m 3 s. That run's `k/plus-check.txt` also passed, four seconds earlier and so at a start value of 5,187,847 s (1 h 4 m 7 s), which is a weaker bound. `--proxy` runs immediately after `check` in each step, so within a passing step it is always the `--proxy` transcript that gives the tighter number, and within a warning step always the plain `check` transcript.

**The threshold lies above 60 days + 58 m 58 s and at or below 60 days + 1 h 4 m 3 s** — between 5,187,538 s and 5,187,843 s of remaining validity. The width is 5,187,843 − 5,187,538 = **305 s, 5 m 5 s**.

That replaces the roughly 24-hour bracket this note carried before. The lower bound no longer comes from the first run at all: `20260914T104930Z` warns at 3,538 s over 60 days, where the first run's warn proves only 553 s. The upper bound no longer comes from the non-evidence supplementary run: `20260914T104509Z` passes at 3,843 s over 60 days, where that run proves only 88,173 s over 60 days.

## Acceptance condition (design § 13)

> Both measured remaining-validity values, and both command transcripts, put the checks on opposite sides of the 60-day boundary.

**This condition is now met, in six of the eight bisect runs.** Taking `20260914T104509Z` as the worked example — it is the run that supplies the bracket's upper bound:

| Check | Remaining-validity value | Side of 5,184,000 s | Transcript |
| --- | --- | --- | --- |
| minus, `linkerd check` | 5,183,374 s (`k/minus-calc.txt`: 1,794,566,197 − 1,789,382,823) | under | `k/minus-check.txt`: `‼` |
| minus, `linkerd check --proxy` | 5,183,370 s (same subtraction against `check_proxy_started_epoch`) | under | `k/minus-check-proxy.txt`: `‼` |
| plus, `linkerd check` | 5,187,847 s (`k/plus-calc.txt`: 1,794,570,737 − 1,789,382,890) | over | `k/plus-check.txt`: `√` |
| plus, `linkerd check --proxy` | 5,187,843 s (same subtraction against `check_proxy_started_epoch`) | over | `k/plus-check-proxy.txt`: `√` |

Both measured values fall on the sides the condition requires, and both commands' transcripts flip with them: fatal below 60 days, clear above. Runs `20260914T101656Z`, `20260914T102104Z`, `20260914T102506Z`, `20260914T102908Z` and `20260914T104117Z` satisfy it the same way, at larger margins.

**Three runs do not satisfy it, and that is the interesting part.** In `20260914T103638Z`, `20260914T104930Z` and the first run `20260912T124246Z`, the plus step's measured value is *over* 5,184,000 s while both of its transcripts still print `‼`. Those are the runs that place the real boundary above 60 days, and they are why a run needs more than ten minutes of margin to meet the condition at all. § 13's condition is a test an individual run either meets or does not, and six valid runs at a single frozen harness tree meet it: **K's acceptance condition is met, and K is reproduced in both directions.** This reverses the earlier ruling in this note, which was made when the only run that had ever recorded a `√` was the non-evidence supplementary run below.

`k-remaining.txt` does not settle this either way in any run — it only checks the measured values against the threshold, and never checks which mark the transcript printed. All nine evidence runs report `result=ok`, including the three whose transcripts do not flip.

## The measurements

### The plus step — the bisected variable

One row per transcript. `config_K_PLUS_ISSUER_LIFETIME` is from each run's `versions.txt`; times and remaining values from `k/plus-calc.txt`; the headline from `k/plus-check.txt` and `k/plus-check-proxy.txt`. Offsets are against 5,184,000 s.

| Run (2026-09-14) | Plus lifetime | Command | Started / ended (UTC) | Remaining at start | Remaining at end | Headline |
| --- | --- | --- | --- | --- | --- | --- |
| `20260914T101656Z` | `1452h` | `linkerd check` | 10:19:51Z / 10:19:54Z | 5,227,152 s (+11 h 59 m 12 s) | 5,227,149 s (+11 h 59 m 9 s) | `√` |
| `20260914T101656Z` | `1452h` | `linkerd check --proxy` | 10:19:54Z / 10:19:59Z | 5,227,149 s (+11 h 59 m 9 s) | 5,227,144 s (+11 h 59 m 4 s) | `√` |
| `20260914T102104Z` | `1446h` | `linkerd check` | 10:24:00Z / 10:24:04Z | 5,205,568 s (+5 h 59 m 28 s) | 5,205,564 s (+5 h 59 m 24 s) | `√` |
| `20260914T102104Z` | `1446h` | `linkerd check --proxy` | 10:24:04Z / 10:24:09Z | 5,205,564 s (+5 h 59 m 24 s) | 5,205,559 s (+5 h 59 m 19 s) | `√` |
| `20260914T102506Z` | `1443h5m` | `linkerd check` | 10:28:04Z / 10:28:08Z | 5,195,052 s (+3 h 4 m 12 s) | 5,195,048 s (+3 h 4 m 8 s) | `√` |
| `20260914T102506Z` | `1443h5m` | `linkerd check --proxy` | 10:28:08Z / 10:28:13Z | 5,195,048 s (+3 h 4 m 8 s) | 5,195,043 s (+3 h 4 m 3 s) | `√` |
| `20260914T102908Z` | `1441h38m` | `linkerd check` | 10:31:54Z / 10:31:58Z | 5,189,847 s (+1 h 37 m 27 s) | 5,189,843 s (+1 h 37 m 23 s) | `√` |
| `20260914T102908Z` | `1441h38m` | `linkerd check --proxy` | 10:31:58Z / 10:32:03Z | 5,189,843 s (+1 h 37 m 23 s) | 5,189,838 s (+1 h 37 m 18 s) | `√` |
| `20260914T103638Z` | `1440h54m` | `linkerd check` | 10:39:29Z / 10:39:33Z | 5,187,207 s (+53 m 27 s) | **5,187,203 s (+53 m 23 s)** | `‼` |
| `20260914T103638Z` | `1440h54m` | `linkerd check --proxy` | 10:39:33Z / 10:39:38Z | 5,187,203 s (+53 m 23 s) | 5,187,198 s (+53 m 18 s) | `‼` |
| `20260914T104117Z` | `1441h16m` | `linkerd check` | 10:44:01Z / 10:44:05Z | 5,188,538 s (+1 h 15 m 38 s) | 5,188,534 s (+1 h 15 m 34 s) | `√` |
| `20260914T104117Z` | `1441h16m` | `linkerd check --proxy` | 10:44:05Z / 10:44:09Z | **5,188,534 s (+1 h 15 m 34 s)** | 5,188,530 s (+1 h 15 m 30 s) | `√` |
| `20260914T104509Z` | `1441h5m` | `linkerd check` | 10:48:10Z / 10:48:14Z | 5,187,847 s (+1 h 4 m 7 s) | 5,187,843 s (+1 h 4 m 3 s) | `√` |
| `20260914T104509Z` | `1441h5m` | `linkerd check --proxy` | 10:48:14Z / 10:48:19Z | **5,187,843 s (+1 h 4 m 3 s)** | 5,187,838 s (+1 h 3 m 58 s) | `√` |
| `20260914T104930Z` | `1440h59m35s` | `linkerd check` | 10:52:33Z / 10:52:37Z | 5,187,542 s (+59 m 2 s) | **5,187,538 s (+58 m 58 s)** | `‼` |
| `20260914T104930Z` | `1440h59m35s` | `linkerd check --proxy` | 10:52:37Z / 10:52:43Z | 5,187,538 s (+58 m 58 s) | 5,187,532 s (+58 m 52 s) | `‼` |

Bold marks the value each transcript contributes under the rule above — an end value for a `‼` row, a start value for a `√` row — in the runs that tightened the bracket. The bracket's two bounds are the bold 5,187,538 s (warn) and the bold 5,187,843 s (pass).

The bisect walked down from a 12-hour margin: pass at +11 h 59 m, pass at +6 h, pass at +3 h 4 m, pass at +1 h 37 m, **warn** at +53 m — the first crossing — then pass at +1 h 16 m, pass at +1 h 4 m, **warn** at +59 m.

### The minus step — the same issuer in every run

Every run installs `config_ISSUER_LIFETIME=1439h50m` at reset and checks it before applying the plus issuer, so this step is effectively the same measurement repeated eight times. All sixteen transcripts printed `‼`, and all sixteen measured values are under 5,184,000 s. Times and values from each run's `k/minus-calc.txt`.

| Run (2026-09-14) | Command | Started / ended (UTC) | Remaining at start | Remaining at end | Headline |
| --- | --- | --- | --- | --- | --- |
| `20260914T101656Z` | `linkerd check` | 10:18:49Z / 10:18:53Z | 5,183,374 s (−10 m 26 s) | 5,183,370 s (−10 m 30 s) | `‼` |
| `20260914T101656Z` | `linkerd check --proxy` | 10:18:53Z / 10:18:58Z | 5,183,370 s (−10 m 30 s) | 5,183,365 s (−10 m 35 s) | `‼` |
| `20260914T102104Z` | `linkerd check` | 10:23:14Z / 10:23:17Z | 5,183,374 s (−10 m 26 s) | 5,183,371 s (−10 m 29 s) | `‼` |
| `20260914T102104Z` | `linkerd check --proxy` | 10:23:17Z / 10:23:22Z | 5,183,371 s (−10 m 29 s) | 5,183,366 s (−10 m 34 s) | `‼` |
| `20260914T102506Z` | `linkerd check` | 10:27:01Z / 10:27:05Z | 5,183,373 s (−10 m 27 s) | 5,183,369 s (−10 m 31 s) | `‼` |
| `20260914T102506Z` | `linkerd check --proxy` | 10:27:05Z / 10:27:11Z | 5,183,369 s (−10 m 31 s) | 5,183,363 s (−10 m 37 s) | `‼` |
| `20260914T102908Z` | `linkerd check` | 10:31:08Z / 10:31:11Z | 5,183,373 s (−10 m 27 s) | 5,183,370 s (−10 m 30 s) | `‼` |
| `20260914T102908Z` | `linkerd check --proxy` | 10:31:11Z / 10:31:16Z | 5,183,370 s (−10 m 30 s) | 5,183,365 s (−10 m 35 s) | `‼` |
| `20260914T103638Z` | `linkerd check` | 10:38:40Z / 10:38:45Z | 5,183,371 s (−10 m 29 s) | 5,183,366 s (−10 m 34 s) | `‼` |
| `20260914T103638Z` | `linkerd check --proxy` | 10:38:45Z / 10:38:51Z | 5,183,366 s (−10 m 34 s) | 5,183,360 s (−10 m 40 s) | `‼` |
| `20260914T104117Z` | `linkerd check` | 10:43:25Z / 10:43:28Z | 5,183,365 s (−10 m 35 s) | 5,183,362 s (−10 m 38 s) | `‼` |
| `20260914T104117Z` | `linkerd check --proxy` | 10:43:28Z / 10:43:33Z | 5,183,362 s (−10 m 38 s) | 5,183,357 s (−10 m 43 s) | `‼` |
| `20260914T104509Z` | `linkerd check` | 10:47:03Z / 10:47:07Z | 5,183,374 s (−10 m 26 s) | 5,183,370 s (−10 m 30 s) | `‼` |
| `20260914T104509Z` | `linkerd check --proxy` | 10:47:07Z / 10:47:12Z | 5,183,370 s (−10 m 30 s) | 5,183,365 s (−10 m 35 s) | `‼` |
| `20260914T104930Z` | `linkerd check` | 10:51:46Z / 10:51:50Z | 5,183,364 s (−10 m 36 s) | 5,183,360 s (−10 m 40 s) | `‼` |
| `20260914T104930Z` | `linkerd check --proxy` | 10:51:50Z / 10:51:56Z | 5,183,360 s (−10 m 40 s) | 5,183,354 s (−10 m 46 s) | `‼` |

### The first run and the 15-minute comparison

| Issuer | Command | Started / ended (UTC) | Remaining at check time | Headline |
| --- | --- | --- | --- | --- |
| 1440h − 10m (`issuer-minus`, notAfter `2026-11-11T12:34:16Z`) | `linkerd check` | 12:44:42Z / 12:44:46Z | 5,183,370 s at end; 5,183,374 s at start — 626 s under 60 days, i.e. 59 d 23 h 49 m 34 s | `‼ issuer cert is valid for at least 60 days` |
| 1440h − 10m | `linkerd check --proxy` | 12:44:46Z / 12:44:51Z | 5,183,365 s at end | `‼ issuer cert is valid for at least 60 days` |
| 1440h + 10m (`issuer-plus`, notAfter `2026-11-11T12:54:56Z`) | `linkerd check` | 12:45:39Z / 12:45:43Z | 5,184,553 s at end (60 d 0 h 9 m 13 s; **553 s over 60 days**) | `‼ issuer cert is valid for at least 60 days` |
| 1440h + 10m | `linkerd check --proxy` | 12:45:43Z / 12:45:48Z | 5,184,548 s at end (548 s over 60 days) | `‼ issuer cert is valid for at least 60 days` |
| ~15 minutes (RA, `05-issuer-expiry/20260912T075503Z`, notAfter `2026-09-12T08:11:54Z`) | `checks/baseline-check.txt`, tick `baseline` at `07:57:16Z` | — | 878 s (14 m 38 s) | `‼ issuer cert is valid for at least 60 days` |
| ~15 minutes (RB, `05-issuer-expiry/20260912T085431Z`, notAfter `2026-09-12T09:11:24Z`) | `checks/baseline-check.txt`, tick `baseline` at `08:56:58Z` | — | 866 s (14 m 26 s) | `‼ issuer cert is valid for at least 60 days` |

The first run's plus step is the figure this note used to quote as "60 days + 557 s". Under the rule above it is **60 days + 553 s**: the check ran for four seconds and could have evaluated at either end of that window, so only the end value is provably still on the warning side. The observation it supports is unchanged — a certificate with more than 60 days of validity left still drew the fatal `‼` row, quoting its own expiry, `2026-11-11T12:54:56Z` (`k/plus-check.txt`), matching `certs/issuer-plus.txt`'s `notAfter=Nov 11 12:54:56 2026 GMT` and `serial=7C35AE8349F9182EAAC64E0FF1888CDE`. It is simply no longer the bound that matters: `20260914T104930Z` warns 3,538 s over 60 days, six times further out.

## Exact headline rows

A warning step, `k/minus-check.txt` and `k/minus-check-proxy.txt` (identical in both; the expiry timestamp differs per run):
```
√ issuer cert is using supported crypto algorithm
√ issuer cert is within its validity period
‼ issuer cert is valid for at least 60 days
    issuer certificate will expire on 2026-11-13T10:36:37Z
    see https://linkerd.io/2/checks/#l5d-identity-issuer-cert-not-expiring-soon for hints
```
(quoted from `20260914T104509Z`.)

A passing step, `k/plus-check.txt` and `k/plus-check-proxy.txt` of `20260914T104509Z` (identical in both):
```
√ issuer cert is using supported crypto algorithm
√ issuer cert is within its validity period
√ issuer cert is valid for at least 60 days
√ issuer cert is issued by the trust anchor
```

A plus step that warned anyway, `k/plus-check.txt` and `k/plus-check-proxy.txt` of `20260914T104930Z` — 58 m 58 s past 60 days and still fatal:
```
√ issuer cert is using supported crypto algorithm
√ issuer cert is within its validity period
‼ issuer cert is valid for at least 60 days
    issuer certificate will expire on 2026-11-13T11:51:35Z
    see https://linkerd.io/2/checks/#l5d-identity-issuer-cert-not-expiring-soon for hints
```

RA and RB `checks/baseline-check.txt` (identical headline text, different expiry timestamps):
```
√ issuer cert is within its validity period
‼ issuer cert is valid for at least 60 days
    issuer certificate will expire on 2026-09-12T08:11:54Z   [RA]
    issuer certificate will expire on 2026-09-12T09:11:24Z   [RB]
    see https://linkerd.io/2/checks/#l5d-identity-issuer-cert-not-expiring-soon for hints
```

## K1 — verdict

**Hypothesis (design § 5):** "With less than 60 days remaining when the check runs, the issuer gets the same `‼ issuer cert is valid for at least 60 days` headline as the 15-minute one. With more than 60 days remaining, it gets `√`. The threshold therefore lies between the two recorded remaining-validity values."

**Verdict: the behaviour is confirmed; the location the hypothesis gave for it is falsified.**

- The under-60-days half is **confirmed**, now across sixteen bisect transcripts as well as the first run's two: every minus step, at 5,183,354–5,183,374 s remaining, prints the identical `‼ issuer cert is valid for at least 60 days` headline as RA's and RB's baseline checks at 878 s and 866 s remaining.
- The over-60-days half is **confirmed in valid evidence for the first time**, but not immediately above 60 days. Twelve bisect transcripts printed `√` (runs `20260914T101656Z`, `20260914T102104Z`, `20260914T102506Z`, `20260914T102908Z`, `20260914T104117Z`, `20260914T104509Z`, both commands each), the tightest of them at 5,187,843 s — 1 h 4 m 3 s past 60 days. Four bisect transcripts and the first run's two printed `‼` *despite* measuring over 60 days, the furthest out at 5,187,538 s — 58 m 58 s past. So "more than 60 days remaining" does not on its own get a `√`; roughly an hour more than 60 days does.
- The hypothesis's own conclusion — "the threshold lies between the two recorded remaining-validity values", i.e. between 5,183,374 s and 5,184,557 s in the run it was written for, a 1,183 s window — is **falsified**: the threshold is above 5,187,538 s, which is 2,981 s beyond the top of that window. A ±10-minute bracket around 1440h cannot contain this boundary, which is why the bisect had to vary the plus lifetime instead.

**What the eight bisect runs bound.** The threshold lies above 60 days + 58 m 58 s and at or below 60 days + 1 h 4 m 3 s: a 305-second window, measured entirely within valid runs at one frozen harness tree. Both of its ends are observations of the same scenario made minutes apart on the same afternoon, not a warn from one round of experiments paired with a pass from a discarded run.

**Notes:** source-derived: the threshold is `expirationWarningThresholdInDays = 60` (`linkerd-source-notes.md` § 7, `pkg/issuercerts/issuercerts.go` L22, L129–135), and is not configurable. The source notes do not say the comparison is a plain "remaining time from now" duration check; these runs show the effective behaviour needs about an hour more margin than that reading would predict.

**Inference, not established fact.** The sweep this note previously called for has been run, and it did what a sweep does: it located the flip and explained nothing. Eight lifetimes between 60 days + 54 minutes and 60 days + 12 hours narrowed a 24-hour bracket to 305 seconds, and every artifact in those runs is still only the check's output — nothing here inspects the comparison the check performs, its operands, or its rounding. The earlier conjecture stands exactly where it stood: the check might weigh in some property of the certificate's own issuance window, or a skew or rounding allowance, rather than a plain "notAfter minus now". Nothing observed here supports or refutes that. It is worth recording, and worth not over-reading, that the 305-second window happens to straddle 3,600 s — one hour past 60 days — but a bracket that contains a round number is not a mechanism, and this lab has measured no quantity that would make an hour meaningful. What would settle it is reading the comparison code path directly (`pkg/issuercerts/issuercerts.go`), not more runs; further bisection would only shrink the window around a number whose origin the artifacts cannot show.

## The superseded supplementary run (not evidence)

`demos/cert-hygiene/runs/20-check-threshold/20260912T143709Z` was ordered by the controller with a wider margin — a 1464h30m issuer (61 days + 30 minutes), `config_K_PLUS_ISSUER_LIFETIME=1464h30m` in its `versions.txt` — set through a git-ignored local config override. Its `git-state.txt` records `demo_repo_dirty=true`, so `validity.txt` reads `evidence_valid=no`: **the harness marks any run dirty whenever that override file exists on disk, regardless of what it changed.** That override is gone: the plus lifetime is now an argument to the scenario, so the bisect runs varied it with a clean tree.

For a while this was the only run in which `linkerd check` had ever been seen to pass the issuer row, and this note's upper bound depended on it. **It no longer does.** Its plus checks passed at 5,272,173 s and 5,272,169 s remaining at their starts — 24 h 29 m 33 s and 24 h 29 m 29 s past 60 days (`k-remaining.txt`: `plus check had 5272169s left at its end (> 5184000s)`) — an upper bound of 88,173 s over 60 days, 84,330 s looser than `20260914T104509Z`'s 3,843 s. Its minus rows warned at 5,183,373 s / 5,183,369 s remaining at their starts, the same `‼` headline as every other minus step. It is kept here as history; nothing above rests on it.

```
√ issuer cert is within its validity period
√ issuer cert is valid for at least 60 days
√ issuer cert is issued by the trust anchor
```
(`k/plus-check.txt`, `k/plus-check-proxy.txt` in that run.)

## What this means for the article

- **K is reproduced, in both directions.** Design § 13's K row — both measured remaining-validity values and both command transcripts on opposite sides of the boundary — is met in six of the eight bisect runs, all `evidence_valid=yes` at one frozen harness tree. The warning firing below 60 days and the check clearing above the boundary are now both observed in valid evidence; the reader-facing triage row can move to "reproduced" for the whole behaviour, not only the warning half.
- **The article must not claim the warning fires at 60 days.** It fires later. The lab measured a certificate with 58 m 58 s *more* than 60 days of remaining validity still getting the fatal `‼` row on both transcripts (`20260914T104930Z`, `k/plus-check.txt`, `k/plus-check-proxy.txt`), and the same check clearing to `√` at 1 h 4 m 3 s over (`20260914T104509Z`, `k/plus-check-proxy.txt`). The boundary should be stated as **measured to lie between roughly 59 minutes and roughly 64 minutes past the 60-day mark in this lab** — or, for a reader who does not need the seconds, "about an hour past 60 days, not at 60 days".
- **Quote the bracket, not a point.** 5,187,538 s and 5,187,843 s are the two provable ends; the check's exact flip is somewhere inside them and this lab did not locate it more precisely. Any single number would be invented.
- **The 15-minute case (R) and the near-60-day case (K) together show the headline is stable and repeatable well under the boundary** (RA, RB, and every minus step print the identical wording), and the bisect adds that it is equally stable well over it.
- **Eight runs, one afternoon, one version.** The bisect is eight runs of one scenario on one cluster at `edge-26.9.1`, with lifetimes chosen to converge, not repeated at any single lifetime. None of this generalises beyond this lab's version or these lifetimes, and nothing here says the boundary is the same for the trust anchor's own 60-day check.
- **No mechanism is established.** Whatever makes the check demand about an hour more margin than a plain 60-day countdown is not shown by these artifacts — only its effect is measured.
- Artifact paths for verification: `demos/cert-hygiene/runs/20-check-threshold/{20260914T101656Z,20260914T102104Z,20260914T102506Z,20260914T102908Z,20260914T103638Z,20260914T104117Z,20260914T104509Z,20260914T104930Z}/{validity.txt,git-state.txt,k-remaining.txt,k/*.txt,versions.txt,timeline.log}`; `demos/cert-hygiene/runs/20-check-threshold/20260912T124246Z/{validity.txt,k-remaining.txt,k/*.txt,certs/issuer-plus.txt,versions.txt}`; `demos/cert-hygiene/runs/20-check-threshold/20260912T143709Z/{validity.txt,k-remaining.txt,k/*.txt,versions.txt}`; `demos/cert-hygiene/runs/05-issuer-expiry/{20260912T075503Z,20260912T085431Z}/{checks/baseline-check.txt,certs/issuer-initial.txt,timeline.log}`. Read any of them with `tools/evidence.sh cat <run> <path>`.
