#!/usr/bin/env bash
# k3s helpers. Source after lib/common.sh; do not execute. Runs inside the VM.

# install_k3s: install k3s if absent, trimmed to save RAM (no Traefik, no servicelb),
# with a world-readable kubeconfig copied to ~/.kube/config; then wait for the node
# and CoreDNS.
install_k3s() {
  if ! command -v k3s >/dev/null 2>&1; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb --write-kubeconfig-mode=644" sh -
  fi
  mkdir -p "${HOME}/.kube"
  # k3s wrote the kubeconfig world-readable (mode 644), so no sudo needed to read it.
  cat /etc/rancher/k3s/k3s.yaml > "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  # k3s returns before the node registers and before CoreDNS is created, so wait
  # rather than querying straight away -- otherwise a caller's next kubectl exits 1
  # on a good install and prints nothing.
  local _
  for _ in $(seq 1 60); do
    kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready ' && break
    sleep 5
  done
  for _ in $(seq 1 60); do
    kubectl -n kube-system get svc kube-dns >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl get nodes -o wide
}

# reset_k3s: a fresh, empty cluster -- uninstall k3s if present, then install_k3s.
reset_k3s() {
  if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
    log "uninstalling k3s"
    sudo /usr/local/bin/k3s-uninstall.sh
  fi
  install_k3s
}
