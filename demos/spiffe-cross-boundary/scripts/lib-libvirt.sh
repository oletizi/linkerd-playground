#!/usr/bin/env bash
# Shared helpers for the Linux single-host topology: both boxes as libvirt VMs on
# the default virbr0 network. Source this; do not execute.
#
# Why libvirt and not Lima on Linux: Lima's only VM-to-VM network on Linux
# (user-v2) rides a QEMU socket netdev that aborts the VM under sustained
# download load, which the Linkerd install reliably triggers. libvirt gives each
# VM a tap device on a real host bridge, so VM-to-VM (and host-to-VM) is ordinary
# kernel routing. See runlog-linux.md F4b.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$(cd "$HERE/../.." && pwd)/lib/common.sh"
load_config "$HERE"

for c in virsh virt-install qemu-img cloud-localds curl ssh; do
  command -v "$c" >/dev/null 2>&1 || die "missing '$c'. Run the one-time host setup first:
    just demo spiffe-cross-boundary host-setup
  (or: sudo bash scripts/host-setup.sh), then log out and back in."
done

# Present is not the same as working. virt-install is a Python script whose
# shebang is '#!/usr/bin/env python3', so it runs under whichever python3 comes
# first on PATH -- and a Homebrew, pyenv, conda or virtualenv python shadows the
# system one while being unable to see the distro's python3-gi in
# /usr/lib/python3/dist-packages. It then dies on 'import gi' with a bare
# ModuleNotFoundError traceback, mid-provision and in virt-install's own voice,
# which reads as a broken demo rather than a shadowed interpreter.
#
# Telling the operator to prefix every command with PATH=/usr/bin is a poor trade:
# it is one more thing to remember on every invocation, and it silently changes
# which of *everything* else they get. The interpreter this script needs is not a
# preference, so run it under the system python ourselves when the inherited one
# cannot. Only if neither works is there something to report.
VIRT_INSTALL=(virt-install)
if ! virt-install --version >/dev/null 2>&1; then
  VIRT_INSTALL_ERR="$(virt-install --version 2>&1 >/dev/null)" || true
  VIRT_INSTALL_BIN="$(command -v virt-install)"
  if [ -x /usr/bin/python3 ] && /usr/bin/python3 "$VIRT_INSTALL_BIN" --version >/dev/null 2>&1; then
    VIRT_INSTALL=(/usr/bin/python3 "$VIRT_INSTALL_BIN")
    log "virt-install cannot run under $(command -v python3 || echo 'the python3 on PATH'); using /usr/bin/python3 for it"
  else
    die "'virt-install' is installed but does not run:

$(printf '%s\n' "$VIRT_INSTALL_ERR" | sed 's/^/    /')

  Usually this is a python3 on PATH that shadows the system one: virt-install runs
  under '#!/usr/bin/env python3' and needs the distro's 'gi' module, which only the
  system interpreter can see. This host resolves python3 to
    $(command -v python3 2>/dev/null || echo '(none)')
  and /usr/bin/python3 could not run virt-install either, so the fallback this
  script would normally take is unavailable. Check that python3-gi is installed
  (on Debian/Ubuntu: sudo apt-get install python3-gi), or deactivate the shadowing
  environment (venv, conda, pyenv, brew) in this shell."
  fi
fi

LIBVIRT_NET="${LIBVIRT_NET:-default}"

# Guest architecture follows the host's. A guest whose arch differs from the host
# has no KVM to run on, so libvirt falls back to full emulation -- which is not an
# error, just unusably slow, and the slowness is easy to blame on the demo rather
# than the substrate. So: derive the image from the host arch, and refuse an
# explicit override that names a different one.
VM_ARCH="$(detect_arch)"
VM_IMAGE_URL="${VM_IMAGE_URL:-$(ubuntu_cloud_image_url "$VM_ARCH")}"
require_matching_image_arch "$VM_IMAGE_URL" "$VM_ARCH" || exit 1
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/linkerd-playground"
SSH_KEY="${DEMO_SSH_KEY:-$HOME/.ssh/linkerd-playground}"
SSH_CONFIG="${DEMO_SSH_CONFIG:-$HOME/.ssh/linkerd-playground.conf}"
VM_USER="${VM_USER:-demo}"

# Deterministic MACs so DHCP reservations are stable across recreates.
mac_for() { case "$1" in *cluster*) echo "52:54:00:5b:1f:0a" ;; *) echo "52:54:00:5b:1f:0b" ;; esac; }

