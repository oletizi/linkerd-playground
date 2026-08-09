# Tooling Feedback


## session-end 2026-08-09
- Edge Lima VM (2 CPU/4 GiB) sshd resets connections under load (kex_exchange_identification: Connection reset) during rapid limactl shell calls; a VM restart clears it. Space out edge ops.
- SPIRE agent reused a stale node SVID from /opt/spire/data/agent (old server) instead of re-attesting with a fresh join token -> new server rejected it (PermissionDenied). Fix: clear the agent keystore on enrollment.

## session-end 2026-08-09
- stackctl roadmap advance --to closed (close cascade) treats a roadmap node's ref: URL as a backlog id and fails loud ('unknown backlog id(s) https://...'), blocking a legitimate close. Had to hand-remove the ref: line from ROADMAP.md to close design:feature/astro-docs-site. The cascade should ignore non-id ref: values (URLs) or only treat backlog-shaped ids as closeable.
