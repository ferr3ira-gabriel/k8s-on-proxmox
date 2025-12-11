#!/usr/bin/env bash

# K3s Kubernetes Cluster on Proxmox LXC
# Based on tutorial by Garrett Mills
# https://medium.com/better-programming/rancher-k3s-kubernetes-on-proxmox-containers-2228100e2d13
#
# Copyright (c) 2024
# License: MIT
# 
# This script creates a K3s Kubernetes cluster with:
# - 1 Control Plane node
# - 2 Worker nodes
# Running on Proxmox LXC containers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helper functions
if [[ -f "${SCRIPT_DIR}/misc/build.func" ]]; then
  source "${SCRIPT_DIR}/misc/build.func"
else
  echo "Error: Helper functions not found. Please ensure misc/build.func exists."
  exit 1
fi

# Default configuration
APP="K3s Cluster"
var_control_cpu="${var_control_cpu:-4}"
var_control_ram="${var_control_ram:-4096}"
var_control_disk="${var_control_disk:-16}"
var_worker_cpu="${var_worker_cpu:-4}"
var_worker_ram="${var_worker_ram:-4096}"
var_worker_disk="${var_worker_disk:-16}"
var_os_template="${var_os_template:-debian-12-standard_12.7-1_amd64.tar.zst}"
var_bridge="${var_bridge:-vmbr0}"
var_install_nginx="${var_install_nginx:-yes}"
var_install_helm="${var_install_helm:-yes}"

# Cluster state
CONTROL_CTID=""
WORKER1_CTID=""
WORKER2_CTID=""
CONTROL_IP=""
WORKER1_IP=""
WORKER2_IP=""
GATEWAY=""
K3S_TOKEN=""
CREATED_CTIDS=()

show_config_summary() {
  echo -e "\n${BL}═══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BL}                    K3s Cluster Configuration                   ${CL}"
  echo -e "${BL}═══════════════════════════════════════════════════════════════${CL}\n"
  echo -e "  ${YW}Control Plane:${CL}"
  echo -e "    ${TAB}Container ID: ${GN}${CONTROL_CTID}${CL}"
  echo -e "    ${TAB}Hostname:     ${GN}control.k8s${CL}"
  echo -e "    ${TAB}IP Address:   ${GN}${CONTROL_IP}${CL}"
  echo -e "    ${TAB}CPU Cores:    ${GN}${var_control_cpu}${CL}"
  echo -e "    ${TAB}Memory:       ${GN}${var_control_ram}MB${CL}"
  echo -e "    ${TAB}Disk:         ${GN}${var_control_disk}GB${CL}"
  echo -e ""
  echo -e "  ${YW}Worker Node 1:${CL}"
  echo -e "    ${TAB}Container ID: ${GN}${WORKER1_CTID}${CL}"
  echo -e "    ${TAB}Hostname:     ${GN}worker-1.k8s${CL}"
  echo -e "    ${TAB}IP Address:   ${GN}${WORKER1_IP}${CL}"
  echo -e "    ${TAB}CPU Cores:    ${GN}${var_worker_cpu}${CL}"
  echo -e "    ${TAB}Memory:       ${GN}${var_worker_ram}MB${CL}"
  echo -e "    ${TAB}Disk:         ${GN}${var_worker_disk}GB${CL}"
  echo -e ""
  echo -e "  ${YW}Worker Node 2:${CL}"
  echo -e "    ${TAB}Container ID: ${GN}${WORKER2_CTID}${CL}"
  echo -e "    ${TAB}Hostname:     ${GN}worker-2.k8s${CL}"
  echo -e "    ${TAB}IP Address:   ${GN}${WORKER2_IP}${CL}"
  echo -e "    ${TAB}CPU Cores:    ${GN}${var_worker_cpu}${CL}"
  echo -e "    ${TAB}Memory:       ${GN}${var_worker_ram}MB${CL}"
  echo -e "    ${TAB}Disk:         ${GN}${var_worker_disk}GB${CL}"
  echo -e ""
  echo -e "  ${YW}Network:${CL}"
  echo -e "    ${TAB}Gateway:      ${GN}${GATEWAY}${CL}"
  echo -e "    ${TAB}Bridge:       ${GN}${var_bridge}${CL}"
  echo -e ""
  echo -e "  ${YW}Options:${CL}"
  echo -e "    ${TAB}Install Helm:          ${GN}${var_install_helm}${CL}"
  echo -e "    ${TAB}Install NGINX Ingress: ${GN}${var_install_nginx}${CL}"
  echo -e "${BL}═══════════════════════════════════════════════════════════════${CL}\n"
}