preflight() {
  virsh -c qemu:///system list >/dev/null 2>&1 || die "cannot reach qemu:///system.
Run the one-time host setup first:
    sudo bash $HERE/scripts/host-setup.sh
and then log out and back in (group membership is only picked up by a new login)."
  virsh -c qemu:///system net-info "$LIBVIRT_NET" >/dev/null 2>&1 \
    || die "libvirt network '$LIBVIRT_NET' not found — run scripts/host-setup.sh"
  ensure_pool
}

# The storage pool backing /var/lib/libvirt/images is called 'default' on some
# distros and 'images' on others (Ubuntu 26.04), so discover it rather than
# assuming. POOL is used for the VM disks and cloud-init seeds.
ensure_pool() {
  [ -n "${POOL:-}" ] && return 0
  if [ -n "${LIBVIRT_POOL:-}" ]; then
    virsh -c qemu:///system pool-info "$LIBVIRT_POOL" >/dev/null 2>&1 \
      || die "configured LIBVIRT_POOL='$LIBVIRT_POOL' does not exist"
    POOL="$LIBVIRT_POOL"; return 0
  fi
  local p
  for p in default images; do
    if virsh -c qemu:///system pool-info "$p" >/dev/null 2>&1; then POOL="$p"; return 0; fi
  done
  POOL="$(virsh -c qemu:///system pool-list --name 2>/dev/null | head -1)"
  [ -n "$POOL" ] || die "no libvirt storage pool found — run scripts/host-setup.sh"
  return 0
}

ensure_ssh_key() {
  [ -f "$SSH_KEY" ] && return 0
  log "generating demo ssh key $SSH_KEY"
  mkdir -p "$(dirname "$SSH_KEY")"
  ssh-keygen -t ed25519 -N '' -C 'linkerd-playground' -f "$SSH_KEY" >/dev/null
}

ensure_base_image() {
  mkdir -p "$CACHE_DIR"
  BASE_IMG="$CACHE_DIR/$(basename "$VM_IMAGE_URL")"
  if [ ! -s "$BASE_IMG" ]; then
    log "downloading base image (~600MB, once): $VM_IMAGE_URL"
    # A progress bar is nice on a terminal and 200KB of noise in a captured log.
    local progress=-sS; [ -t 2 ] && progress=--progress-bar
    curl -fSL "$progress" "$VM_IMAGE_URL" -o "$BASE_IMG.part" && mv "$BASE_IMG.part" "$BASE_IMG"
  fi
}

