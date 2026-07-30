# Optional connectivity recipe: Tailscale

> **This is one optional way to satisfy the demo's network precondition. The
> [spiffe-cross-boundary demo](README.md) does NOT depend on it** — the demo only
> requires that the two machines can already reach each other over IP, and any
> connectivity that satisfies the [network contract](README.md#connectivity-a-precondition--bring-your-own)
> works (a flat LAN with static routes is the default). Use this recipe only if you
> want to run the two machines across networks / NAT via a Tailscale overlay.

The demo needs the edge to reach the cluster **pod + service CIDRs**
(`10.42.0.0/16`, `10.43.0.0/16`) and resolve `*.cluster.local`. A Tailscale subnet
router provides the L3 reachability; `net/shim.sh` then handles DNS. This recipe was
verified end-to-end with both VMs as their own tailnet nodes.

## Steps

Each VM joins the tailnet as its own node (run `tailscaled` *inside* the VM, not on
the Mac host):

```bash
# in EACH VM:
curl -fsSL https://tailscale.com/install.sh | sudo sh
```

Bring the cluster VM up as a subnet router advertising the cluster CIDRs, and the
edge as a route acceptor:

```bash
# cluster VM:
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
sudo tailscale up --advertise-routes=10.42.0.0/16,10.43.0.0/16 --accept-routes --hostname=linkerd-cluster-vm

# edge VM:
sudo tailscale up --accept-routes --hostname=linkerd-edge-vm
```

Authenticate each node (click the printed login URL), then **approve the advertised
subnet routes** for the cluster VM in the Tailscale admin console:
**Machines → `linkerd-cluster-vm` → Edit route settings →** enable
`10.42.0.0/16` and `10.43.0.0/16`.

Verify the edge received the routes:

```bash
# on the edge VM — should list both CIDRs via tailscale0 (table 52):
ip route show table all | grep -E '10\.4[23]\.'
# and reach the k8s API through the overlay:
curl -sk https://10.43.0.1:443/version | head -c 40
```

## Point the demo at the tailnet addresses

Set the two address variables in `config.local.env` to each VM's **tailnet** IP
(`tailscale ip -4`):

```bash
CLUSTER_NODE_ADDR=<cluster VM tailnet IP>
EDGE_ADDR=<edge VM tailnet IP>
```

Because the subnet router already installs the CIDR routes, `net/shim.sh` detects
them and only configures cluster DNS — no static route is added. From here, follow
the [demo README](README.md) as normal.

## Notes

- `EDGE_ADDR` (the tailnet IP) becomes the `ExternalWorkload`'s address, so
  in-cluster pods reach the edge over the overlay via the cluster node's
  `tailscale0`.
- This crosses genuine NAT/network boundaries, which is why it's useful when the two
  machines are *not* on the same flat LAN. On a single LAN, prefer the default
  static-route path in the demo README.
