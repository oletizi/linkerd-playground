# Third-party review: Cert-Hygiene Lab, Slice 2 design

- **Reviewed:** [2026-09-11-cert-hygiene-lab-slice-2-design.md](../specs/2026-09-11-cert-hygiene-lab-slice-2-design.md), revision at commit `31b920f`
- **Dispositions:** design doc § 12
- The review text below is preserved as received.

---

This is coherent and substantially more ambitious than slice 1, but the design still holds together. I would approve the overall architecture and scenario set, with a few changes before implementation. Two are important experimental-design issues: W's certificate model/recovery path and S-hard's ability to create the mixed-anchor state its hypothesis requires.

I checked the current Linkerd edge documentation against the parts of the proposal that depend on documented operator procedures. The staged rotation sequence is faithful to Linkerd's documented procedure, and the webhook docs do say that deleting the TLS Secrets and applying an upgrade recreates them without normally requiring webhook pod restarts.

## 1. W needs to distinguish two different webhook-management models

This is the biggest thing I'd change.

Your profile currently says:

> When WEBHOOK_CERT_LIFETIME is set, reset.sh … passes each through --set-file <component>.crtPEM=…,<component>.keyPEM=…,<component>.caBundle=….

Then recovery says:

> delete the three …-k8s-tls Secrets and run linkerd upgrade

and correctly notices the catch that the supplied values may simply come back.

There are really two distinct operational models here:

- **Linkerd-managed webhook credentials:** Linkerd generates the Secret. The documented delete + upgrade procedure is directly applicable.
- **Externally/supplied credentials:** some external mechanism owns the cert/key material, and Linkerd is configured to use it.

Current Linkerd documentation makes this distinction fairly explicit. Its automatic-webhook-rotation instructions use `externalSecret=true` plus a supplied `caBundle` when cert-manager owns the Secrets.

Your lab configuration is a third, somewhat artificial state: you're giving the Linkerd renderer a static cert/key as values specifically to force expiry.

That's perfectly legitimate for fault injection, but I would make it explicit:

> webhook-short uses lab-supplied static webhook credentials, not Linkerd's default credential-management model. This is necessary to create a minutes-long expiry. The recovery phase therefore tests both the documented default-management procedure and recovery appropriate to supplied credentials.

Then W's recovery experiment becomes very clean:

1. Delete Secrets.
2. Run plain `linkerd upgrade`.
3. Capture exactly what it renders/applies.
4. Inspect resulting certificate serial/expiry.
5. If still expired, supply newly generated credentials explicitly.
6. Capture recovery.

That turns the "catch" into a deliberate experiment rather than an implementation uncertainty.

I would also move this out of Open Questions. It's no longer really an open design question; what upgrade does is an experimental question W intentionally measures.

## 2. Don't assume all webhook failures produce an "x509 error"

W2 says:

> all rejected with an x509 error from the API server.

I'd loosen that.

Kubernetes' important semantic distinction is `failurePolicy`: `Fail` rejects when the webhook call fails; `Ignore` allows admission to continue. The exact surfaced API error can depend on where TLS validation fails and how Kubernetes wraps it.

Make the hypothesis:

> W2: With Fail, after expiry, (a), (b), (c), and (d) are all rejected because the API server cannot successfully call the corresponding webhook.

Then treat the exact returned error text as a finding.

That's actually more useful for the article, because the whole point of this lab is discovering what operators really see.

Same issue with W5:

> API server logs each failed webhook call with the TLS error

I'd make that:

> API-server logs contain the webhook-call failure corresponding to the rejected/ignored admission request; the run records the exact TLS/error representation.

You don't want an otherwise successful experiment to "falsify" W5 merely because k3s logs `failed calling webhook` with wrapped text instead of the precise x509 string you anticipated.

## 3. W's admission probes need unique objects per tick

This is small but important.

If every tick says:

> apply an invalid policy

you need to ensure you're actually causing a fresh admission operation each time.

I'd specify that every admission probe uses either a unique generated object name or a unique mutation so that Kubernetes must invoke admission. For example:

```
policy-invalid-<tick>
serviceprofile-invalid-<tick>
inject-probe-<tick>
```

and capture:

```
admission/
  baseline/
  pre-expiry/
  post-001/
    pod.request.yaml
    pod.response.txt
    pod.observed.yaml
    policy.request.yaml
    policy.response.txt
    ...
```