vm_exists()  { virsh -c qemu:///system dominfo "$1" >/dev/null 2>&1; }
vm_running() { [ "$(virsh -c qemu:///system domstate "$1" 2>/dev/null)" = "running" ]; }

# Pin <name> to <ip> in the libvirt network's DHCP table.
dhcp_reserve() { # name ip mac
  local name="$1" ip="$2" mac="$3"
  # Drop any stale entry for this MAC or IP first; both are errors if absent.
  virsh -c qemu:///system net-update "$LIBVIRT_NET" delete ip-dhcp-host \
    "<host mac='$mac'/>" --live --config >/dev/null 2>&1 || true
  virsh -c qemu:///system net-update "$LIBVIRT_NET" add ip-dhcp-host \
    "<host mac='$mac' name='$name' ip='$ip'/>" --live --config >/dev/null
}

# Build the disk + cloud-init seed as libvirt volumes. Done through the libvirt
# API rather than by writing to /var/lib/libvirt/images directly, so none of this
# needs root — libvirtd creates the files.
make_volumes() { # name disk_gb userdata_file
  local name="$1" disk_gb="$2" userdata="$3" seed
  seed="$(mktemp -d)/seed.iso"
  cloud-localds "$seed" "$userdata"

  virsh -c qemu:///system vol-delete --pool "$POOL" "${name}.qcow2"    >/dev/null 2>&1 || true
  virsh -c qemu:///system vol-delete --pool "$POOL" "${name}-seed.iso" >/dev/null 2>&1 || true

  virsh -c qemu:///system vol-create-as "$POOL" "${name}.qcow2" "${disk_gb}G" --format qcow2 >/dev/null
  virsh -c qemu:///system vol-upload --pool "$POOL" "${name}.qcow2" "$BASE_IMG"
  virsh -c qemu:///system vol-resize --pool "$POOL" "${name}.qcow2" "${disk_gb}G" >/dev/null

  virsh -c qemu:///system vol-create-as "$POOL" "${name}-seed.iso" \
    "$(stat -c%s "$seed")" --format raw >/dev/null
  virsh -c qemu:///system vol-upload --pool "$POOL" "${name}-seed.iso" "$seed"
  rm -rf "$(dirname "$seed")"
}

render_userdata() { # hostname extra_packages...
  local host="$1"; shift
  local pubkey; pubkey="$(cat "${SSH_KEY}.pub")"
  local f; f="$(mktemp)"
  {
    echo "#cloud-config"
    echo "hostname: ${host}"
    echo "users:"
    echo "  - name: ${VM_USER}"
    echo "    sudo: \"ALL=(ALL) NOPASSWD:ALL\""
    echo "    shell: /bin/bash"
    echo "    lock_passwd: true"
    echo "    ssh_authorized_keys:"
    echo "      - ${pubkey}"
    echo "package_update: true"
    echo "packages:"
    for p in "$@"; do echo "  - $p"; done
  } > "$f"
  echo "$f"
}

vm_create() { # name ip cpus mem_mib disk_gb packages...
  local name="$1" ip="$2" cpus="$3" mem="$4" disk="$5"; shift 5
  local mac; mac="$(mac_for "$name")"

  if vm_exists "$name"; then
    vm_running "$name" || { log "starting existing $name"; virsh -c qemu:///system start "$name" >/dev/null; }
    log "$name already exists at $ip"
    return 0
  fi

  preflight; ensure_ssh_key; ensure_base_image
  dhcp_reserve "$name" "$ip" "$mac"

  local ud; ud="$(render_userdata "$name" "$@")"
  log "creating $name (${cpus} vcpu, ${mem}MiB, ${disk}GiB) at $ip"
  make_volumes "$name" "$disk" "$ud"
  rm -f "$ud"

  # aarch64 has no BIOS, so an arm64 guest needs UEFI firmware (the
  # qemu-efi-aarch64 package host-setup.sh installs on that arch).
  local firmware=()
  [ "$VM_ARCH" = arm64 ] && firmware=(--boot uefi)

  "${VIRT_INSTALL[@]}" --connect qemu:///system --name "$name" \
    --memory "$mem" --vcpus "$cpus" \
    --disk "vol=${POOL}/${name}.qcow2,bus=virtio" \
    --disk "vol=${POOL}/${name}-seed.iso,device=cdrom" \
    --os-variant ubuntu24.04 \
    --network "network=${LIBVIRT_NET},model=virtio,mac=${mac}" \
    ${firmware[@]+"${firmware[@]}"} \
    --graphics none --import --noautoconsole >/dev/null
}

vm_ssh() { # ip command...
  local ip="$1"; shift
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=5 "${VM_USER}@${ip}" "$@"
}

vm_wait_ready() { # name ip
  local name="$1" ip="$2" i
  log "waiting for $name to finish cloud-init (first boot installs packages)"
  for i in $(seq 1 120); do
    if vm_ssh "$ip" 'cloud-init status --wait >/dev/null 2>&1 || cloud-init status | grep -q done' 2>/dev/null; then
      log "$name ready at $ip"; return 0
    fi
    sleep 5
  done
  die "$name did not become ready at $ip — check: virsh -c qemu:///system console $name"
}

# Copy the whole repo (scripts source lib/common.sh from the repo root) plus the
# local config into the guest.
vm_push_repo() { # ip
  local ip="$1" root
  root="$(cd "$HERE/../.." && pwd)"
  log "copying repo to $ip"
  tar --exclude=.git --exclude=site/node_modules --exclude=site/dist -C "$root" -czf - . \
    | vm_ssh "$ip" 'rm -rf ~/linkerd-playground && mkdir -p ~/linkerd-playground && tar -C ~/linkerd-playground -xzf -'
}

write_ssh_config() {
  cat > "$SSH_CONFIG" <<EOF
# Generated by the spiffe-cross-boundary demo. Use with:
#   ssh -F $SSH_CONFIG linkerd-cluster '<command>'
Host linkerd-cluster
    HostName ${CLUSTER_NODE_ADDR}
Host linkerd-edge
    HostName ${EDGE_ADDR}
Host linkerd-cluster linkerd-edge
    User ${VM_USER}
    IdentityFile ${SSH_KEY}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
  log "ssh config -> $SSH_CONFIG"
}
