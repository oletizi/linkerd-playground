#!/usr/bin/env bash
# Runs INSIDE the edge VM. The ONLY networking the playground performs.
# Assumes CLUSTER_NODE_ADDR is already reachable by whatever means you run (LAN/VPN/overlay).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"; load_config "$HERE"
[ "$CLUSTER_NODE_ADDR" != "CHANGE_ME" ] || die "set CLUSTER_NODE_ADDR in config.local.env"

ping -c1 -W2 "$CLUSTER_NODE_ADDR" >/dev/null || die "cluster node $CLUSTER_NODE_ADDR not reachable — fix your base network first"

# Route the cluster pod + service CIDRs to the cluster node.
# An overlay subnet router (Tailscale/WireGuard) may already provide these routes
# (e.g. Tailscale installs them in table 52); skip when already present.
already_routed() { ip route show table all 2>/dev/null | grep -qE "^${1//./\\.} "; }
for cidr in "$POD_CIDR" "$SVC_CIDR"; do
  if already_routed "$cidr"; then
    log "route for $cidr already present (overlay subnet router?) — skipping"
  else
    sudo ip route replace "$cidr" via "$CLUSTER_NODE_ADDR"
  fi
done

# Resolve *.cluster.local via CoreDNS. The goal is that resolution works; which
# mechanism gets us there depends on the box. Stock Ubuntu runs systemd-resolved
# and takes a drop-in. Some substrates do not: OrbStack masks the unit and owns
# /etc/resolv.conf as a read-only symlink, and minimal images may not ship it at
# all. Pick the mechanism this box actually uses -- then prove DNS works, since
# "the restart did not error" is not the same thing.
resolved_usable() {
  command -v systemctl >/dev/null 2>&1 || return 1
  case "$(systemctl is-enabled systemd-resolved 2>/dev/null)" in
    masked|"") return 1 ;;
  esac
}

if resolved_usable; then
  log "cluster DNS via systemd-resolved drop-in"
  sudo mkdir -p /etc/systemd/resolved.conf.d
  { echo '[Resolve]'; echo "DNS=${COREDNS_ADDR}"; echo 'Domains=~cluster.local'; } \
    | sudo tee /etc/systemd/resolved.conf.d/cluster.conf >/dev/null
  sudo systemctl restart systemd-resolved
else
  log "systemd-resolved is masked or absent here; writing /etc/resolv.conf directly"
  # Snapshot the ORIGINAL resolver config once, and always read the fallbacks --
  # the resolvers for names CoreDNS does not own -- from that snapshot.
  #
  # Not from the live file: after the first run that file is one we wrote, so
  # re-reading it carries our own CoreDNS forward as a "fallback". Two bad
  # consequences, both observed before this was fixed: the nameserver list grows
  # on every run, and a later run pointed at the WRONG CoreDNS still resolves
  # through the stale entry -- so the verification below passes on a box that is
  # in fact misconfigured.
  SNAP=/etc/resolv.conf.pre-shim
  [ -f "$SNAP" ] || cat /etc/resolv.conf 2>/dev/null | sudo tee "$SNAP" >/dev/null
  # Loopback entries are skipped: they point at a local stub (e.g. resolved's
  # 127.0.0.53) that we are replacing.
  fallbacks="$(awk '/^nameserver/ {print $2}' "$SNAP" 2>/dev/null \
                 | grep -vE '^(127\.|::1$)' | grep -v "^${COREDNS_ADDR}$" | head -3)"
  {
    echo 'search cluster.local'
    echo "nameserver ${COREDNS_ADDR}"
    for ns in $fallbacks; do echo "nameserver $ns"; done
  } | sudo tee /etc/resolv.conf.shim >/dev/null
  # Not an in-place edit: /etc/resolv.conf may be a symlink to a read-only file.
  sudo rm -f /etc/resolv.conf
  sudo mv /etc/resolv.conf.shim /etc/resolv.conf
fi

# Verify the thing we actually care about. kubernetes.default always exists once
# the cluster is up, so it needs nothing this demo has yet created. And since no
# fallback resolver serves cluster.local, this resolving proves the CoreDNS we
# just configured is the one that answered -- not merely that some resolver did.
probe=kubernetes.default.svc.cluster.local
for _ in 1 2 3 4 5; do getent hosts "$probe" >/dev/null 2>&1 && break; sleep 1; done
getent hosts "$probe" >/dev/null 2>&1 || die "cluster DNS still does not resolve here.
  '$probe' did not resolve after configuring ${COREDNS_ADDR} as the cluster resolver.
  Most often this means the cluster is not up yet (run the Box A steps first), or
  CoreDNS is not reachable from this box. Check with:
    dig +short @${COREDNS_ADDR} $probe"

log "route + cluster DNS shim applied (pod=${POD_CIDR} svc=${SVC_CIDR} dns=${COREDNS_ADDR}); $probe resolves"
