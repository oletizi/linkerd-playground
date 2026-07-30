# linkerd-playground

A collection of hands-on demos exploring Linkerd, service-mesh identity, and
cross-infrastructure trust.

## Demos

| Demo | What it shows |
|------|---------------|
| [spiffe-cross-boundary](demos/spiffe-cross-boundary/) | SPIFFE giving a shared trust domain + workload identity to a non-Kubernetes workload across a real two-machine boundary, via Linkerd mesh expansion. |

## Running a demo

```bash
just demos                              # list demos
just demo spiffe-cross-boundary status  # run a demo target
```

Each demo is self-contained under `demos/<name>/` with its own README.
