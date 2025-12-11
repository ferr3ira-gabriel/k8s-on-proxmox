#!/usr/bin/env bash

# K3s Worker Node Installation Script
# Run this inside an LXC container to join a K3s cluster as worker
#
# Based on tutorial by Garrett Mills
# https://medium.com/better-programming/rancher-k3s-kubernetes-on-proxmox-containers-2228100e2d13

set -euo pipefail

# Colors
RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
HOLD="-"

msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}...${CL}"
}

msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

header_info() {
  clear
  cat <<"EOF"
    __ __ ___          _       __           __             _   __          __   
   / //_/|__ \ ___    | |     / /___  _____/ /_____  _____/ | / /___  ____/ /__ 
  / ,<   __/ // __|   | | /| / / __ \/ ___/ //_/ _ \/ ___/  |/ / __ \/ __  / _ \
 / /| | / __/ \__ \   | |/ |/ / /_/ / /  / ,< /  __/ /  / /|  / /_/ / /_/ /  __/
/_/ |_|/____/|___/    |__/|__/\____/_/  /_/|_|\___/_/  /_/ |_/\____/\__,_/\___/ 
                                                                                 
EOF
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root"
    exit 1
  fi
}

setup_kmsg() {
  msg_info "Setting up /dev/kmsg"
  
  # Create kmsg script
  cat > /usr/local/bin/conf-kmsg.sh << 'KMSGEOF'
#!/bin/sh -e
if [ ! -e /dev/kmsg ]; then
    ln -s /dev/console /dev/kmsg
fi
mount --make-rshared /
KMSGEOF
  
  chmod +x /usr/local/bin/conf-kmsg.sh
  
  # Create systemd service
  cat > /etc/systemd/system/conf-kmsg.service << 'SVCEOF'
[Unit]
Description=Make sure /dev/kmsg exists

[Service]
Type=simple
RemainAfterExit=yes
ExecStart=/usr/local/bin/conf-kmsg.sh
TimeoutStartSec=0

[Install]
WantedBy=default.target
SVCEOF
  
  systemctl daemon-reload
  systemctl enable --now conf-kmsg
  
  msg_ok "Set up /dev/kmsg"
}

update_system() {
  msg_info "Updating system packages"
  apt-get update &>/dev/null
  apt-get upgrade -y &>/dev/null
  msg_ok "Updated system packages"
}

install_dependencies() {
  msg_info "Installing dependencies"
  apt-get install -y curl wget ca-certificates &>/dev/null
  msg_ok "Installed dependencies"
}

join_cluster() {
  local control_ip="$1"
  local token="$2"
  local node_name="$3"
  
  msg_info "Joining K3s cluster as worker"
  curl -sfL https://get.k3s.io | \
    K3S_URL="https://${control_ip}:6443" \
    K3S_TOKEN="${token}" \
    sh -s - --node-name "$node_name"
  msg_ok "Joined K3s cluster as worker"
  
  # Wait for agent to be ready
  msg_info "Waiting for K3s agent to be ready"
  sleep 5
  msg_ok "K3s agent is ready"
}

show_completion_info() {
  local node_name="$1"
  
  echo -e "\n${GN}═══════════════════════════════════════════════════════════════${CL}"
  echo -e "${GN}              Worker Node Joined Successfully!                 ${CL}"
  echo -e "${GN}═══════════════════════════════════════════════════════════════${CL}\n"
  
  echo -e "  ${YW}Node Name:${CL} ${GN}${node_name}${CL}"
  echo -e ""
  echo -e "  ${YW}To verify:${CL}"
  echo -e "    Run on the control plane: ${GN}kubectl get nodes${CL}"
  echo -e ""
  echo -e "${GN}═══════════════════════════════════════════════════════════════${CL}\n"
}

usage() {
  echo "Usage: $0 <control-plane-ip> <cluster-token> [node-name]"
  echo ""
  echo "Arguments:"
  echo "  control-plane-ip  IP address of the K3s control plane"
  echo "  cluster-token     K3s cluster token (from /var/lib/rancher/k3s/server/node-token)"
  echo "  node-name         Name for this worker node (default: worker.k8s)"
  echo ""
  echo "Example:"
  echo "  $0 192.168.1.100 K10abc123...xyz worker-1.k8s"
}

main() {
  local control_ip="${1:-}"
  local token="${2:-}"
  local node_name="${3:-worker.k8s}"
  
  header_info
  
  if [[ -z "$control_ip" ]] || [[ -z "$token" ]]; then
    msg_error "Missing required arguments"
    echo ""
    usage
    exit 1
  fi
  
  echo -e "\nK3s Worker Node Installation"
  echo -e "Control Plane IP: ${GN}${control_ip}${CL}"
  echo -e "Node Name: ${GN}${node_name}${CL}\n"
  
  check_root
  setup_kmsg
  update_system
  install_dependencies
  join_cluster "$control_ip" "$token" "$node_name"
  
  show_completion_info "$node_name"
}

main "$@"
