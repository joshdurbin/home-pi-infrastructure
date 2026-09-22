# Home Pi Infrastructure

A comprehensive Ansible-based infrastructure automation for Raspberry Pi clusters running k3s Kubernetes. This project configures Raspberry Pi instances (Pi 4, Pi 5) as a lightweight k3s Kubernetes cluster, optimized for minimal resource usage by disabling unnecessary hardware features (Bluetooth, audio, camera, HAT interfaces, etc.).

**Table of Contents:**
- [Hardware Setup](#hardware-setup)
- [Quick Start](#quick-start)
- [Makefile Commands](#makefile-commands)
- [System Optimizations](#system-optimizations)
- [User Management](#user-management)
- [K3S Verification](#k3s-verification)
- [K3S Maintenance](#k3s-maintenance)
- [kubectl Access From Your Machine](#kubectl-access-from-your-machine)
- [Storage (Longhorn)](#storage-longhorn)
- [Monitoring & Logging (VictoriaMetrics, VictoriaLogs, Grafana)](#monitoring--logging-victoriametrics-victorialogs-grafana)
- [Tailscale Integration (Optional)](#tailscale-integration-optional)
- [Cluster Configuration](#cluster-configuration)
- [Troubleshooting](#troubleshooting)
- [References](#references)

## Hardware Setup

- **Control Plane**: 3x Raspberry Pi 4B (8GB RAM, 128GB SSD) — `rpi-4b-1`, `rpi-4b-2`, `rpi-4b-3`
- **Worker Nodes**: 3x Raspberry Pi 5 (8GB RAM) — `rpi-5-1`, `rpi-5-2`, `rpi-5-3`
- **Excluded**: Raspberry Pi 3B+ (optional other roles)

Two of the Pi 5 nodes (`rpi-5-2`, `rpi-5-3`) carry a `storage=true` Kubernetes node label and back Longhorn's
distributed storage. Two Pi 5 nodes (`rpi-5-1`, `rpi-5-2`) carry a `telemetry=true` label and host the
VictoriaMetrics/VictoriaLogs storage pods. See [Storage (Longhorn)](#storage-longhorn) and
[Monitoring & Logging](#monitoring--logging-victoriametrics-victorialogs-grafana) below.

Each node has:
- 64-bit Raspberry Pi OS (Lite)
- SSH access enabled
- Static IP configuration
- Python 3 installed

## Project Structure

```
home-pi-infrastructure/
├── site.yml                      # PRIMARY: Unified infrastructure configuration
├── Makefile                      # Convenient commands (make deploy, make verify, etc.)
├── inventory.dist                # Ansible inventory with node groups
├── requirements.yaml             # Ansible collections
├── ansible.cfg                   # Ansible configuration
├── group_vars/                   # Group-based variables
│   ├── all/                      # Variables for all hosts
│   ├── server/                   # k3s server (control plane) config
│   └── agent/                    # k3s agent (worker) config
├── roles/                        # Custom Ansible roles
│   ├── setup/                    # System optimization & packages
│   ├── user_management/          # User & SSH key management
│   ├── k3s_maintenance/          # k3s maintenance script deployment
│   ├── helm/                     # Helm binary install (apt + official GPG key)
│   ├── k8s_labels/                # Applies node labels declared in host_vars (k8s_labels var)
│   ├── longhorn/                 # Distributed storage (Longhorn), 80GB pool on rpi-5-2/rpi-5-3
│   ├── victoria-metrics/         # Metrics storage + Grafana (bundled) + vmagent/vmalert
│   ├── victoria-logs/            # Log storage + Vector log shipper
│   ├── helm_drift_check/         # Post-install verification that Helm's manifest matches live state
│   └── tailscale/                # Tailscale VPN (optional)
├── k3s-ansible/                  # k3s-ansible submodule
└── k3s-maintenance               # k3s maintenance utility script
```

## Prerequisites

On your control machine:
- Ansible 2.13+
- SSH access to all Raspberry Pi instances
- `ansible_user=ansible` with sudo permissions

## Quick Start

### 1. Clone and Initialize

```bash
git clone <this-repo>
cd home-pi-infrastructure
git submodule update --init --recursive
```

### 2. Configure Inventory

Edit `inventory.dist` with your node IPs:

```ini
[all]
rpi-4b-1 ansible_host=192.168.1.13
rpi-4b-2 ansible_host=192.168.1.14
rpi-4b-3 ansible_host=192.168.1.18
rpi-5-1  ansible_host=192.168.1.30

[all:vars]
ansible_user=ansible
ansible_python_interpreter=/usr/bin/python3
ansible_password=ansible
ansible_become_password=ansible
```

### 3. Install Ansible Collections

```bash
make install
```

Or manually:

```bash
ansible-galaxy collection install -r requirements.yaml
```

### 4. Deploy Full Infrastructure

```bash
make deploy
```

Or manually:

```bash
ansible-playbook site.yml -i inventory.dist --ask-vault-pass
```

**What this does:**
- **System Prep**: Disables Bluetooth, WiFi, audio; reduces GPU memory; enables cgroups
- **User Management**: Creates jdurbin user with SSH key and passwordless sudo
- **K3S Deployment**: Installs and configures k3s cluster (servers + agents)
- **Maintenance Tools**: Deploys k3s-maintenance script to all nodes

This is idempotent - safe to run repeatedly to ensure everything stays configured.

## Makefile Commands

The Makefile provides convenient shortcuts for common operations:

```bash
# Installation
make install                    # Install Ansible collections

# Deployment
make deploy                     # Deploy full infrastructure
make deploy-system              # Deploy only system setup
make deploy-k3s                 # Deploy only k3s cluster
make deploy-users               # Deploy only user management
make deploy-maintenance         # Deploy only maintenance tools

# Verification & Monitoring
make verify                     # Check cluster health
make status                     # Show k3s cluster node status
make logs                       # Tail k3s logs from first server

# Maintenance
make drain NODE=rpi-4b-1        # Drain node for maintenance
make uncordon NODE=rpi-4b-1     # Return node to service

# Development
make syntax-check               # Verify playbook syntax
make lint                       # Run ansible-lint
make help                       # Show all commands
```

### Running Specific Components

Use tags to run just certain parts:

```bash
# Only system setup
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags setup

# Only k3s
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags k3s

# Only user management
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags user_management
```

## System Optimizations

This setup disables the following to maximize available memory and CPU:

- On-board Bluetooth
- WiFi
- Audio subsystem (ALSA)
- Camera interface
- I2C, SPI, 1-Wire HAT support
- HDMI output
- GPU memory (reduced to 16MB)
- mpris-proxy (media player service)
- avahi-daemon (mDNS discovery)
- unattended-upgrades (automatic patching daemon)

**Result**: ~200-400MB additional available RAM per node for k3s workloads

## User Management

### Configuration

User configuration is defined in `roles/user_management/defaults/main.yml`:

```yaml
managed_users:
  - username: jdurbin
    groups:
      - adm
    ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKO2h8AOSDnFT0Y96v+O0tkvp10aHp6SpecUBvb3Wmg+"
```

### Adding New Users

1. Edit `roles/user_management/defaults/main.yml`
2. Add new user to the `managed_users` list:

```yaml
managed_users:
  - username: jdurbin
    groups:
      - adm
    ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKO2h8AOSDnFT0Y96v+O0tkvp10aHp6SpecUBvb3Wmg+"
  
  - username: newuser
    groups:
      - adm
    ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

3. Deploy: `make deploy-users` or `make deploy`

### User Properties

- **No Password Login**: Password set to `!` - users cannot login with passwords
- **SSH Key Only**: Authenticated via SSH public key
- **Sudo Without Password**: Users in `adm` group have passwordless sudo access

### Usage

```bash
# Login as user (uses SSH key)
ssh jdurbin@rpi-4b-1

# Run commands with sudo (no password required)
sudo systemctl status k3s
sudo kubectl get nodes

# Drop to root
sudo su -
```

### Removing Users

1. Remove from `managed_users` list in `defaults/main.yml`
2. Manually delete if needed: `sudo userdel -r username`

### Important Notes

- The `ansible` user is NOT managed by this role - it retains its original configuration
- Users must have unique usernames across all hosts
- SSH keys are added via `authorized_keys`

### Common Groups

- `adm`: Full passwordless sudo access
- `sudo`: Standard sudo group (requires password)
- `docker`: Docker access (if installed)
- `video`: GPU/video device access
- `dialout`: Serial port access

## K3S Verification

### Check Cluster Status

```bash
make verify
```

Or manually:

```bash
ssh ansible@rpi-4b-1

# View all nodes
sudo kubectl get nodes

# View system pods
sudo kubectl get pods --all-namespaces

# Check cluster info
sudo kubectl cluster-info

# View node resource usage
sudo kubectl top nodes
```

### Quick Health Check

```bash
ssh ansible@rpi-4b-1 "sudo kubectl get nodes && echo '---' && sudo kubectl get pods -A | grep -E 'coredns|metrics-server|local-path'"
```

All nodes should show `STATUS: Ready` and system pods should be `Running`.

### Test Workload Deployment

```bash
ssh ansible@rpi-4b-1

# Deploy test pod
sudo kubectl run test-pod --image=nginx:latest --restart=Never

# View logs
sudo kubectl logs test-pod

# Clean up
sudo kubectl delete pod test-pod
```

### Remote Access from Your Machine

See [kubectl Access From Your Machine](#kubectl-access-from-your-machine) below for the full setup
(the kubeconfig file is root-owned, so a plain `scp` won't work — it needs to be read via `ssh ... sudo cat`).

## K3S Maintenance

### Installation

The k3s-maintenance script is automatically deployed to all k3s nodes via `site.yml`. Manual deployment:

```bash
make deploy-maintenance
```

Or:

```bash
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags maintenance
```

### Enable Maintenance Mode (Before Reboot)

```bash
ssh ansible@rpi-4b-1
sudo k3s-maintenance -e
```

**What it does:**
1. Drains the node (evicts all pods except DaemonSets)
2. Saves maintenance state with timestamp
3. Marks node as cordoned (no new pods scheduled)

**Safe to do after this:**
- Reboot the node
- Update the OS
- Replace hardware
- Perform maintenance

### Disable Maintenance Mode (After Reboot)

```bash
ssh ansible@rpi-4b-1
sudo k3s-maintenance -d
```

**What it does:**
1. Uncordons the node
2. Returns node to service
3. Pods automatically re-schedule to the node

### Check Maintenance Status

```bash
sudo k3s-maintenance -s
```

Output:
```
[INFO] Node: rpi-4b-1
[INFO] Status: IN SERVICE
[INFO] Enabled at: 2026-09-17T14:30:00
[INFO] Disabled at: 2026-09-17T14:45:00
```

### Complete Reboot Workflow

```bash
# 1. Enter maintenance mode
ssh ansible@rpi-4b-2
sudo k3s-maintenance -e
# Wait for drain to complete

# 2. Verify pods are evicted
ssh ansible@rpi-4b-1
kubectl get pods -A | grep rpi-4b-2
# Should be empty

# 3. Reboot the node
ssh ansible@rpi-4b-2
sudo reboot
# Wait for node to come back up

# 4. Verify node is ready
ssh ansible@rpi-4b-1
kubectl get nodes
# Wait for rpi-4b-2 to show "Ready"

# 5. Return to service
ssh ansible@rpi-4b-2
sudo k3s-maintenance -d

# 6. Verify workloads re-scheduled
ssh ansible@rpi-4b-1
kubectl get pods -A | grep rpi-4b-2
# Should see pods running again
```

### State File

The script maintains state in `/var/lib/k3s-maintenance.state`:

```json
{
  "in_maintenance": false,
  "enabled_at": "2026-09-17T14:30:00.123456",
  "disabled_at": "2026-09-17T14:45:00.654321",
  "node_name": "rpi-4b-2"
}
```

### Troubleshooting k3s-maintenance

**Script can't find kubectl:**
```bash
which kubectl
/usr/local/bin/kubectl
```

**Drain times out:**
Edit the script to increase timeout:
```python
DEFAULT_DRAIN_TIMEOUT = 600  # 10 minutes
```

**Node won't uncordon:**
```bash
kubectl describe node rpi-4b-2
kubectl get pods -A --field-selector=status.phase!=Running
```

**State file stuck:**
```bash
sudo rm /var/lib/k3s-maintenance.state
sudo k3s-maintenance -s
```

## kubectl Access From Your Machine

The cluster's kubeconfig lives on the server nodes at `/etc/rancher/k3s/k3s.yaml`, owned by root, with the
API server address defaulted to `127.0.0.1`. To use `kubectl` (and `helm`) from your own machine:

```bash
# 1. Install kubectl (macOS)
brew install kubectl

# 2. Pull the kubeconfig off a server node (root-owned, so read it over SSH rather than scp)
ssh jdurbin@192.168.1.13 sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config_rpi

# 3. Point the server address at the real IP instead of 127.0.0.1
sed -i '' 's/127.0.0.1/192.168.1.13/' ~/.kube/config_rpi

# 4. Use it
export KUBECONFIG=~/.kube/config_rpi
kubectl get nodes
```

Add the `export KUBECONFIG=...` line to your `~/.zshrc` to make it permanent. This kubeconfig has full
cluster-admin access — fine for a single-user homelab, but keep it as private as any other admin credential.

**Optional client tools** (no in-cluster deployment needed, they just use the kubeconfig above):
- [k9s](https://k9scli.io/) — terminal UI: `brew install k9s`, then run `k9s`
- [Lens](https://k8slens.dev/) or [Headlamp](https://headlamp.dev/) — desktop GUI apps: `brew install --cask lens`

## Storage (Longhorn)

Distributed block storage backing every PVC that requests the `longhorn` StorageClass. Namespace: `longhorn`.

**Capacity model:**
- Data replicas live **only** on `rpi-5-2` and `rpi-5-3` (the `storage=true` labeled nodes) — 80GB usable
  per node, and since Longhorn keeps 2 replicas, plan for ~half of requested storage as the real usable ceiling.
- `longhorn-manager`, the UI, the driver, and the CSI components run on **all 6 nodes** — any pod anywhere
  in the cluster can attach and use a Longhorn volume, even though the data itself only ever lives on the
  two storage nodes. This is deliberate: it's the difference between "where Longhorn's software runs" and
  "where replica data is placed."
- No automatic backups, no automatic snapshots (both explicitly disabled).
- `data_locality: best-effort`, `replicas: 2` — a volume survives either storage node going down.

**Deploy/update just this:**
```bash
ansible-playbook site.yml -i inventory.dist -t helm,storage,longhorn,labels --ask-vault-pass
```

**Access the Longhorn UI:**
```bash
export KUBECONFIG=~/.kube/config_rpi
kubectl -n longhorn port-forward svc/longhorn-frontend 8080:80
```
Then visit `http://localhost:8080`.

**Check volume/node health:**
```bash
kubectl -n longhorn get volumes
kubectl -n longhorn get nodes.longhorn.io
kubectl -n longhorn get pods
```

## Monitoring & Logging (VictoriaMetrics, VictoriaLogs, Grafana)

Metrics and logs for the whole cluster, both retained for **48 hours**. Namespace: `monitoring`.

- **Metrics**: `victoria-metrics-k8s-stack` Helm chart — bundles the VictoriaMetrics operator, `vmsingle`
  (metrics storage), `vmagent` (scraper, cluster-wide), `vmalert`, Alertmanager, kube-state-metrics,
  node-exporter, and **Grafana** (bundled as part of this chart — there's no separate Grafana role).
- **Logs**: `victoria-logs-single` chart — VictoriaLogs server plus **Vector** as the log shipper (runs as
  a DaemonSet on every node, tailing every pod's container logs — no extra config needed for full coverage).
- The stateful pieces (`vmsingle` and the VictoriaLogs server) are pinned via nodeSelector to the
  `telemetry=true` labeled nodes (`rpi-5-1`, `rpi-5-2`). Everything else (Grafana, vmagent, vmalert,
  kube-state-metrics, node-exporter, Vector) is unpinned and can run anywhere.
- **Grafana auth**: anonymous Admin access is enabled (`disable_login_form: true`) — visiting the UI drops
  you straight in with no login prompt. Reasonable for a single-user homelab already gated by kubeconfig
  access; the admin/password secret still exists underneath if you ever want to re-enable the login form.

**Deploy/update just this:**
```bash
ansible-playbook site.yml -i inventory.dist -t helm,storage,longhorn,labels,telemetry --ask-vault-pass
```
(Longhorn's StorageClass must exist first, since Grafana/vmsingle/VictoriaLogs all use Longhorn-backed PVCs —
that's why `storage,longhorn` is included even when you only care about telemetry.)

### Accessing Grafana

```bash
export KUBECONFIG=~/.kube/config_rpi
kubectl -n monitoring port-forward svc/vmks-grafana 3000:80
```
Visit `http://localhost:3000` — no login required.

Pre-configured datasources (all provisioned automatically): **VictoriaMetrics** (x2 — Prometheus-compatible
and native), **Alertmanager**, and **VictoriaLogs**.

### Accessing Logs

Two ways to query logs, both hitting the same VictoriaLogs backend:

**1. VictoriaLogs' own built-in UI (vmui)** — simplest for ad-hoc digging:
```bash
kubectl -n monitoring port-forward svc/vls-victoria-logs-single-server 9428:9428
```
Visit `http://localhost:9428/select/vmui/`.

**2. Grafana Explore** — better once you want logs alongside metrics dashboards. Port-forward Grafana (above),
then: **Explore** (compass icon) → select the **VictoriaLogs** datasource → enter a LogsQL query.

**LogsQL query examples:**
```
*                            # everything
{namespace="longhorn"}       # scope to a namespace
{pod=~"vmsingle.*"}          # pods matching a pattern
error                        # full-text search for "error" anywhere in the line
```

### Accessing Metrics Directly (optional)

```bash
kubectl -n monitoring port-forward svc/vmsingle-vmks-victoria-metrics-k8s-stack 8428:8428
```
VictoriaMetrics' own UI is at `http://localhost:8428/vmui/`; the raw PromQL-compatible API is at `/api/v1/query`.

### Node Labels Reference

| Label | Nodes | Used by |
|---|---|---|
| `storage=true` | rpi-5-2, rpi-5-3 | Longhorn replica placement (physical data) |
| `telemetry=true` | rpi-5-1, rpi-5-2 | vmsingle + VictoriaLogs server pod placement |

Labels are declared per-host in `host_vars/rpi-5-*.yaml` under the `k8s_labels` key, and applied to the live
cluster by the `k8s_labels` role (which reads every host's `k8s_labels` var and patches the matching
Kubernetes Node object — not tied to any single chart-deploying role).

## Tailscale Integration (Optional)

Tailscale is a zero-config VPN built on WireGuard that securely connects nodes over the internet.

**Note:** Currently commented out in `site.yml`. To enable, uncomment the Tailscale play.

### Installation

```bash
ansible-playbook tailscale_deploy.yml -i inventory.dist --ask-vault-pass
```

Or uncomment in `site.yml` and run `make deploy`.

**Deployed to:** Pi4 and Pi5 instances only (excludes Pi 3B+)

### Configuration

After installation, authenticate each node:

```bash
ssh ansible@rpi-4b-1
sudo tailscale up
# Follow the login URL to authenticate
```

### Verify Connection

```bash
sudo tailscale status
```

Output shows:
```
    rpi-4b-1 linux-arm64 100.x.x.x active; idle 2m58s
    rpi-4b-2 linux-arm64 100.x.x.y active; idle 3m1s
```

### Usage

```bash
# SSH via Tailscale IP (from any device on your Tailscale network)
ssh ansible@100.x.x.x

# Or by name
ssh ansible@rpi-4b-1

# Check status
sudo tailscale status

# Disable temporarily
sudo tailscale down

# Re-enable
sudo tailscale up
```

### Advanced: Subnet Router

Route your home network through a Tailscale node:

```bash
sudo tailscale up --advertise-routes=192.168.1.0/24
```

Then approve the route in Tailscale admin panel.

### Advanced: Exit Node

Route internet traffic through a Tailscale node:

```bash
sudo tailscale up --advertise-exit-node
```

Then select it in Tailscale settings.

### Security

- **Encryption**: All traffic encrypted with WireGuard
- **Authentication**: Uses your Tailscale account
- **ACLs**: Control access via Tailscale admin panel
- **Free Tier**: Up to 100 devices at no cost

### Troubleshooting

```bash
# Check service status
sudo systemctl status tailscaled

# View logs
sudo journalctl -u tailscaled -f

# Restart
sudo systemctl restart tailscaled

# Logout (remove from network)
sudo tailscale logout
```

## Cluster Configuration

### K3S Version

Edit `group_vars/server/k3s.yaml` and `group_vars/agent/k3s.yaml`:

```yaml
k3s_version: v1.36.4+k3s1
k3s_release_channel: stable
```

Check available versions: https://github.com/k3s-io/k3s/releases

### K3S Join Token

The cluster uses a pre-shared token in `group_vars/all/main.yaml` (encrypted with Ansible Vault):

```yaml
k3s_join_token: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  ...
```

To update:

```bash
ansible-vault edit group_vars/all/main.yaml
```

### Network Ports

- **API Server Port**: 6443
- **Kubelet Port**: 10250
- **Service NodePort Range**: 30000-32767

Update `inventory.dist` if your network differs.

### Secrets & Variables

- **Encrypted with Vault**: `group_vars/all/main.yaml` (k3s_join_token)
- **Unencrypted**: All other group_vars and host_vars

To rotate secrets:

```bash
ansible-vault encrypt group_vars/all/main.yaml
ansible-vault decrypt group_vars/all/main.yaml
```

## Troubleshooting

### Node Fails to Join Cluster

```bash
ssh ansible@rpi-5-1
sudo journalctl -u k3s-agent -f
```

Common issues:
- **Token mismatch**: Verify `k3s_join_token` in `group_vars/all/main.yaml`
- **Server unreachable**: Check server IP in `group_vars/agent/k3s.yaml`
- **Port blocked**: Ensure port 6443 is open between nodes

### System Pods Not Running

```bash
ssh ansible@rpi-4b-1
sudo kubectl describe pod <pod-name> -n kube-system
sudo kubectl logs <pod-name> -n kube-system
```

### K3S Service Won't Start

Reset k3s on the problematic node:

```bash
ssh ansible@<node>
sudo systemctl stop k3s k3s-agent 2>/dev/null
sudo /usr/local/bin/k3s-uninstall.sh 2>/dev/null
sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s
```

Then re-run: `make deploy` or `make deploy-k3s`

### Can't SSH as User

```bash
# Check if user exists
ssh ansible@rpi-4b-1
id jdurbin

# Check SSH key is installed
cat /home/jdurbin/.ssh/authorized_keys

# Check file permissions
ls -la /home/jdurbin/.ssh/
```

### Sudo Asks for Password

```bash
# Check user is in adm group
id jdurbin

# Check sudoers file
sudo cat /etc/sudoers.d/adm-passwordless
```

### Helm Reports "Upgrade Complete" But a Resource Is Missing/Stuck

This is a known Helm limitation (not specific to this repo or to Ansible) — see
[helm/helm#30819](https://github.com/helm/helm/issues/30819) and
[helm/helm#12021](https://github.com/helm/helm/issues/12021). Helm's three-way merge patch can, in some
cases, report a successful upgrade while silently failing to reconcile a resource back into the cluster —
most commonly after that resource was deleted or modified out-of-band (e.g. `kubectl delete daemonset ...`).

The `helm_drift_check` role runs after every Longhorn/VictoriaMetrics/VictoriaLogs chart install and checks
whether every resource in the chart's current manifest actually exists live. If it detects drift, the
playbook **fails with the exact recovery command to run** (a `helm upgrade` invoked directly rather than
through Ansible, which resolves it). You shouldn't need to do this often — it only happens after manual
`kubectl delete` on a Helm-managed resource — but if you see it:

```bash
export KUBECONFIG=~/.kube/config_rpi
helm get values <release> -n <namespace> -o yaml > /tmp/<release>-values.yaml
helm upgrade <release> <chart-ref> -n <namespace> -f /tmp/<release>-values.yaml
```

### Ansible Vault Password Errors

```bash
# Decrypt to view
ansible-vault view group_vars/all/main.yaml --vault-password-file=<your-password-file>

# Or use prompt
ansible-vault view group_vars/all/main.yaml
```

## Advanced Commands

### Target Specific Groups

```bash
# Only run on k3s servers
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --limit server

# Only run on k3s agents
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --limit agent

# Only run on pi4 nodes
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --limit pi4
```

### K3S Management Playbooks

```bash
# Upgrade k3s to newer version
ansible-playbook k3s-ansible/playbooks/upgrade.yml -i inventory.dist --ask-vault-pass

# Reset k3s cluster (removes all k3s installations)
ansible-playbook k3s-ansible/playbooks/reset.yml -i inventory.dist --ask-vault-pass

# Reboot all cluster nodes
ansible-playbook k3s-ansible/playbooks/reboot.yml -i inventory.dist --ask-vault-pass
```

### Gather Node Facts

```bash
# Get facts from specific node
ansible rpi-4b-1 -m setup -i inventory.dist

# Get facts from all servers
ansible server -m setup -i inventory.dist
```

## References

- [k3s Documentation](https://docs.k3s.io/)
- [k3s-ansible GitHub](https://github.com/k3s-io/k3s-ansible)
- [Ansible Documentation](https://docs.ansible.com/)
- [Raspberry Pi Documentation](https://www.raspberrypi.org/documentation/)
- [Tailscale Documentation](https://tailscale.com/kb/)
- [Tailscale Admin Panel](https://login.tailscale.com/admin)

## Contributing

This is a personal infrastructure project. Feel free to adapt for your own use.
