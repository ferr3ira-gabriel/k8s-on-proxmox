#!/usr/bin/env bash

# K3s Control Plane Installation Script
# Run this inside an LXC container to install K3s as control plane
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
    __ __ ___          ______            __             __   ____  __                
   / //_/|__ \ ___    / ____/___  ____  / /__________  / /  / __ \/ /___ _____  ___  
  / ,<   __/ // __|  / /   / __ \/ __ \/ __/ ___/ __ \/ /  / /_/ / / __ `/ __ \/ _ \ 
 / /| | / __/ \__ \ / /___/ /_/ / / / / /_/ /  / /_/ / /  / ____/ / /_/ / / / /  __/ 
/_/ |_|/____/|___/ \____/\____/_/ /_/\__/_/   \____/_/  /_/   /_/\__,_/_/ /_/\___/  
                                                                                     
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
  apt-get install -y curl wget ca-certificates gnupg &>/dev/null
  msg_ok "Installed dependencies"
}

install_k3s() {
  local node_name="${1:-control.k8s}"
  
  msg_info "Installing K3s control plane"
  curl -sfL https://get.k3s.io | sh -s - \
    --disable traefik \
    --node-name "$node_name" \
    --write-kubeconfig-mode 644
  msg_ok "Installed K3s control plane"
  
  # Wait for K3s to be ready
  msg_info "Waiting for K3s to be ready"
  sleep 5
  kubectl wait --for=condition=Ready node/"$node_name" --timeout=120s 2>/dev/null || true
  msg_ok "K3s is ready"
}

install_helm() {
  msg_info "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash &>/dev/null
  msg_ok "Installed Helm"
}

install_nginx_ingress() {
  msg_info "Installing NGINX Ingress Controller"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx &>/dev/null
  helm repo update &>/dev/null
  helm install nginx-ingress ingress-nginx/ingress-nginx \
    --set controller.publishService.enabled=true &>/dev/null
  msg_ok "Installed NGINX Ingress Controller"
}

show_cluster_info() {
  local node_token
  local cluster_ip
  
  node_token=$(cat /var/lib/rancher/k3s/server/node-token)
  cluster_ip=$(hostname -I | awk '{print $1}')
  
  echo -e "\n${GN}═══════════════════════════════════════════════════════════════${CL}"
  echo -e "${GN}           K3s Control Plane Installed Successfully!           ${CL}"
  echo -e "${GN}═══════════════════════════════════════════════════════════════${CL}\n"
  
  echo -e "  ${YW}Cluster Status:${CL}"
  kubectl get nodes 2>/dev/null || echo "  (K3s is starting...)"
  
  echo -e "\n  ${YW}To join worker nodes, run on each worker:${CL}"
  echo -e "    curl -sfL https://get.k3s.io | K3S_URL=https://${cluster_ip}:6443 K3S_TOKEN=${node_token} sh -s - --node-name <worker-name>"
  
  echo -e "\n  ${YW}Kubeconfig location:${CL}"
  echo -e "    /etc/rancher/k3s/k3s.yaml"
  
  echo -e "\n${GN}═══════════════════════════════════════════════════════════════${CL}\n"
}

main() {
  local node_name="${1:-control.k8s}"
  local install_addons="${2:-yes}"
  
  header_info
  
  echo -e "\nK3s Control Plane Installation"
  echo -e "Node name: ${GN}${node_name}${CL}\n"
  
  check_root
  setup_kmsg
  update_system
  install_dependencies
  install_k3s "$node_name"
  
  if [[ "$install_addons" == "yes" ]]; then
    install_helm
    
    read -r -p "Install NGINX Ingress Controller? [y/N]: " response
    if [[ "${response,,}" =~ ^(y|yes)$ ]]; then
      install_nginx_ingress
    fi
  fi
  
  show_cluster_info
}

main "$@"