collect_settings() {
  # Storage selection
  STORAGE=$(whiptail --backtitle "K3s on Proxmox LXC" --title "STORAGE" --menu \
    "Select storage for containers:" 12 50 4 \
    $(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1, $1}') \
    3>&1 1>&2 2>&3) || exit 1
  
  # Template selection/download
  local available_templates
  available_templates=$(pveam available --section system 2>/dev/null | grep -E "debian-12" | awk '{print $2}' | head -5)
  
  if [[ -z "$available_templates" ]]; then
    msg_error "No Debian 12 templates available"
    exit 1
  fi
  
  var_os_template=$(whiptail --backtitle "K3s on Proxmox LXC" --title "TEMPLATE" --menu \
    "Select OS template (Debian 12 recommended):" 15 70 5 \
    $(echo "$available_templates" | while read t; do echo "$t $t"; done) \
    3>&1 1>&2 2>&3) || exit 1
  
  download_template "$STORAGE" "$var_os_template"
  
  # Network configuration
  GATEWAY=$(whiptail --backtitle "K3s on Proxmox LXC" --title "GATEWAY" --inputbox \
    "Enter the network gateway IP:" 10 50 "192.168.1.1" \
    3>&1 1>&2 2>&3) || exit 1
  
  # Control plane IP
  CONTROL_IP=$(whiptail --backtitle "K3s on Proxmox LXC" --title "CONTROL PLANE IP" --inputbox \
    "Enter the Control Plane IP (CIDR format):" 10 50 "192.168.1.100/24" \
    3>&1 1>&2 2>&3) || exit 1
  
  if ! validate_ip "$CONTROL_IP"; then
    msg_error "Invalid IP format. Use CIDR notation (e.g., 192.168.1.100/24)"
    exit 1
  fi
  
  # Worker 1 IP
  WORKER1_IP=$(whiptail --backtitle "K3s on Proxmox LXC" --title "WORKER 1 IP" --inputbox \
    "Enter Worker 1 IP (CIDR format):" 10 50 "192.168.1.101/24" \
    3>&1 1>&2 2>&3) || exit 1
  
  if ! validate_ip "$WORKER1_IP"; then
    msg_error "Invalid IP format. Use CIDR notation (e.g., 192.168.1.101/24)"
    exit 1
  fi
  
  # Worker 2 IP
  WORKER2_IP=$(whiptail --backtitle "K3s on Proxmox LXC" --title "WORKER 2 IP" --inputbox \
    "Enter Worker 2 IP (CIDR format):" 10 50 "192.168.1.102/24" \
    3>&1 1>&2 2>&3) || exit 1
  
  if ! validate_ip "$WORKER2_IP"; then
    msg_error "Invalid IP format. Use CIDR notation (e.g., 192.168.1.102/24)"
    exit 1
  fi
  
  # Container password
  CT_PASSWORD=$(whiptail --backtitle "K3s on Proxmox LXC" --title "PASSWORD" --passwordbox \
    "Enter root password for containers:" 10 50 \
    3>&1 1>&2 2>&3) || exit 1
  
  if [[ -z "$CT_PASSWORD" ]]; then
    msg_error "Password cannot be empty"
    exit 1
  fi
  
  # Network bridge
  var_bridge=$(whiptail --backtitle "K3s on Proxmox LXC" --title "NETWORK BRIDGE" --inputbox \
    "Enter network bridge:" 10 50 "vmbr0" \
    3>&1 1>&2 2>&3) || exit 1
  
  # Control plane resources
  var_control_cpu=$(whiptail --backtitle "K3s on Proxmox LXC" --title "CONTROL PLANE CPU" --inputbox \
    "Enter CPU cores for Control Plane:" 10 50 "4" \
    3>&1 1>&2 2>&3) || exit 1
  
  var_control_ram=$(whiptail --backtitle "K3s on Proxmox LXC" --title "CONTROL PLANE RAM" --inputbox \
    "Enter RAM (MB) for Control Plane:" 10 50 "4096" \
    3>&1 1>&2 2>&3) || exit 1
  
  var_control_disk=$(whiptail --backtitle "K3s on Proxmox LXC" --title "CONTROL PLANE DISK" --inputbox \
    "Enter disk size (GB) for Control Plane:" 10 50 "16" \
    3>&1 1>&2 2>&3) || exit 1
  
  # Worker resources
  var_worker_cpu=$(whiptail --backtitle "K3s on Proxmox LXC" --title "WORKER CPU" --inputbox \
    "Enter CPU cores for Workers:" 10 50 "4" \
    3>&1 1>&2 2>&3) || exit 1
  
  var_worker_ram=$(whiptail --backtitle "K3s on Proxmox LXC" --title "WORKER RAM" --inputbox \
    "Enter RAM (MB) for Workers:" 10 50 "4096" \
    3>&1 1>&2 2>&3) || exit 1
  
  var_worker_disk=$(whiptail --backtitle "K3s on Proxmox LXC" --title "WORKER DISK" --inputbox \
    "Enter disk size (GB) for Workers:" 10 50 "16" \
    3>&1 1>&2 2>&3) || exit 1
  
  # Helm installation
  if whiptail --backtitle "K3s on Proxmox LXC" --title "HELM" --yesno \
    "Install Helm package manager?" 10 50; then
    var_install_helm="yes"
  else
    var_install_helm="no"
  fi
  
  # NGINX Ingress installation
  if whiptail --backtitle "K3s on Proxmox LXC" --title "NGINX INGRESS" --yesno \
    "Install NGINX Ingress Controller?\n\n(Requires Helm)" 10 50; then
    var_install_nginx="yes"
    var_install_helm="yes"
  else
    var_install_nginx="no"
  fi
  
  # Get container IDs
  CONTROL_CTID=$(get_next_ct_id 100)
  WORKER1_CTID=$(get_next_ct_id $((CONTROL_CTID + 1)))
  WORKER2_CTID=$(get_next_ct_id $((WORKER1_CTID + 1)))
}

create_cluster() {
  local control_ip_clean="${CONTROL_IP%/*}"
  local worker1_ip_clean="${WORKER1_IP%/*}"
  local worker2_ip_clean="${WORKER2_IP%/*}"
  
  # Phase 1: Create LXC Containers
  echo -e "\n${BL}Phase 1: Creating LXC Containers${CL}\n"
  
  # Control Plane
  create_lxc_container "$CONTROL_CTID" "control.k8s" "$var_os_template" "$STORAGE" \
    "$var_control_cpu" "$var_control_ram" "$var_control_disk" \
    "$CONTROL_IP" "$GATEWAY" "$CT_PASSWORD" "$var_bridge"
  CREATED_CTIDS+=("$CONTROL_CTID")
  
  # Worker 1
  create_lxc_container "$WORKER1_CTID" "worker-1.k8s" "$var_os_template" "$STORAGE" \
    "$var_worker_cpu" "$var_worker_ram" "$var_worker_disk" \
    "$WORKER1_IP" "$GATEWAY" "$CT_PASSWORD" "$var_bridge"
  CREATED_CTIDS+=("$WORKER1_CTID")
  
  # Worker 2
  create_lxc_container "$WORKER2_CTID" "worker-2.k8s" "$var_os_template" "$STORAGE" \
    "$var_worker_cpu" "$var_worker_ram" "$var_worker_disk" \
    "$WORKER2_IP" "$GATEWAY" "$CT_PASSWORD" "$var_bridge"
  CREATED_CTIDS+=("$WORKER2_CTID")
  
  # Phase 2: Configure LXC for K3s (apparmor, cgroup, capabilities)
  echo -e "\n${BL}Phase 2: Configuring LXC Containers for K3s${CL}\n"
  
  configure_lxc_for_k3s "$CONTROL_CTID"
  configure_lxc_for_k3s "$WORKER1_CTID"
  configure_lxc_for_k3s "$WORKER2_CTID"
  
  # Phase 3: Start containers and push kernel config
  echo -e "\n${BL}Phase 3: Starting Containers${CL}\n"
  
  start_container "$CONTROL_CTID"
  push_kernel_config "$CONTROL_CTID"
  setup_kmsg_in_container "$CONTROL_CTID"
  
  start_container "$WORKER1_CTID"
  push_kernel_config "$WORKER1_CTID"
  setup_kmsg_in_container "$WORKER1_CTID"
  
  start_container "$WORKER2_CTID"
  push_kernel_config "$WORKER2_CTID"
  setup_kmsg_in_container "$WORKER2_CTID"
  
  # Phase 4: Install K3s on Control Plane
  echo -e "\n${BL}Phase 4: Installing K3s Control Plane${CL}\n"
  
  install_k3s_control "$CONTROL_CTID" "control.k8s"
  
  # Wait for K3s to be ready
  msg_info "Waiting for K3s to be ready"
  sleep 10
  pct exec "$CONTROL_CTID" -- kubectl wait --for=condition=Ready node/control.k8s --timeout=120s 2>/dev/null || true
  msg_ok "K3s control plane is ready"
  
  # Get token for workers
  K3S_TOKEN=$(get_k3s_token "$CONTROL_CTID")
  
  # Phase 5: Join Workers to Cluster
  echo -e "\n${BL}Phase 5: Joining Worker Nodes${CL}\n"
  
  install_k3s_worker "$WORKER1_CTID" "worker-1.k8s" "$control_ip_clean" "$K3S_TOKEN"
  install_k3s_worker "$WORKER2_CTID" "worker-2.k8s" "$control_ip_clean" "$K3S_TOKEN"
  
  # Wait for workers to join
  msg_info "Waiting for workers to join the cluster"
  sleep 15
  msg_ok "Workers joined the cluster"
  
  # Phase 6: Install Helm and NGINX Ingress (optional)
  if [[ "$var_install_helm" == "yes" ]]; then
    echo -e "\n${BL}Phase 6: Installing Additional Components${CL}\n"
    install_helm "$CONTROL_CTID"
    
    if [[ "$var_install_nginx" == "yes" ]]; then
      msg_info "Waiting for cluster to stabilize"
      sleep 10
      install_nginx_ingress "$CONTROL_CTID"
    fi
  fi
}

show_completion_info() {
  local control_ip_clean="${CONTROL_IP%/*}"
  
  echo -e "\n${GN}═══════════════════════════════════════════════════════════════${CL}"
  echo -e "${GN}              K3s Cluster Created Successfully!                ${CL}"
  echo -e "${GN}═══════════════════════════════════════════════════════════════${CL}\n"
  
  echo -e "  ${YW}Cluster Nodes:${CL}"
  pct exec "$CONTROL_CTID" -- kubectl get nodes 2>/dev/null || echo "  (Run 'kubectl get nodes' on control plane to verify)"
  
  echo -e "\n  ${YW}To access the cluster:${CL}"
  echo -e "    ${TAB}1. SSH into control plane: ${GN}ssh root@${control_ip_clean}${CL}"
  echo -e "    ${TAB}2. Use kubectl: ${GN}kubectl get nodes${CL}"
  echo -e ""
  echo -e "  ${YW}To copy kubeconfig to your local machine:${CL}"
  echo -e "    ${TAB}${GN}pct exec ${CONTROL_CTID} -- cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config${CL}"
  echo -e "    ${TAB}Then update the server address from 127.0.0.1 to ${GN}${control_ip_clean}${CL}"
  echo -e ""
  
  if [[ "$var_install_nginx" == "yes" ]]; then
    echo -e "  ${YW}NGINX Ingress Controller:${CL}"
    echo -e "    ${TAB}Access any node IP on ports 80/443 to reach ingress"
    echo -e "    ${TAB}Check status: ${GN}kubectl get svc -A | grep ingress${CL}"
    echo -e ""
  fi
  
  echo -e "  ${YW}Container IDs:${CL}"
  echo -e "    ${TAB}Control Plane: ${GN}${CONTROL_CTID}${CL}"
  echo -e "    ${TAB}Worker 1:      ${GN}${WORKER1_CTID}${CL}"
  echo -e "    ${TAB}Worker 2:      ${GN}${WORKER2_CTID}${CL}"
  echo -e ""
  echo -e "${GN}═══════════════════════════════════════════════════════════════${CL}\n"
}

main() {
  header_info
  
  echo -e "\nThis script will create a K3s Kubernetes cluster on Proxmox LXC containers."
  echo -e "Based on the tutorial by Garrett Mills.\n"
  
  # Pre-flight checks
  check_root
  check_proxmox
  
  # Check for required commands
  if ! command -v whiptail &>/dev/null; then
    msg_error "whiptail is required but not installed"
    exit 1
  fi
  
  # Confirmation
  if ! whiptail --backtitle "K3s on Proxmox LXC" --title "K3s CLUSTER SETUP" --yesno \
    "This script will create a K3s Kubernetes cluster with:\n\n  - 1 Control Plane node\n  - 2 Worker nodes\n\nAll running on Proxmox LXC containers.\n\nContinue?" 15 60; then
    clear
    exit 0
  fi
  
  # Collect settings via whiptail
  collect_settings
  
  # Show configuration summary
  header_info
  show_config_summary
  
  # Final confirmation
  if ! whiptail --backtitle "K3s on Proxmox LXC" --title "CONFIRM" --yesno \
    "Ready to create the K3s cluster with the above configuration?\n\nThis will create 3 LXC containers." 10 60; then
    clear
    exit 0
  fi
  
  # Create cluster with error handling
  trap 'cleanup_on_error "${CREATED_CTIDS[@]}"' ERR
  
  header_info
  create_cluster
  
  # Disable error trap
  trap - ERR
  
  # Show completion info
  show_completion_info
  
  msg_ok "K3s cluster setup completed successfully!"
}

# Run main function
main "$@"
