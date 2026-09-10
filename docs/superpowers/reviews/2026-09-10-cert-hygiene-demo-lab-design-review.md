# Third-party review: Cert-Hygiene Demo Lab design

- **Reviewed:** [2026-09-10-cert-hygiene-demo-lab-design.md](../specs/2026-09-10-cert-hygiene-demo-lab-design.md), revision at commit `5d4f92a`
- **Dispositions:** design doc § 9
- The review text below is preserved as received.

---

This is a strong design. I think it is ready to approve with a handful of targeted corrections, rather than needing another structural revision.

The most important improvement over the earlier feasibility framing is that you've cleanly separated source-derived hypotheses from empirical evidence. That makes the lab useful even when Linkerd behaves differently from the source-reading prediction—which is exactly the right epistemic model for an article built around observed failure modes.

## What I would change before approval

### 1. H2 is stated more strongly than the evidence can support

This is the one substantive issue I'd fix.

> H2: At T_iss every workload leaf expires at once. Failure is simultaneous, not gradual.

The first sentence is a certificate property and should be directly observable. The second is a traffic-behavior prediction, but your own H6 predicts an established TLS session may continue through expiry. HTTP pooling may also produce some fuzziness around the boundary.

So "failure is simultaneous" conflates credential invalidity with observable application failure.

I'd change H2 to something like:

> H2: Every workload leaf is clamped to the same T_iss, so all workload identities become expired at the same instant rather than aging out independently. Newly negotiated mTLS connections should begin failing at that boundary; established sessions are tested separately by H6.

That also makes the eventual correction to the article brief more precise. Instead of:

> Leaves are clamped to the issuer's notAfter, so they all expire together at T_iss

as a rebuttal to "failure spreads gradually," I'd eventually distinguish:

> certificate expiry is simultaneous; observed traffic failure may not be.

That distinction is potentially one of the more interesting findings of the article.

### 2. The recovery procedure needs to preserve the experimental variable explicitly

Section 4.3 says:

> Sign a replacement issuer from the same anchor and apply it by the procedure in Replacing expired certificates

Good, but I would add an invariant:

> The replacement issuer must use the existing trust anchor and must not alter the trust-anchor Secret/configuration. Recovery is testing issuer replacement, not trust-root rotation.

That prevents an implementation detail in the current Linkerd docs from accidentally broadening the recovery operation.

I'd also capture the replacement issuer PEM and inspection output under something like:

```
certs/
  trust-anchor.pem
  issuer-initial.pem
  issuer-initial.txt
  issuer-replacement.pem
  issuer-replacement.txt
```

Otherwise `certs/` documents the starting condition but not the credential that caused recovery.

### 3. Record the actual Kubernetes Secret transition

For H8, `IssuerUpdated` plus probe recovery is good evidence, but there is a useful intermediate state worth recording.

Capture metadata—not private key contents—from `linkerd-identity-issuer` before and after replacement, particularly the Secret's UID/resourceVersion and the mounted certificate's fingerprint/serial as observed by the identity container.

That gives you a chain:

Secret updated → projected volume changed → identity observed new issuer → IssuerUpdated → proxies reacquired identities → traffic recovered.

You don't necessarily need every link for the article, but having it in the evidence bundle will make H8 much easier to diagnose if recovery doesn't happen as predicted.

### 4. Make the probe timing evidence slightly stronger

The current format:

```
<UTC ISO-8601> <probe> <ok|fail> <detail>
```

is good for humans, but I'd record at least an attempt/sequence number as well:

```
<UTC> <probe> <seq> <ok|fail> <detail>
```

For `probe-tcp-stream`, also give the connection an ID:

```
... probe-tcp-stream conn=1 seq=37 ok ...
```

That removes ambiguity about whether an `ok` after `T_iss` belongs to the connection established before expiry or to an accidentally re-established connection.

More importantly, make the stream probe fail closed: if its connection dies, it should log the death and not reconnect. Otherwise H6 becomes difficult to interpret.

I would state that explicitly in §2.

### 5. Define exactly what probe-http does after failure

You correctly say HTTP pooling means it cannot distinguish established/new TLS sessions. That's fine because the TCP probes provide the controlled experiment.

But make sure the HTTP probe doesn't have application-level retry behavior that hides a failure. I'd add something like:

