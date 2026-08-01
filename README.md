# linkerd-playground

A collection of hands-on demos exploring Linkerd, service-mesh identity, and
cross-infrastructure trust.

## Demos

| Demo | What it shows |
|------|---------------|
| [spiffe-cross-boundary](demos/spiffe-cross-boundary/) | **RetailCloud** — a store's on-prem point-of-sale on another machine pushes to a cloud dashboard over the mesh, gated by SPIFFE identity (Linkerd mesh expansion). Live dashboard, network topology, and a built-in tutorial. |

## Running a demo

```bash
just demos                              # list demos
just demo spiffe-cross-boundary status  # run a demo target
```

Each demo is self-contained under `demos/<name>/` with its own README.
