# Evidence CDN

A Cloudflare Worker that serves the cert-hygiene lab's recorded runs from the
Backblaze B2 bucket `linkerd-playground`.

## Why

B2's API rate-limits reads. Nothing should read evidence through that API — not a
reader following a citation, not a script fetching a run, not our own upload
verification. Everything reads through this Worker, which serves from Cloudflare's
edge cache and touches B2 only on a cache miss.

Recorded runs are never edited, so responses are marked `immutable` and cached for
a year. Repeat reads never reach B2 at all.

## What it needs

- The bucket is **public** (`allPublic`). The Worker therefore holds no
  credentials, and there is nothing to rotate or leak.
- Uploads use a **write-only** B2 application key held on the machine that
  uploads, never here. That key cannot list or read, which is deliberate: it
  cannot be used to do the thing this Worker exists to prevent.

## Deploy

```
npx wrangler login          # once, interactively
npx wrangler deploy         # from this directory
```

The deploy prints the `*.workers.dev` hostname. That hostname is the base for
every evidence URL, and it belongs in `tools/evidence.sh` and in the reading
guide, so citations and tooling agree.

## Paths

A file keeps the path it had in the repository, minus the `demos/cert-hygiene/`
prefix:

```
runs/06-anchor-expiry/20260912T125027Z/logs/pre-recover/identity.txt
```

becomes

```
https://<worker-host>/runs/06-anchor-expiry/20260912T125027Z/logs/pre-recover/identity.txt
```

There are no directory listings: B2 does not provide them, and the Worker does
not invent them. Every path is resolved from the manifest committed alongside
each run, which also carries the checksum a caller can verify the bytes against.

Each run is also uploaded as a single archive, so materialising a whole run is
one request rather than thousands.