That makes the evidence much easier to audit later.

Also delete successful probe resources after observation so the namespace doesn't accumulate junk over a 15-minute/tick-heavy run.

## 4. R is very good, but R3 needs directional interpretation

This is a much better experiment than the first run's recovery phase:

> restart client → restart server → restart everything

But R3:

> restarting one side is not enough; both endpoints need a fresh certificate

needs care because the TLS roles matter.

The result you really want isn't merely "one side isn't enough." You want to learn which stale identity prevents which connection.

I'd phrase R3 as:

> R3: A new proxy-to-proxy mTLS connection cannot succeed while either endpoint participating in the handshake still presents or trusts state that is invalid after recovery; the staged client/server restarts identify which endpoint state is necessary for recovery.

Then let the evidence tell you whether:

| neither restarted | client only | server only | both |
| --- | --- | --- | --- |
| fail | fail | ? | ok |

Your staged recovery is excellent precisely because it can discover something more specific than the current hypothesis.

## 5. O is probably the cleanest causal experiment in the entire slice

I especially like this one.

Slice 1 mixes two events:

> issuer expires → proxies lose valid leaves → issuer is replaced

O isolates:

> identity unavailable → leaves expire → same identity service and same issuer return

That gives you a much stronger way to interpret whatever happened in R.

I would add one explicit invariant:

> During O, issuer Secret contents, trust-anchor contents, and identity configuration must remain byte-for-byte unchanged across fault and recovery.

You already mostly get this from the validity rules, but it's important enough to state in § 4 because it is what makes O2 causally interesting.

Also capture the identity Deployment's replica transition and pod UID. You want the evidence to establish that recovery involved a new identity-controller process but unchanged credentials.

## 6. K should test the boundary, not just either side

Currently:

```
59 days → ‼
61 days → √
```

Since the claim is specifically a fixed 60-day threshold, I'd strongly prefer:

```
59d 23h 59m → ‼
60d exactly  → ?
60d + margin → √
```

or, if certificate timestamp/command execution makes exact equality awkward:

```
59d
60d + 5m
61d
```

The current 59/61 experiment establishes a threshold somewhere between them. It does not empirically establish that the boundary is 60 days.

Source says 60 days, but this scenario exists specifically to convert that source claim into lab evidence. Test tightly around the boundary.

## 7. A has a timing problem worth making explicit

You have:

```
anchor: 20m
issuer: 120m
leaf:   5m
```

and:

> Existing traffic keeps working after T_mark until each proxy's current leaf expires.

Yes—but because workload leaves continually rotate before T_mark, the actual post-anchor-expiry survival interval depends on when each proxy last successfully renewed before anchor expiry.

So don't accidentally frame this as:

> anchor expires → traffic works another five minutes

The interesting measurement is:

```
T_anchor
last successful leaf issuance per proxy
leaf notAfter per proxy
first new-connection failure per proxy pair
```

I would explicitly add that to A2:

> The run measures survival relative to each proxy's final pre-expiry leaf notAfter, not simply relative to T_mark.

This is the exact inverse of the issuer-expiry result. In R, issuer clamping collapses everyone onto one boundary. In A, the absence of anchor clamping should preserve staggered leaf expiries.

That's likely an important article finding.

## 8. A's recovery is correctly distinct from S

Good decision.

The current Linkerd manual-rotation documentation explicitly says its no-downtime procedure applies while the existing trust anchor is valid and directs users with an already-expired anchor to the expired-certificate replacement procedure instead.

So A and S answer fundamentally different questions:

- A: "What do I do after I have already broken trust?"
- S: "How do I rotate trust without breaking it?"

I would say this explicitly in § 7 or the introduction because otherwise the two scenarios can look redundant.

## 9. S-staged is well designed

This is faithful to the documented trust-bundle choreography:

```
old anchor
→ old + new bundle
→ distribute bundle to workloads
→ new issuer signed by new anchor
→ distribute new identities
→ remove old anchor
```

That is exactly the conceptual sequence Linkerd documents.

And this sentence is particularly important:

> Holding any workload back would leave it trusting only the old anchor when step 7 introduces certificates chained to the new one, and would cause the very failure the procedure exists to avoid.

Keep it. It shows that the restarts aren't merely procedural cargo cult; they're part of the trust-transition invariant.

But S1 is slightly too absolute:

