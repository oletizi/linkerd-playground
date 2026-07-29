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
kubectl get nodes -o wide
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
