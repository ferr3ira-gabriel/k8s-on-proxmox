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

REPO_URL="https://raw.githubusercontent.com/ferr3ira-gabriel/k8s-on-proxmox/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# Source helper functions (local or remote)
if [[ -n "$SCRIPT_DIR" ]] && [[ -f "${SCRIPT_DIR}/misc/build.func" ]]; then
  source "${SCRIPT_DIR}/misc/build.func"
else
  echo "Fetching helper functions from GitHub..."
  source <(curl -fsSL "${REPO_URL}/misc/build.func")
fi

# Phase definitions
declare -A PHASES=(
  [1]="Create LXC Containers"
  [2]="Configure LXC for K3s"
  [3]="Start Containers & Setup"
  [4]="Install Oh My Zsh"
  [5]="Install K3s Control Plane"
  [6]="Join Worker Nodes"
  [7]="Install Helm & NGINX Ingress"
)

START_PHASE=1
RESUME_MODE=false

show_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help              Show this help message
  -l, --list-phases       List all phases
  -s, --status            Check status of existing containers
  -p, --start-phase NUM   Start from phase NUM (1-7)
  -r, --resume            Auto-detect and resume from last completed phase
  -u, --uninstall         Remove all cluster containers and cleanup

Phases:
EOF
  for i in $(seq 1 7); do
    echo "  $i. ${PHASES[$i]}"
  done
  echo ""
  exit 0
}

uninstall_cluster() {
  header_info
  
  echo -e "\n${RD}WARNING: This will destroy all K3s cluster containers!${CL}\n"
  
  # Detect existing containers
  read -r CONTROL_CTID WORKER1_CTID WORKER2_CTID <<< "$(detect_cluster_containers)"
  
  if [[ -z "$CONTROL_CTID" ]] && [[ -z "$WORKER1_CTID" ]] && [[ -z "$WORKER2_CTID" ]]; then
    msg_warn "No cluster containers found"
    exit 0
  fi
  
  echo -e "  ${YW}Containers to be destroyed:${CL}"
  [[ -n "$CONTROL_CTID" ]] && echo -e "    - control.k8s (CT ${CONTROL_CTID})"
  [[ -n "$WORKER1_CTID" ]] && echo -e "    - worker-1.k8s (CT ${WORKER1_CTID})"
  [[ -n "$WORKER2_CTID" ]] && echo -e "    - worker-2.k8s (CT ${WORKER2_CTID})"
  echo ""
  
  if ! whiptail --backtitle "K3s on Proxmox LXC" --title "CONFIRM UNINSTALL" --yesno \
    "Are you sure you want to destroy all cluster containers?\n\nThis action cannot be undone!" 10 60; then
    echo -e "\n${YW}Uninstall cancelled${CL}\n"
    exit 0
  fi
  
  echo ""
  for ctid in $CONTROL_CTID $WORKER1_CTID $WORKER2_CTID; do
    if [[ -n "$ctid" ]] && pct status "$ctid" &>/dev/null; then
      msg_info "Stopping container ${ctid}"
      pct stop "$ctid" 2>/dev/null || true
      sleep 2
      msg_ok "Stopped container ${ctid}"
      
      msg_info "Destroying container ${ctid}"
      pct destroy "$ctid" 2>/dev/null || true
      msg_ok "Destroyed container ${ctid}"
    fi
  done
  
  echo -e "\n${GN}Cluster uninstalled successfully!${CL}\n"
  exit 0
}

list_phases() {
  header_info
  echo -e "\n${BL}Available Phases:${CL}\n"
  for i in $(seq 1 7); do
    echo -e "  ${GN}Phase $i:${CL} ${PHASES[$i]}"
  done
  echo ""
  exit 0
}

