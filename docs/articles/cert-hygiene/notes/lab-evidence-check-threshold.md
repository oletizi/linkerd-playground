# Evidence: where linkerd check's 60-day issuer warning starts

- **Run:** `demos/cert-hygiene/runs/20-check-threshold/20260912T124246Z` — `validity.txt`: `evidence_valid=yes`; `k-remaining.txt` line 1: `result=ok`
- **Comparison runs:** `demos/cert-hygiene/runs/05-issuer-expiry/20260912T075503Z` (RA), `demos/cert-hygiene/runs/05-issuer-expiry/20260912T085431Z` (RB) — the 15-minute issuer, from Task 21
- **Supplementary, not evidence:** `demos/cert-hygiene/runs/20-check-threshold/20260912T143709Z` — `validity.txt`: `evidence_valid=no`, `reason=dirty harness tree, or git-state.txt missing` (`git-state.txt`: `demo_repo_dirty=true`). Discussed separately below; no conclusion here rests on it alone.
- **Versions:** `versions.txt`: `linkerd_cli_version=edge-26.9.1`, `linkerd_controller_image=cr.l5d.io/linkerd/controller:edge-26.9.1`
- **Issuers:** `config_ISSUER_LIFETIME=1439h50m` (1440h − 10m, installed at reset) and `config_K_PLUS_ISSUER_LIFETIME=1440h10m` (1440h + 10m, applied afterward with the issuer-only `linkerd upgrade`, same anchor — `timeline.log:6`: `k-apply issuer-only linkerd upgrade with a 1440h10m issuer from the same anchor`)
- **Threshold:** `k/minus-calc.txt` and `k/plus-calc.txt`: `threshold_s=5184000` (60 days), matching the source-derived value below.

This is a step-driven scenario with no T_mark; times below are the step markers from `timeline.log`.

## Acceptance condition (design § 13)

> Both measured remaining-validity values, and both command transcripts, put the checks on opposite sides of the 60-day boundary.

| Check | Remaining-validity value | Side of 5,184,000 s | Transcript |
| --- | --- | --- | --- |
| minus, `linkerd check` | 5,183,374 s (`k/minus-calc.txt`: `issuer_not_after_epoch − check_started_epoch` = 1,794,400,456 − 1,789,217,082) | under | `k/minus-check.txt`: `‼` |
| minus, `linkerd check --proxy` | 5,183,370 s (same subtraction against `check_proxy_started_epoch`) | under | `k/minus-check-proxy.txt`: `‼` |
| plus, `linkerd check` | 5,184,553 s (`k/plus-calc.txt`: `issuer_not_after_epoch − check_ended_epoch` = 1,794,401,696 − 1,789,217,143) | over | `k/plus-check.txt`: `‼` |
| plus, `linkerd check --proxy` | 5,184,548 s (same subtraction against `check_proxy_ended_epoch`) | over | `k/plus-check-proxy.txt`: `‼` |

`k-remaining.txt` records the same four values under the same "ok" verdict — the mechanical validity rule only checks that minus is under 5,184,000 s and plus is over it; it never checks which mark the transcript printed. All four measured values sit on the sides the condition requires, so **the acceptance condition is met**: both checks are bracketed across the boundary. That the transcripts all print the same mark regardless is exactly what K1 below is about.

## The measurements