> no new connection fails at any step.

A rolling restart can naturally cause transient application connection failures unrelated to certificate trust.

I'd define S1 in terms of certificate/trust failure, rather than literally zero failed application attempts:

> S1: S-staged produces no new-connection failure attributable to TLS identity or trust-anchor incompatibility at any step.

If you genuinely want to test the stronger Linkerd "without downtime" operational claim, that's worthwhile—but make it a separate observation from the cryptographic invariant.

## 10. S-hard currently may not create the state S3 claims to test

This is the second significant experimental-design issue.

You say:

> replace anchor and issuer in one step with --force, with no bundle. Restart nothing … then restart client probes only, then everything.

and hypothesize:

> connections between pods holding different anchors fail until both sides are restarted.

But immediately after the hard control-plane swap, all existing workload proxies still hold the old trust bundle.

Then when you restart client probes, you create:

```
client: new trust anchor
server: old trust anchor
```

Great—that creates the mixed-anchor condition.

But once you restart everything, the condition disappears.

So S3 is really tested at exactly one deliberate stage: after client-only restart.

State that explicitly and make the expected matrix first-class:

| Stage | Client trust | Server trust | Expected |
| --- | --- | --- | --- |
| pre-swap | old | old | works |
| hard swap, no restart | old | old | existing proxy relationship may still work |
| client restart | new | old | trust mismatch experiment |
| all restart | new | new | works |

Even better, capture each side's actual trust-bundle SHA at every stage. Then S3 isn't inferred from restart history; you prove that the endpoints actually held different bundles.

## 11. Generalise the planned credential sequence beyond anchors

You have:

> Planned anchor sequence

I think slice 2 has outgrown an anchor-specific validity mechanism.

R changes issuer. W changes webhook certs. A changes anchor + issuer. S changes bundles + issuer.

I'd make this a generic planned credential transition mechanism:

```
credential-plan:
  trust-anchor:
    - old
    - old+new
    - new
  issuer:
    - old-by-old
    - new-by-new
```

or whatever representation suits Bash.

Validity then means:

> every observed credential transition belongs to the scenario's declared sequence; no undeclared credential changes occurred.

That gives you one conceptual mechanism for R/W/A/S instead of gradually accumulating special-case invariants.

## 12. One operational issue with "build everything, then run"

I like the principle:

> one control run, then every scenario against that same harness tree.

But W and S contain discovery-dependent behavior. W explicitly says the invalid resources are chosen by discovery; W recovery intentionally discovers how supplied webhook values interact with upgrade.

So I'd distinguish implementation discovery from evidence run.

Before freezing the evidence harness commit, you're allowed to run throwaway `_discovery` experiments. Once those settle implementation details:

1. commit harness,
2. clean tree,
3. run control,
4. run R/W/O/K/A/S,
5. no implementation changes between evidence runs unless you invalidate/re-run affected evidence.

That seems consistent with what you're already doing—the slice-1 `_discovery` directory shows the pattern—but I would state it explicitly.

Otherwise "build everything, then run" conflicts slightly with "resolved by first webhook-short reset."

## Approval assessment

I would approve the scenario selection, order, harness generalization, evidence model, and overall slice boundary.

Before implementation, I'd change four things:

1. W: explicitly distinguish the lab's supplied-static-webhook-cert model from Linkerd-managed and external-Secret models, and make the recovery sequence an intentional experiment.
2. K: test tightly enough around 60 days to actually establish the claimed threshold.
3. S-hard: specify and record the old/old → new/old → new/new trust-state matrix; that's the actual S3 experiment.
4. Evidence validity: generalize "planned anchor sequence" into a planned credential-transition mechanism, or at minimum record trust-bundle fingerprints per endpoint for S.

I'd strongly recommend, but wouldn't block approval on, loosening W2/W5's exact-error predictions, making W admission objects unique per tick, sharpening R3, and explicitly defining A's failure timing relative to each proxy's final leaf.

One other thing stands out at the article level: R + O + A form an unusually good controlled comparison. They isolate three superficially similar but mechanically different failures:

- issuer expired → signer invalid and existing identity state behaves one way
- identity unavailable → signer remains valid but temporarily unreachable
- anchor expired → issuer may still be temporally valid, but signing authority is no longer valid

I would make sure the eventual findings document compares those three side by side. That's likely more educational than treating them as three independent certificate incidents.