check_container_status() {
  local ctid="$1"
  local check="$2"
  
  case "$check" in
    exists)
      pct status "$ctid" &>/dev/null
      ;;
    running)
      [[ "$(pct status "$ctid" 2>/dev/null | awk '{print $2}')" == "running" ]]
      ;;
    has_k3s)
      pct exec "$ctid" -- test -f /usr/local/bin/k3s 2>/dev/null
      ;;
    has_zsh)
      pct exec "$ctid" -- test -d /root/.oh-my-zsh 2>/dev/null
      ;;
    has_kmsg)
      pct exec "$ctid" -- test -f /usr/local/bin/conf-kmsg.sh 2>/dev/null
      ;;
    is_control)
      pct exec "$ctid" -- test -f /var/lib/rancher/k3s/server/node-token 2>/dev/null
      ;;
  esac
}

detect_cluster_containers() {
  # Find containers with k8s hostnames
  local found_control=""
  local found_worker1=""
  local found_worker2=""
  
  for ctid in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    local hostname=$(pct config "$ctid" 2>/dev/null | grep "^hostname:" | awk '{print $2}')
    case "$hostname" in
      control.k8s) found_control="$ctid" ;;
      worker-1.k8s) found_worker1="$ctid" ;;
      worker-2.k8s) found_worker2="$ctid" ;;
    esac
  done
  
  echo "$found_control $found_worker1 $found_worker2"
}