| Issuer | Command | Started / ended (UTC) | Remaining at check time | Headline |
| --- | --- | --- | --- | --- |
| 1440h − 10m (`issuer-minus`, notAfter `2026-11-11T12:34:16Z`) | `linkerd check` | 12:44:42Z / 12:44:46Z | 5,183,374 s at start (59 d 23 h 49 m 34 s; 626 s under 60 days) | `‼ issuer cert is valid for at least 60 days` |
| 1440h − 10m | `linkerd check --proxy` | 12:44:46Z / 12:44:51Z | 5,183,370 s at start | `‼ issuer cert is valid for at least 60 days` |
| 1440h + 10m (`issuer-plus`, notAfter `2026-11-11T12:54:56Z`) | `linkerd check` | 12:45:39Z / 12:45:43Z | 5,184,557 s at start / 5,184,553 s at end (60 d 0 h 9 m 13 s at end; 553 s over 60 days) | `‼ issuer cert is valid for at least 60 days` |
| 1440h + 10m | `linkerd check --proxy` | 12:45:43Z / 12:45:48Z | 5,184,553 s at start / 5,184,548 s at end (548 s over 60 days) | `‼ issuer cert is valid for at least 60 days` |
| ~15 minutes (RA, `05-issuer-expiry/20260912T075503Z`, notAfter `2026-09-12T08:11:54Z`) | `checks/baseline-check.txt`, tick `baseline` at `07:57:16Z` | — | 878 s (14 m 38 s) | `‼ issuer cert is valid for at least 60 days` |
| ~15 minutes (RB, `05-issuer-expiry/20260912T085431Z`, notAfter `2026-09-12T09:11:24Z`) | `checks/baseline-check.txt`, tick `baseline` at `08:56:58Z` | — | 866 s (14 m 26 s) | `‼ issuer cert is valid for at least 60 days` |

Even the most favourable reading of the plus step — the remaining validity measured at the *start* of the command, before any time has passed running it — was 5,184,557 s, 557 s **more** than the 60-day threshold. `linkerd check` still printed the fatal `‼` row, quoting that certificate's own expiry, `2026-11-11T12:54:56Z` (`k/plus-check.txt`), which matches `certs/issuer-plus.txt`'s `notAfter=Nov 11 12:54:56 2026 GMT` and `serial=7C35AE8349F9182EAAC64E0FF1888CDE`.

## Exact headline rows

`k/minus-check.txt`, `k/minus-check-proxy.txt` (identical in both):
```
√ issuer cert is within its validity period
‼ issuer cert is valid for at least 60 days
    issuer certificate will expire on 2026-11-11T12:34:16Z
    see https://linkerd.io/2/checks/#l5d-identity-issuer-cert-not-expiring-soon for hints
```