> Each HTTP probe records exactly one application request result. Client retries are disabled; connection reuse is left enabled intentionally because this probe represents ordinary application-visible HTTP behavior rather than a handshake detector.

That gives the three probes very clean semantics:

- HTTP = what an ordinary app sees
- TCP-new = forced new connection
- TCP-stream = controlled established connection

That's an excellent experimental arrangement.

### 6. The negative control's `linkerd check` criterion may be unnecessarily brittle

You say:

> linkerd check must show no warnings.

I'd be cautious here. The thing the control really needs to establish is that there are no credential-lifecycle warnings or fatal checks attributable to the harness configuration.

An unrelated environmental warning from k3s/OrbStack/edge Linkerd shouldn't invalidate the experiment if it appears identically in control and fault runs.

I'd formulate the criterion as:

> Every probe stays ok; checks contain no fatal results and no certificate-lifetime warnings. Any other warnings must be identical to, or explained relative to, the scenario run.

That makes the control comparative rather than requiring the environment to be perfectly warning-free.

### 7. Capture Kubernetes object state for the post-expiry pods

For H7, `kubectl get pods -A -o wide` tells you that something isn't Ready, but not necessarily why.

I'd add either `kubectl describe pod` or structured pod YAML for `probe-new` and `server-restarted`, including container state and readiness conditions.

Something like:

```
pods/
  <tick>.txt
  probe-new.yaml
  server-restarted.yaml
  probe-new-describe.txt
  server-restarted-describe.txt
```

This matters because the eventual article claim isn't merely "pod wasn't Ready"; it's approximately "the proxy couldn't acquire identity, which prevented readiness." You want evidence connecting those.

### 8. Clarify server-restarted

This phrase is ambiguous:

> restart a copy of an existing workload (server-restarted)

I'd make the experimental distinction explicit.

You actually want two independent tests: new pod after expiry and replacement pod for an existing workload after expiry.

If `server-restarted` is a separately named Deployment, it's actually another new-workload test rather than a restart test. If you want to test restart semantics, restart the actual `server` Deployment and observe the replacement pod—but doing that would destroy the server used by your established stream.

So your current instinct to preserve `server` is right. I would simply stop calling the second thing "restarted" unless it really is.

For example:

```
probe-new       # workload first created after T_iss
server-recreate # new pod created from an already-existing workload template
```

Or create a dormant restart-target Deployment during baseline and roll it after expiry. That gives you a genuine restart experiment without touching the probe server.

I prefer the latter.

## Two smaller design observations

The evidence hierarchy is particularly good:

source → hypothesis → lab observation → article claim

I would preserve that explicitly during implementation. Don't let scripts start asserting H1–H8 as pass/fail tests. As you correctly say, a falsified hypothesis is a result, not a failed run. Harness validity and hypothesis outcome should remain completely separate concepts.

I also like the decision to retain raw `linkerd check` output rather than normalize it. Since part of the article is going to tell operators what they will actually see, raw CLI output tied to a precise Linkerd version is much more valuable than a parser's interpretation.

## One addition I'd make to versions.txt

Record the actual Git state of both the demo and the Linkerd version under test:

```
demo_repo_commit=
demo_repo_dirty=
linkerd_cli_version=
linkerd_control_plane_version=
proxy_versions=
...
```

If you're using binaries/images corresponding to edge-26.9.1, that's enough for the runtime. But the demo commit is essential for reproducibility because `runs/` alone doesn't tell a future reader exactly which harness implementation generated it.

If dirty runs are allowed, I'd ideally also save `harness.diff`. Otherwise I'd simply refuse evidence-grade runs from a dirty tree.

## Approval assessment

I don't see an architectural problem that should send this back for redesign. The substrate choice is coherent, the evidence bundle is unusually well specified, the control is appropriate, the probe design directly addresses the article's validation contract, and the first slice is well chosen.

The changes I'd consider approval-blocking are only:

1. Separate simultaneous leaf expiry from simultaneous observable failure in H2.
2. Make `probe-tcp-stream` explicitly never reconnect.
3. Disambiguate the "restarted workload" experiment so H7 actually measures what it claims.
4. Capture the replacement issuer as part of the evidence.

The Secret-transition evidence, HTTP retry semantics, pod descriptions, negative-control refinement, and Git-state capture are worthwhile hardening but could reasonably happen during implementation.

With those four corrections, I'd mark the design approved for implementation of the baseline + scenario #5 slice.