show_status() {
  header_info
  echo -e "\n${BL}Cluster Status:${CL}\n"
  
  read -r CONTROL_CTID WORKER1_CTID WORKER2_CTID <<< "$(detect_cluster_containers)"
  
  if [[ -z "$CONTROL_CTID" ]] && [[ -z "$WORKER1_CTID" ]] && [[ -z "$WORKER2_CTID" ]]; then
    echo -e "  ${YW}No K3s cluster containers found.${CL}"
    echo -e "  Run the script without arguments to create a new cluster.\n"
    exit 0
  fi
  
  echo -e "  ${YW}Detected Containers:${CL}"
  
  for role in "control:$CONTROL_CTID:control.k8s" "worker1:$WORKER1_CTID:worker-1.k8s" "worker2:$WORKER2_CTID:worker-2.k8s"; do
    IFS=':' read -r name ctid hostname <<< "$role"
    if [[ -n "$ctid" ]]; then
      local status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
      local status_color="${RD}"
      [[ "$status" == "running" ]] && status_color="${GN}"
      echo -e "    ${TAB}${hostname} (CT $ctid): ${status_color}${status}${CL}"
    else
      echo -e "    ${TAB}${hostname}: ${RD}not found${CL}"
    fi
  done
  
  echo -e "\n  ${YW}Phase Status:${CL}"
  
  local last_phase=0
  
  # Check Phase 1: Containers exist
  if [[ -n "$CONTROL_CTID" ]] && [[ -n "$WORKER1_CTID" ]] && [[ -n "$WORKER2_CTID" ]]; then
    echo -e "    ${CM} Phase 1: ${PHASES[1]}"
    last_phase=1
  else
    echo -e "    ${CROSS} Phase 1: ${PHASES[1]}"
  fi
  
  # Check Phase 2: LXC configured (check conf file)
  if [[ $last_phase -ge 1 ]] && grep -q "lxc.apparmor.profile" "/etc/pve/lxc/${CONTROL_CTID}.conf" 2>/dev/null; then
    echo -e "    ${CM} Phase 2: ${PHASES[2]}"
    last_phase=2
  elif [[ $last_phase -ge 1 ]]; then
    echo -e "    ${CROSS} Phase 2: ${PHASES[2]}"
  fi
  
  # Check Phase 3: Containers running with kmsg
  if [[ $last_phase -ge 2 ]] && check_container_status "$CONTROL_CTID" running && check_container_status "$CONTROL_CTID" has_kmsg; then
    echo -e "    ${CM} Phase 3: ${PHASES[3]}"
    last_phase=3
  elif [[ $last_phase -ge 2 ]]; then
    echo -e "    ${CROSS} Phase 3: ${PHASES[3]}"
  fi
  
  # Check Phase 4: Oh My Zsh installed
  if [[ $last_phase -ge 3 ]] && check_container_status "$CONTROL_CTID" has_zsh; then
    echo -e "    ${CM} Phase 4: ${PHASES[4]}"
    last_phase=4
  elif [[ $last_phase -ge 3 ]]; then
    echo -e "    ${CROSS} Phase 4: ${PHASES[4]}"
  fi
  
  # Check Phase 5: K3s control plane
  if [[ $last_phase -ge 4 ]] && check_container_status "$CONTROL_CTID" is_control; then
    echo -e "    ${CM} Phase 5: ${PHASES[5]}"
    last_phase=5
  elif [[ $last_phase -ge 4 ]]; then
    echo -e "    ${CROSS} Phase 5: ${PHASES[5]}"
  fi
  
  # Check Phase 6: Workers joined
  if [[ $last_phase -ge 5 ]] && check_container_status "$WORKER1_CTID" has_k3s && check_container_status "$WORKER2_CTID" has_k3s; then
    echo -e "    ${CM} Phase 6: ${PHASES[6]}"
    last_phase=6
  elif [[ $last_phase -ge 5 ]]; then
    echo -e "    ${CROSS} Phase 6: ${PHASES[6]}"
  fi
  
  # Check Phase 7: Helm/NGINX
  if [[ $last_phase -ge 6 ]] && pct exec "$CONTROL_CTID" -- which helm &>/dev/null; then
    echo -e "    ${CM} Phase 7: ${PHASES[7]}"
    last_phase=7
  elif [[ $last_phase -ge 6 ]]; then
    echo -e "    ${CROSS} Phase 7: ${PHASES[7]}"
  fi
  
  echo ""
  if [[ $last_phase -lt 7 ]]; then
    local next_phase=$((last_phase + 1))
    echo -e "  ${YW}Resume with:${CL} $0 --start-phase $next_phase"
  else
    echo -e "  ${GN}Cluster setup complete!${CL}"
  fi
  echo ""
  
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_usage
        ;;
      -l|--list-phases)
        list_phases
        ;;
      -s|--status)
        show_status
        ;;
      -p|--start-phase)
        if [[ -n "$2" ]] && [[ "$2" =~ ^[1-7]$ ]]; then
          START_PHASE="$2"
          RESUME_MODE=true
          shift
        else
          echo "Error: --start-phase requires a number between 1 and 7"
          exit 1
        fi
        ;;
      -r|--resume)
        RESUME_MODE=true
        # Auto-detect will happen later
        ;;
      -u|--uninstall)
        uninstall_cluster
        ;;
      *)
        echo "Unknown option: $1"
        show_usage
        ;;
    esac
    shift
  done
}

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
  # Storage selection for containers (rootdir)
  local storage_list
  storage_list=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1, $1}') || true
  
  if [[ -z "$storage_list" ]]; then
    msg_error "No storage available for containers"
    exit 1
  fi
  
  STORAGE=$(whiptail --backtitle "K3s on Proxmox LXC" --title "CONTAINER STORAGE" --menu \
    "Select storage for containers:" 12 50 4 \
    $storage_list \
    3>&1 1>&2 2>&3) || exit 1
  
  # Storage selection for templates (vztmpl)
  local template_storage_list
  template_storage_list=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1, $1}') || true
  
  if [[ -z "$template_storage_list" ]]; then
    msg_error "No storage available for templates. Enable 'vztmpl' content on a storage."
    exit 1
  fi
  
  # Auto-select if only one template storage, otherwise ask
  local template_count
  template_count=$(echo "$template_storage_list" | wc -w)
  if [[ $template_count -eq 2 ]]; then
    TEMPLATE_STORAGE=$(echo "$template_storage_list" | awk '{print $1}')
    msg_ok "Using ${TEMPLATE_STORAGE} for templates"
  else
    TEMPLATE_STORAGE=$(whiptail --backtitle "K3s on Proxmox LXC" --title "TEMPLATE STORAGE" --menu \
      "Select storage for templates:" 12 50 4 \
      $template_storage_list \
      3>&1 1>&2 2>&3) || exit 1
  fi
  
  # Update template list
  msg_info "Updating template list"
  pveam update &>/dev/null || true
  msg_ok "Template list updated"
  
  # Template selection/download
  local available_templates
  available_templates=$(pveam available --section system 2>/dev/null | grep -E "debian-12" | awk '{print $2}' | head -5) || true
  
  if [[ -z "$available_templates" ]]; then
    msg_error "No Debian 12 templates available. Run 'pveam update' first."
    exit 1
  fi
  
  var_os_template=$(whiptail --backtitle "K3s on Proxmox LXC" --title "TEMPLATE" --menu \
    "Select OS template (Debian 12 recommended):" 15 70 5 \
    $(echo "$available_templates" | while read t; do echo "$t $t"; done) \
    3>&1 1>&2 2>&3) || exit 1
  
  download_template "$TEMPLATE_STORAGE" "$var_os_template" || exit 1
  
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

