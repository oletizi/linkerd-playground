# Tooling Feedback


## session-end 2026-08-09
- Edge Lima VM (2 CPU/4 GiB) sshd resets connections under load (kex_exchange_identification: Connection reset) during rapid limactl shell calls; a VM restart clears it. Space out edge ops.
- SPIRE agent reused a stale node SVID from /opt/spire/data/agent (old server) instead of re-attesting with a fresh join token -> new server rejected it (PermissionDenied). Fix: clear the agent keystore on enrollment.