`k/plus-check.txt`, `k/plus-check-proxy.txt` (identical in both):
```
√ issuer cert is within its validity period
‼ issuer cert is valid for at least 60 days
    issuer certificate will expire on 2026-11-11T12:54:56Z
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

**Verdict: half confirmed, half falsified.**

- The under-60-days half is **confirmed**: at 5,183,374 s / 5,183,370 s remaining (minus), both transcripts print the identical `‼ issuer cert is valid for at least 60 days` headline as RA's and RB's baseline checks at 878 s and 866 s remaining (`k/minus-check.txt`, `k/minus-check-proxy.txt`; RA/RB `checks/baseline-check.txt`).
- The over-60-days half is **falsified**: at 5,184,557 s / 5,184,553 s remaining at the start of the command (plus), the check did not print `√`. All four plus transcripts (`check` and `check --proxy`, control plane and data plane) print the same fatal `‼` row as the minus step, quoting the issuer's own expiry (`k/plus-check.txt`, `k/plus-check-proxy.txt`).
- Because the second half is falsified, the hypothesis's own conclusion — "the threshold lies between the two recorded remaining-validity values" (i.e., between 5,183,374 s and 5,184,557 s, a 1,183 s window) — does not hold as stated. This run puts a **lower bound** on the threshold above 5,184,557 s (60 days + 557 s), not a two-sided bracket around 60 days.

**What the two runs together bound.** The evidence run alone only establishes that the threshold is *somewhere above* 60 days + 557 s. The supplementary run (below) adds an upper bound: with a 1464h30m issuer (61 days + 30 minutes), the plus checks passed. Together, the two runs bound the threshold to lie **above 60 days + 557 s and at or below 61 days + 30 minutes** — a window of roughly 23 hours, not the 1,183-second window K1 predicted. Only the evidence run's bound (above 60 days + 557 s) is evidence-backed; the upper bound depends on the supplementary run and is reported with that caveat.

**Notes:** source-derived: the threshold is `expirationWarningThresholdInDays = 60` (`linkerd-source-notes.md` § 7, `pkg/issuercerts/issuercerts.go` L22, L129–135), and is not configurable. The source notes do not say the comparison is a plain "remaining time from now" duration check; this run shows the effective behaviour needs more margin than that reading would predict.

**Inference, not established fact.** One candidate explanation the design flagged as worth naming: the check might weigh in some property of the certificate's own issuance window (for example a comparison against the certificate's total lifetime, or a skew/rounding allowance) rather than a plain "notAfter minus now" duration. This is speculation, not shown by these artifacts — nothing collected here inspects the check's internal comparison, only its output. It would be settled by a sweep of issuer lifetimes between the two bounds above (for example at 15-minute or hourly increments of margin over 60 days) to find where the headline actually flips, together with reading the comparison code path directly (`pkg/issuercerts/issuercerts.go`) to see what it compares against.

## The supplementary run (not evidence)

`demos/cert-hygiene/runs/20-check-threshold/20260912T143709Z` was ordered by the controller with a wider margin — a 1464h30m issuer (61 days + 30 minutes), `config_K_PLUS_ISSUER_LIFETIME=1464h30m` in its `versions.txt` — set through a git-ignored local config override. Its `git-state.txt` records `demo_repo_dirty=true`, so `validity.txt` reads `evidence_valid=no`: **the harness marks any run dirty whenever that override file exists on disk, regardless of what it changed.** This run is not evidence and is not used to confirm or falsify K1 on its own; it is reported here only as a supplementary observation that bounds the falsified half of K1 from above.

Its plus rows, at roughly 5,272,169 s remaining (61 days − 30 min buffer worth of margin over 60 days, `k-remaining.txt`: `plus check had 5272169s left at its end (> 5184000s)`), **passed**:
```
√ issuer cert is within its validity period
√ issuer cert is valid for at least 60 days
√ issuer cert is issued by the trust anchor
```
(`k/plus-check.txt`, `k/plus-check-proxy.txt` in that run.) Its minus rows still warned, at 5,183,373 s / 5,183,369 s remaining — the same `‼` headline as the evidence run's minus step (`k/minus-check.txt` in that run).

## What this means for the article

- **The article must not claim the warning fires at exactly 60 days.** This lab's own evidence run shows a certificate with 557 seconds *more* than 60 days of remaining validity still getting the fatal `‼` row on all four transcripts. Any statement of the boundary must say "somewhere above 60 days plus roughly 9 minutes, and observed to be at or below 61 days plus 30 minutes in this lab" — not "60 days."
- **The 15-minute case (R) and the near-60-day case (K) together show the headline is stable and repeatable well under the boundary** (RA, RB, and K's minus step all print the identical wording), but they say nothing about exactly where above 60 days the headline clears.
- **One run each.** The evidence run (`20260912T124246Z`) is one bracketing attempt on one issuer pair; RA and RB are two runs of the 15-minute case. None of this generalises beyond this lab's version, `edge-26.9.1`, or these lifetimes.
- **No mechanism is established.** Whatever makes the check demand more margin than a plain 60-day countdown is not shown by these artifacts — only its effect (a much wider dead zone than 60 days ± minutes) is observed.
- Artifact paths for verification: `demos/cert-hygiene/runs/20-check-threshold/20260912T124246Z/{validity.txt,k-remaining.txt,k/*.txt,certs/issuer-plus.txt,versions.txt}`; `demos/cert-hygiene/runs/20-check-threshold/20260912T143709Z/{validity.txt,k-remaining.txt,k/*.txt,versions.txt}`; `demos/cert-hygiene/runs/05-issuer-expiry/{20260912T075503Z,20260912T085431Z}/{checks/baseline-check.txt,certs/issuer-initial.txt,timeline.log}`.