run_phase_1() {
  echo ""
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BL}  Phase 1: Creating LXC Containers${CL}"
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo ""
  
  create_lxc_container "$CONTROL_CTID" "control.k8s" "$var_os_template" "$STORAGE" "$TEMPLATE_STORAGE" \
    "$var_control_cpu" "$var_control_ram" "$var_control_disk" \
    "$CONTROL_IP" "$GATEWAY" "$CT_PASSWORD" "$var_bridge"
  CREATED_CTIDS+=("$CONTROL_CTID")
  
  create_lxc_container "$WORKER1_CTID" "worker-1.k8s" "$var_os_template" "$STORAGE" "$TEMPLATE_STORAGE" \
    "$var_worker_cpu" "$var_worker_ram" "$var_worker_disk" \
    "$WORKER1_IP" "$GATEWAY" "$CT_PASSWORD" "$var_bridge"
  CREATED_CTIDS+=("$WORKER1_CTID")
  
  create_lxc_container "$WORKER2_CTID" "worker-2.k8s" "$var_os_template" "$STORAGE" "$TEMPLATE_STORAGE" \
    "$var_worker_cpu" "$var_worker_ram" "$var_worker_disk" \
    "$WORKER2_IP" "$GATEWAY" "$CT_PASSWORD" "$var_bridge"
  CREATED_CTIDS+=("$WORKER2_CTID")
}

run_phase_2() {
  echo ""
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BL}  Phase 2: Configuring LXC Containers for K3s${CL}"
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo ""
  
  configure_lxc_for_k3s "$CONTROL_CTID"
  configure_lxc_for_k3s "$WORKER1_CTID"
  configure_lxc_for_k3s "$WORKER2_CTID"
}

