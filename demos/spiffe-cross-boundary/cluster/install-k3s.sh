#!/usr/bin/env bash
# Runs INSIDE the cluster VM.
set -euo pipefail
# Trim k3s to save RAM: no Traefik, no servicelb. World-readable kubeconfig.
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb --write-kubeconfig-mode=644" sh -
fi
mkdir -p "${HOME}/.kube"
# k3s wrote the kubeconfig world-readable (mode 644), so no sudo needed to read it.
cat /etc/rancher/k3s/k3s.yaml > "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
# k3s returns before the node registers and before CoreDNS is created, so wait
# rather than querying straight away -- otherwise this exits 1 on a good install
# and prints nothing, and the README's next step (confirm the kube-dns ClusterIP)
# cannot be carried out.
for _ in $(seq 1 60); do
  kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready ' && break
  sleep 5
done
for _ in $(seq 1 60); do
  kubectl -n kube-system get svc kube-dns >/dev/null 2>&1 && break
  sleep 5
done
kubectl get nodes -o wide
echo -n 'kube-dns ClusterIP (must match COREDNS_ADDR): '
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
