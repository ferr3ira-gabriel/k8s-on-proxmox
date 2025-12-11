# K3s Kubernetes on Proxmox LXC

Deploy a lightweight Kubernetes cluster using Rancher K3s on Proxmox LXC containers.

## Credits

This project is based on the excellent tutorial by **Garrett Mills**:

- **Article**: [Rancher K3s: Kubernetes on Proxmox Containers](https://medium.com/better-programming/rancher-k3s-kubernetes-on-proxmox-containers-2228100e2d13)
- **Author**: [Garrett Mills](https://medium.com/@glmdev) | [garrettmills.dev](https://garrettmills.dev/)
- **Original Post**: [garrettmills.dev/blog](https://garrettmills.dev/blog/2022/04/18/Rancher-K3s-Kubernetes-on-Proxmox-Container/)

Script patterns inspired by [Proxmox VE Helper-Scripts](https://github.com/community-scripts/ProxmoxVE).

## Overview

This script automates the deployment of a K3s Kubernetes cluster on Proxmox VE using LXC containers instead of full VMs. LXC containers provide:

- **Near bare-metal performance** - Kernel-level virtualization
- **Faster boot times** - Almost instant startup
- **Lower resource usage** - Smaller disk footprint
- **Easy resource management** - Adjust CPU/RAM on the fly

### Cluster Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Proxmox VE Host                         │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐  │
│  │  Control Plane  │  │    Worker 1     │  │   Worker 2  │  │
│  │   (LXC 100)     │  │   (LXC 101)     │  │  (LXC 102)  │  │
│  │                 │  │                 │  │             │  │
│  │  - K3s Server   │  │  - K3s Agent    │  │ - K3s Agent │  │
│  │  - kubectl      │  │                 │  │             │  │
│  │  - Helm         │  │                 │  │             │  │
│  │  - NGINX Ingress│  │                 │  │             │  │
│  └─────────────────┘  └─────────────────┘  └─────────────┘  │
│          │                    │                   │         │
│          └────────────────────┴───────────────────┘         │
│                         K3s Cluster                         │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- Proxmox VE 7.x or 8.x
- Root access to Proxmox host
- Network configured (bridge, gateway, DHCP or static IPs)
- Debian 12 container template available

### One-Command Installation

Run directly on your Proxmox VE host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ferr3ira-gabriel/k8s-on-proxmox/main/k3s-cluster.sh)"
```

Or clone and run:

```bash
git clone https://github.com/ferr3ira-gabriel/k8s-on-proxmox.git
cd k8s-on-proxmox
chmod +x k3s-cluster.sh
./k3s-cluster.sh
```

## Tutorial Summary

The script follows these steps from the original tutorial:

### Phase 1: Create LXC Containers

1. Create **privileged** LXC containers (required for Docker/K3s)
2. Configure resources (CPU, RAM, Disk)
3. Assign static IP addresses
4. Set root password

### Phase 2: Configure LXC for K3s

Add required settings to `/etc/pve/lxc/XXX.conf`:

```
lxc.apparmor.profile: unconfined
lxc.cgroup.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
```

### Phase 3: Container Preparation

1. Push kernel boot config to containers
2. Create `/dev/kmsg` symlink (required by Kubelet)
3. Configure systemd service for persistence

### Phase 4: Install K3s Control Plane

```bash
curl -sfL https://get.k3s.io | sh -s - --disable traefik --node-name control.k8s
```

### Phase 5: Join Worker Nodes

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://<control-ip>:6443 K3S_TOKEN=<token> sh -s - --node-name worker-X.k8s
```

### Phase 6: Install NGINX Ingress (Optional)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install nginx-ingress ingress-nginx/ingress-nginx --set controller.publishService.enabled=true
```

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| Control CPU | 4 cores | vCPU for control plane |
| Control RAM | 4096 MB | Memory for control plane |
| Control Disk | 16 GB | Disk size for control plane |
| Worker CPU | 4 cores | vCPU for each worker |
| Worker RAM | 4096 MB | Memory for each worker |
| Worker Disk | 16 GB | Disk size for each worker |
| OS Template | Debian 12 | Base operating system |
| Install Helm | Yes | Helm package manager |
| Install NGINX | Yes | NGINX Ingress Controller |

## Post-Installation

### Access the Cluster

SSH into the control plane:
```bash
ssh root@<control-plane-ip>
kubectl get nodes
```

### Copy Kubeconfig Locally

```bash
# On Proxmox host
pct exec <control-ctid> -- cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config

# Update server address
sed -i 's/127.0.0.1/<control-plane-ip>/g' ~/.kube/config
```

### Verify Cluster

```bash
kubectl get nodes
kubectl get pods -A
```

## File Structure

```
k8s-on-proxmox/
├── README.md                      # This file
├── k3s-cluster.sh                 # Main script (run on Proxmox host)
├── misc/
│   └── build.func                 # Helper functions
└── install/
    ├── k3s-control-install.sh     # Standalone control plane installer
    └── k3s-worker-install.sh      # Standalone worker installer
```

## Manual Installation

If you prefer to install manually inside containers:

### Control Plane

```bash
# Inside control plane LXC
./install/k3s-control-install.sh control.k8s
```

### Worker Nodes

```bash
# Get token from control plane
cat /var/lib/rancher/k3s/server/node-token

# Inside worker LXC
./install/k3s-worker-install.sh <control-ip> <token> worker-1.k8s
```

## Troubleshooting

### Container won't start after config changes

Ensure the container is **stopped** before editing `/etc/pve/lxc/XXX.conf`.

### K3s fails to start

Check if `/dev/kmsg` exists:
```bash
ls -la /dev/kmsg
```

If not, run:
```bash
ln -s /dev/console /dev/kmsg
```

### Workers can't join cluster

1. Verify network connectivity: `ping <control-ip>`
2. Check token is correct
3. Ensure port 6443 is accessible

### NGINX Ingress not working

Wait for pods to be ready:
```bash
kubectl get pods -n default -l app.kubernetes.io/name=ingress-nginx
```

## Adding More Workers

To add additional worker nodes:

1. Create a new LXC container (privileged)
2. Configure LXC settings for K3s
3. Run the worker install script with the cluster token

## Uninstall

Remove the cluster:

```bash
# On Proxmox host
pct stop <control-ctid> <worker1-ctid> <worker2-ctid>
pct destroy <control-ctid> <worker1-ctid> <worker2-ctid>
```

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Related Resources

- [K3s Documentation](https://docs.k3s.io/)
- [Proxmox VE Documentation](https://pve.proxmox.com/wiki/Main_Page)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [Helm Documentation](https://helm.sh/docs/)