run_phase_3() {
  echo ""
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BL}  Phase 3: Starting Containers & Setup${CL}"
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo ""
  
  for ctid in "$CONTROL_CTID" "$WORKER1_CTID" "$WORKER2_CTID"; do
    if [[ "$(pct status "$ctid" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
      start_container "$ctid"
    else
      msg_ok "Container ${ctid} already running"
    fi
    push_kernel_config "$ctid"
    setup_kmsg_in_container "$ctid"
  done
}

ensure_containers_running() {
  for ctid in "$CONTROL_CTID" "$WORKER1_CTID" "$WORKER2_CTID"; do
    if [[ "$(pct status "$ctid" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
      msg_info "Starting container ${ctid}"
      pct start "$ctid"
      sleep 3
      msg_ok "Started container ${ctid}"
    fi
  done
}

run_phase_4() {
  echo ""
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BL}  Phase 4: Installing Oh My Zsh on All Nodes${CL}"
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo ""
  
  ensure_containers_running
  
  install_ohmyzsh "$CONTROL_CTID" "control.k8s"
  install_ohmyzsh "$WORKER1_CTID" "worker-1.k8s"
  install_ohmyzsh "$WORKER2_CTID" "worker-2.k8s"
}

run_phase_5() {
  echo ""
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BL}  Phase 5: Installing K3s Control Plane${CL}"
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo ""
  
  ensure_containers_running
  
  install_k3s_control "$CONTROL_CTID" "control.k8s"
  
  msg_info "Waiting for K3s to be ready"
  sleep 10
  pct exec "$CONTROL_CTID" -- kubectl wait --for=condition=Ready node/control.k8s --timeout=120s 2>/dev/null || true
  msg_ok "K3s control plane is ready"
}

run_phase_6() {
  local control_ip_clean="${CONTROL_IP%/*}"
  
  echo ""
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BL}  Phase 6: Joining Worker Nodes${CL}"
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo ""
  
  ensure_containers_running
  
  # Get token for workers
  K3S_TOKEN=$(get_k3s_token "$CONTROL_CTID")
  
  install_k3s_worker "$WORKER1_CTID" "worker-1.k8s" "$control_ip_clean" "$K3S_TOKEN"
  install_k3s_worker "$WORKER2_CTID" "worker-2.k8s" "$control_ip_clean" "$K3S_TOKEN"
  
  msg_info "Waiting for workers to join the cluster"
  sleep 15
  msg_ok "Workers joined the cluster"
}

run_phase_7() {
  echo ""
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BL}  Phase 7: Installing Additional Components${CL}"
  echo -e "${BL}══════════════════════════════════════════════════════════════${CL}"
  echo ""
  
  ensure_containers_running
  
  if [[ "$var_install_helm" == "yes" ]]; then
    install_helm "$CONTROL_CTID"
    
    if [[ "$var_install_nginx" == "yes" ]]; then
      msg_info "Waiting for cluster to stabilize"
      sleep 10
      install_nginx_ingress "$CONTROL_CTID"
    fi
  else
    msg_ok "Skipped (Helm not requested)"
  fi
}

create_cluster() {
  for phase in $(seq "$START_PHASE" 7); do
    "run_phase_${phase}"
  done
}

show_completion_info() {
  local control_ip_clean="${CONTROL_IP%/*}"
  
  echo -e "\n${GN}═══════════════════════════════════════════════════════════════${CL}"
  echo -e "${GN}              K3s Cluster Created Successfully!                ${CL}"
  echo -e "${GN}═══════════════════════════════════════════════════════════════${CL}\n"
  
  echo -e "  ${YW}Cluster Nodes:${CL}"
  pct exec "$CONTROL_CTID" -- kubectl get nodes 2>/dev/null || echo "  (Run 'kubectl get nodes' on control plane to verify)"
  
  echo -e "\n  ${YW}Container IDs:${CL}"
  echo -e "    ${TAB}Control Plane: ${GN}${CONTROL_CTID}${CL} (${control_ip_clean})"
  echo -e "    ${TAB}Worker 1:      ${GN}${WORKER1_CTID}${CL}"
  echo -e "    ${TAB}Worker 2:      ${GN}${WORKER2_CTID}${CL}"
  
  echo -e "\n  ${YW}To access the cluster:${CL}"
  echo -e "    ${TAB}SSH: ${GN}ssh root@${control_ip_clean}${CL}"
  echo -e "    ${TAB}kubectl: ${GN}kubectl get nodes${CL}"
  
  if [[ "$var_install_nginx" == "yes" ]]; then
    echo -e "\n  ${YW}NGINX Ingress Controller:${CL}"
    echo -e "    ${TAB}Access any node IP on ports 80/443 to reach ingress"
    echo -e "    ${TAB}Check status: ${GN}kubectl get svc -A | grep ingress${CL}"
  fi
  
  echo -e "\n  ${YW}Uninstall cluster:${CL}"
  echo -e "    ${TAB}${GN}bash <(curl -fsSL ${REPO_URL}/k3s-cluster.sh) --uninstall${CL}"
  
  echo -e "\n${GN}═══════════════════════════════════════════════════════════════${CL}"
  echo -e "${GN}                         KUBECONFIG                            ${CL}"
  echo -e "${GN}═══════════════════════════════════════════════════════════════${CL}\n"
  
  echo -e "${YW}Save this to ~/.kube/config on your local machine:${CL}\n"
  
  # Get kubeconfig and replace localhost with actual IP
  pct exec "$CONTROL_CTID" -- cat /etc/rancher/k3s/k3s.yaml 2>/dev/null | sed "s/127.0.0.1/${control_ip_clean}/g"
  
  echo -e "\n${GN}═══════════════════════════════════════════════════════════════${CL}\n"
}

collect_resume_settings() {
  # Auto-detect existing containers
  read -r CONTROL_CTID WORKER1_CTID WORKER2_CTID <<< "$(detect_cluster_containers)"
  
  if [[ -z "$CONTROL_CTID" ]] || [[ -z "$WORKER1_CTID" ]] || [[ -z "$WORKER2_CTID" ]]; then
    msg_error "Could not detect all cluster containers. Run --status to check."
    exit 1
  fi
  
  msg_ok "Detected containers: Control=$CONTROL_CTID, Worker1=$WORKER1_CTID, Worker2=$WORKER2_CTID"
  
  # Get IPs from container configs
  CONTROL_IP=$(pct config "$CONTROL_CTID" 2>/dev/null | grep "^net0:" | grep -oP 'ip=\K[^,]+') || true
  WORKER1_IP=$(pct config "$WORKER1_CTID" 2>/dev/null | grep "^net0:" | grep -oP 'ip=\K[^,]+') || true
  WORKER2_IP=$(pct config "$WORKER2_CTID" 2>/dev/null | grep "^net0:" | grep -oP 'ip=\K[^,]+') || true
  GATEWAY=$(pct config "$CONTROL_CTID" 2>/dev/null | grep "^net0:" | grep -oP 'gw=\K[^,]+') || true
  
  # Set defaults for optional components
  var_install_helm="${var_install_helm:-yes}"
  var_install_nginx="${var_install_nginx:-yes}"
  
  msg_ok "Control IP: $CONTROL_IP"
}

main() {
  # Parse command line arguments first
  parse_args "$@"
  
  header_info
  
  echo -e "\nThis script will create a K3s Kubernetes cluster on Proxmox LXC containers."
  echo -e "Based on the tutorial by Garrett Mills.\n"
  
  # Pre-flight checks
  check_root
  check_proxmox
  load_kernel_modules
  
  # Check for required commands
  if ! command -v whiptail &>/dev/null; then
    msg_error "whiptail is required but not installed"
    exit 1
  fi
  
  if [[ "$RESUME_MODE" == true ]]; then
    # Resume mode - detect existing containers
    echo -e "${YW}Resume mode: Starting from Phase ${START_PHASE}${CL}\n"
    collect_resume_settings
    
    # Confirmation
    if ! whiptail --backtitle "K3s on Proxmox LXC" --title "RESUME CLUSTER SETUP" --yesno \
      "Resume K3s cluster setup from Phase ${START_PHASE}: ${PHASES[$START_PHASE]}\n\nDetected containers:\n  - Control: CT ${CONTROL_CTID}\n  - Worker 1: CT ${WORKER1_CTID}\n  - Worker 2: CT ${WORKER2_CTID}\n\nContinue?" 15 60; then
      clear
      exit 0
    fi
  else
    # Normal mode - create new cluster
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
  fi
  
  # Create cluster with error handling
  if [[ "$RESUME_MODE" != true ]]; then
    trap 'cleanup_on_error "${CREATED_CTIDS[@]}"' ERR
  fi
  
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
