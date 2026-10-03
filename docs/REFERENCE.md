# Reference

> Looking for a quick setup? See the [main README](../README.md) — this is the deep-dive version:
> architecture rationale, every config option, and troubleshooting. Everything here is optional reading;
> the main README is all you need to get the cluster running.

A comprehensive Ansible-based infrastructure automation for Raspberry Pi clusters running k3s Kubernetes. This project configures Raspberry Pi instances (Pi 4, Pi 5) as a lightweight k3s Kubernetes cluster, optimized for minimal resource usage by disabling unnecessary hardware features (Bluetooth, audio, camera, HAT interfaces, etc.).

**Table of Contents:**
- [Hardware Setup](#hardware-setup)
- [Quick Start](#quick-start)
- [Makefile Commands](#makefile-commands)
- [System Optimizations](#system-optimizations)
- [User Management](#user-management)
- [K3S Verification](#k3s-verification)
- [Node Maintenance](#node-maintenance)
- [kubectl Access From Your Machine](#kubectl-access-from-your-machine)
- [GitOps (Argo CD)](#gitops-argo-cd)
- [Storage (Longhorn)](#storage-longhorn)
- [Monitoring (VictoriaMetrics, Grafana)](#monitoring-victoriametrics-grafana)
- [Logging (OpenSearch)](#logging-opensearch)
- [Logs, Also in VictoriaLogs](#logs-also-in-victorialogs)
- [DNS (Blocky)](#dns-blocky)
- [Search (SearXNG)](#search-searxng)
- [Redis Clusters (Blocky + SearXNG Caching)](#redis-clusters-blocky--searxng-caching)
- [Postgres (CloudNativePG)](#postgres-cloudnativepg)
- [Temporal](#temporal)
- [Home Dashboard (Homepage)](#home-dashboard-homepage)
- [Node Rebalancing (descheduler)](#node-rebalancing-descheduler)
- [Vulnerability Scanning (Trivy Operator)](#vulnerability-scanning-trivy-operator)
- [Open WebUI](#open-webui)
- [LiteLLM](#litellm)
- [GO Feature Flag](#go-feature-flag)
- [Snowflake (Tor)](#snowflake-tor)
- [Availability and node maintenance](#availability-and-node-maintenance)
- [Exposing UIs via Tailscale Operator](#exposing-uis-via-tailscale-operator)
- [Tailscale Integration (Optional)](#tailscale-integration-optional)
- [Cluster Configuration](#cluster-configuration)
- [Troubleshooting](#troubleshooting)
- [References](#references)

## Hardware Setup

- **Control Plane**: 3x Raspberry Pi 5 (8GB RAM) — `rpi-5-1`, `rpi-5-2`, `rpi-5-3`
- **Worker Nodes**: 3x Raspberry Pi 4B (4GB RAM, 128GB SSD) — `rpi-4b-1`, `rpi-4b-2`, `rpi-4b-3` — plus a
  4th Raspberry Pi 5 (`rpi-5-4`, worker only, see below)

Control plane moved to the Pi 5s deliberately, not by original design - confirmed live that the Pi 4B
nodes' disks were too slow/inconsistent for etcd's fsync latency sensitivity, causing real API server
instability (intermittent 503s, TLS handshake timeouts, connection resets) under normal cluster load. See
`inventory.dist`'s own `[server]` group comment for the full reasoning, including why `rpi-5-4` joins
`[pi5]`/`[agent]` and never `[server]` - etcd quorum needs a fixed, deliberately-sized
odd-numbered membership, not "however many Pi 5s happen to exist."

The Pi 5 nodes also carry this cluster's disk-heavy workloads (Longhorn, VictoriaMetrics, OpenSearch,
Postgres - see each `host_vars/rpi-5-*.yaml`'s labels) - accepted deliberately alongside etcd, not
overlooked; revisit if the Pi 5 disks turn out not to keep up with both together, but that hasn't been
observed. `rpi-5-4` is a worker (`[agent]`), not control plane, so it doesn't carry etcd's own fsync
sensitivity at all.

(RAM figures confirmed live via `kubectl get nodes -o jsonpath='{.status.capacity.memory}'` - the 4B nodes
report ~3.9GiB, i.e. 4GB boards; this matters for anything sizing container `resources.limits.memory`
against the smaller of the two node classes.)

Two of the Pi 5 nodes (`rpi-5-2`, `rpi-5-3`) carry a `storage=true` Kubernetes node label and back Longhorn's
distributed storage (their disks hold every Longhorn volume's replica *data*; the volumes themselves attach
over the network to pods on any node). `pi5=true` marks the Pi 5s, required by OpenSearch (its Amazon Linux images won't run on a Pi 4B). Everything
else - including VictoriaMetrics, VictoriaLogs and, by default, Postgres - is unpinned and can schedule on any
node with capacity. See [Logging](#logging-opensearch) below. See also
[Storage (Longhorn)](#storage-longhorn) and [Monitoring](#monitoring-victoriametrics-grafana).

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
├── apps/                         # Argo CD's half of this repo - see GitOps (Argo CD) below.
│   │                              # Ansible never reads this directory; Argo CD never reads
│   │                              # anything outside it. Same repo, two independent consumers.
│   ├── longhorn/{application.yaml, values.yaml}
│   ├── victoria-metrics/{application.yaml, values.yaml}
│   ├── opensearch/{application.yaml, values-*.yaml, manifests/, README.md}
│   ├── redis-operator/{application.yaml, values.yaml}   # manages Blocky's/SearXNG's own redis clusters
│   ├── blocky/{application.yaml, values.yaml, manifests/}          # manifests/ includes blocky-cache's
│   │                                                                # RedisReplication/RedisSentinel CRs
│   ├── searxng/{application.yaml, values.yaml, manifests/}         # manifests/ includes searxng-cache's
│   │                                                                # RedisReplication/RedisSentinel CRs
│   └── tailscale-operator/{application.yaml, values.yaml, manifests/}
├── group_vars/                   # Group-based variables
│   ├── all/                      # Variables for all hosts
│   └── k3s_cluster/              # Shared server+agent config (k3s version, cluster API facts)
├── roles/                        # Custom Ansible roles
│   ├── setup/                    # System optimization & packages
│   ├── user_management/          # User & SSH key management
│   ├── helm/                     # Helm binary install (apt + official GPG key)
│   ├── k8s_labels/                # Applies node labels declared in host_vars (k8s_labels var)
│   ├── argocd/                   # Bootstraps Argo CD + the root Application (see GitOps section)
│   ├── k8s_secrets/               # Seeds every Secret/ConfigMap apps/ can't (see GitOps section)
│   ├── helm_drift_check/         # Post-install verification that Helm's manifest matches live state
│   ├── longhorn_prereqs/         # Host prereqs only now (open-iscsi/nfs-common) - chart is Argo CD's job
│   └── tailscale/                # Tailscale VPN client on each node (optional)
└── k3s-ansible/                  # k3s-ansible submodule
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
- **Argo CD Bootstrap**: Installs Argo CD and its root Application, which then continuously syncs
  Longhorn, VictoriaMetrics, OpenSearch, Blocky, SearXNG, the redis-operator (Blocky's and SearXNG's own
  cache clusters), WhoDB, CloudNativePG (Postgres), and the Tailscale Operator from this repo's own
  `apps/` directory on GitHub — see [GitOps (Argo CD)](#gitops-argo-cd).

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
make deploy-secrets             # Seed cluster Secrets/ConfigMaps only
make deploy-argocd              # Bootstrap Argo CD only

# Verification & Monitoring
make verify                     # Check cluster health
make status                     # Show k3s cluster node status
make logs                       # Tail k3s logs from first server

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

**Result**: ~200-400MB additional available RAM per node for k3s workloads

Automatic package updates (`unattended-upgrades`) are **on**: staggered overnight per node, security, point-release,
stable-updates and Raspberry Pi archive packages, never rebooting, and holding back Longhorn's `open-iscsi`/
`nfs-common` - see `roles/setup/README.md`.

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
ssh jdurbin@rpi-5-1

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
ssh ansible@rpi-5-1

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
ssh ansible@rpi-5-1 "sudo kubectl get nodes && echo '---' && sudo kubectl get pods -A | grep -E 'coredns|metrics-server|local-path'"
```

All nodes should show `STATUS: Ready` and system pods should be `Running`.

### Test Workload Deployment

```bash
ssh ansible@rpi-5-1

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

## Node Maintenance

How to take a node out for patching or a reboot. There's no tooling for it: you do it by hand, **one node at a
time** (the cluster doesn't have the capacity for two out at once), from a **control-plane node**.

**Where to run `kubectl`**: SSH to a control-plane node - `rpi-5-1`, `rpi-5-2` or `rpi-5-3` - and use
`sudo kubectl`. Agent nodes (`rpi-4b-*`, `rpi-5-4`) run no API server and have no kubeconfig, so `kubectl` there
fails with `connection refused` on `localhost:8080`. If you are maintaining a control-plane node, run the
commands from a *different* control-plane node.

**1. Check the cluster is healthy first** (from a control-plane node):
```bash
sudo kubectl get nodes                                # all Ready, none SchedulingDisabled
sudo kubectl -n longhorn get volumes.longhorn.io      # attached volumes: ROBUSTNESS healthy
sudo kubectl -n postgres get cluster postgres         # "Cluster in healthy state", 2 instances
sudo kubectl get pods -A | grep -v -E 'Running|Completed'   # nothing unexpected
```
Don't start if another node is already cordoned or a Longhorn volume is rebuilding (see step 5).

**2. Drain the node**:
```bash
sudo kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```
What to expect: its pods are evicted and rescheduled elsewhere. The Postgres primary (if it's on this node)
fails over to the replica, and the old primary is recreated on another node. Single-replica apps are down while
they reschedule - see [Availability and node maintenance](#availability-and-node-maintenance) for the gaps.
The drain returns when the node is empty of everything except DaemonSet pods.

**3. Patch / reboot the node yourself**, e.g. `ssh ansible@<node> sudo reboot`. Packages are already updated
automatically (`unattended-upgrades`, one node at a time overnight, never rebooting), so a reboot is mostly
about picking up a new kernel: check `ls /var/run/reboot-required` on the node. While it's drained, also apply
the packages the automatic updates deliberately hold back (Longhorn's host dependencies):
`sudo apt install --only-upgrade open-iscsi nfs-common`.

**4. Bring it back**:
```bash
sudo kubectl get node <node>          # wait until Ready
sudo kubectl uncordon <node>
```

**5. Wait before doing the next node.** Longhorn rebuilds the replicas that were on a node while it was out, and
until that finishes a volume has a single healthy copy:
```bash
sudo kubectl -n longhorn get volumes.longhorn.io      # wait for every attached volume to be healthy again
sudo kubectl -n postgres get cluster postgres         # 2 instances, healthy
```

**Notes**
- **Control-plane nodes** (`rpi-5-1/2/3`) are the three etcd members. Never have two out at once or etcd loses
  quorum and the API goes away.
- **Storage nodes** (`rpi-5-2`, `rpi-5-3`) hold the Longhorn replica data. While one is out, every volume runs
  on a single replica; Longhorn itself refuses to drain a node that holds the *last* healthy copy of a volume.
- OpenSearch must run on a Pi 5 (`pi5=true`); with four Pi 5s there is always somewhere for it to go.

**If the drain hangs**
- It is almost always Longhorn or a PodDisruptionBudget. Look at what's still there:
  `sudo kubectl get pods -A -o wide --field-selector spec.nodeName=<node>`.
- Longhorn blocks (via its `instance-manager` PodDisruptionBudget) when the node holds a volume's last healthy
  replica. Wait for the volumes to be healthy (step 5) and the drain proceeds.
- A pod with no controller would need `--force` (none exist today).
- To abort: Ctrl-C, then `sudo kubectl uncordon <node>`.

**After the node is back, if something is off**
- **Temporal**: if `temporal-history` crash-loops with `failed to start ringpop`, restart all four services
  together: `sudo kubectl -n temporal rollout restart deploy/temporal-frontend deploy/temporal-matching
  deploy/temporal-worker deploy/temporal-history`.
- **OpenSearch**: it is a single data node, so it is unavailable while that pod moves; it should recover on its
  own. Its client and data nodes are cluster-manager-eligible and on persistent volumes, so evicting either keeps
  its identity. (See `apps/opensearch/manifests/cluster.yaml` for why that matters.)

## kubectl Access From Your Machine

The cluster's kubeconfig lives on the server nodes at `/etc/rancher/k3s/k3s.yaml`, owned by root, with the
API server address defaulted to `127.0.0.1`. To use `kubectl` (and `helm`) from your own machine:

```bash
# 1. Install kubectl (macOS)
brew install kubectl

# 2. Pull the kubeconfig off a server node (root-owned, so read it over SSH rather than scp)
ssh jdurbin@192.168.1.30 sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config_rpi

# 3. Point the server address at the real IP instead of 127.0.0.1
sed -i '' 's/127.0.0.1/192.168.1.30/' ~/.kube/config_rpi

# 4. Use it
export KUBECONFIG=~/.kube/config_rpi
kubectl get nodes
```

Add the `export KUBECONFIG=...` line to your `~/.zshrc` to make it permanent. This kubeconfig has full
cluster-admin access — fine for a single-user homelab, but keep it as private as any other admin credential.

**Optional client tools** (no in-cluster deployment needed, they just use the kubeconfig above):
- [k9s](https://k9scli.io/) — terminal UI: `brew install k9s`, then run `k9s`
- [Lens](https://k8slens.dev/) or [Headlamp](https://headlamp.dev/) — desktop GUI apps: `brew install --cask lens`

## GitOps (Argo CD)

Longhorn, VictoriaMetrics, VictoriaLogs, OpenSearch, Blocky, SearXNG, redis-operator, WhoDB,
CloudNativePG, Postgres, Temporal, Homepage, Open WebUI, the descheduler, Trivy Operator, and the
Tailscale Operator are no longer installed or upgraded by Ansible. Argo CD runs in-cluster (namespace
`argocd`) and continuously reconciles every child `Application` under this **same** repo's `apps/`
directory (one directory can hold more than one `Application` - some apps are deliberately split across
a few, ordered by `sync-wave`, to avoid CRD-ordering races - so this is deliberately not quoted as a
single number that would just go stale again at the next addition) — edit a file there, commit, and Argo
CD applies it within its
next poll cycle (or immediately via `argocd app sync` / the UI). This replaced hand-templating every
chart's values through Jinja and running `kubectl`/`helm` manually to fix drift — Argo CD's own continuous
reconciliation makes drift structurally impossible to miss.

**One repo, two independent consumers:**
- **Ansible** (everything outside `apps/`): bare-metal OS setup, k3s cluster bootstrap, node
  labels/hardware/reboot orchestration, and the one-time Argo CD install + bootstrap
  `Application`/`AppProject` (`roles/argocd/`). Ansible never reads `apps/`.
- **Argo CD** (`apps/` only): one directory per app, each with an `Application` manifest (Argo CD's
  multi-source feature: one source is the real upstream Helm chart, a second supplies `values.yaml` from
  this same repo, a third — where needed — supplies plain manifests like NetworkPolicies or Ingresses)
  plus that `values.yaml`. Argo CD's own root `Application` (the classic "app of apps" pattern) watches
  `apps/*/application.yaml` and syncs each one as a child Application. Argo CD never reads anything
  outside `apps/`.

Keeping Argo CD's own bootstrap config in the same repo it manages (rather than a separate one) is simpler
to operate day to day, and there's no real conflict: the two halves don't overlap and each tool ignores
the other's files entirely.

**Where Argo CD reads from**: this repo is public on GitHub
(`https://github.com/joshdurbin/home-pi-infrastructure.git`), so Argo CD (running in-cluster on the Pis)
just points straight at it — no credentials needed, same as the public Helm chart repos above. `git push`
from anywhere and Argo CD picks it up within its next poll cycle (or immediately via `argocd app sync` /
the UI).

(This repo started out served locally over the LAN via `git daemon`, back when it wasn't yet pushed to
GitHub — that's gone now that it's a public GitHub repo. If it were private instead, Argo CD would need a
credential: either a read-only SSH deploy key or a fine-grained PAT, stored as a `Secret` in the `argocd`
namespace labeled `argocd.argoproj.io/secret-type: repository` — worth revisiting if this repo is ever made
private.)

**Bootstrap Argo CD:**
```bash
ansible-playbook site.yml -i inventory.dist -t helm,argocd --ask-vault-pass
```
Then check in:
```bash
kubectl -n argocd get pods
kubectl -n argocd get applications
```
Every child Application (plus `root`) should show `Synced`/`Healthy` (see the GitOps section above for
why this repo stopped quoting an exact count here). Access the UI at
`https://argocd.<tailnet>.ts.net` once the Tailscale Operator Application has synced (see below), or via
`kubectl -n argocd port-forward svc/argocd-server 8080:443` in the meantime — it runs with
`server.insecure: true` (TLS is terminated by Tailscale, same as every other UI in this cluster), and
`dex`/`notifications` are disabled (no SSO, unused in a single-user homelab).

**Argo CD's own metrics**: `controller.metrics.enabled`/`server.metrics.enabled`/
`repoServer.metrics.enabled`/`applicationSet.metrics.enabled` (`roles/argocd/templates/values.j2` - Argo
CD's own install is Ansible-driven, not GitOps, so its chart values live here rather than in `apps/`)
each create a dedicated metrics Service, all four sharing the label `app.kubernetes.io/part-of: argocd`
and a port named `http-metrics` - confirmed via a real `helm template` render, not assumed. Scraped by
`apps/argocd-metrics/` (its own tiny Application, not another Ansible-templated resource) - it needs
victoria-metrics' `VMServiceScrape` CRD (wave 1), which doesn't exist yet at the point Ansible bootstraps
Argo CD on a fresh install, so it has to be GitOps-managed (Argo CD's own retry/backoff handles that race
gracefully; a one-shot Ansible task wouldn't). Dashboard: grafana.com ID 14584, the official upstream
"ArgoCD" dashboard.

**Secrets bridge**: `apps/` must never contain real credentials, but a few of these apps need some (Grafana
admin password, Tailscale OAuth client, SearXNG's `secret_key` and metrics password, OpenSearch's admin
password, Open WebUI's session-signing key — Blocky needs none at all, see below).
Those stay exactly where they already were — Ansible Vault, in `group_vars/all/main.yaml` — and a single
role, **`k8s_secrets`**, applies the resulting `Secret`/`ConfigMap` objects directly to the cluster,
decoupled from git
entirely.

This one role replaced what used to be three separate roles (`victoria-metrics`, `adguard_home`,
`tailscale_operator`), each named after an app it no longer actually manages — misleading, since none of
them touch the app itself anymore, only a credential it needs. `k8s_secrets` is deliberately generic and
data-driven instead: it's a two-task loop (`roles/k8s_secrets/tasks/main.yaml`) over a single list,
**`k8s_secrets`**, defined in `group_vars/all/cluster_secrets.yaml` — one file that's the complete answer
to "what gets seeded into the cluster and why." Adding another one later means adding a list entry there,
not writing a new role.

`apps/`'s `values.yaml` files reference those objects by name (`existingSecret: ...`, or a chart's own
"expects a pre-created Secret" convention) rather than embedding any credential inline. Run this before the
Argo CD bootstrap above (or any time after — it's idempotent) so the objects exist before each
Application's first sync:
```bash
ansible-playbook site.yml -i inventory.dist -t secrets --ask-vault-pass
```

## Storage (Longhorn)

Distributed block storage backing every PVC that requests the `longhorn` StorageClass. Namespace: `longhorn`.
**The chart install and all settings now live in this repo's `apps/` directory** (see [GitOps (Argo CD)](#gitops-argo-cd)) — Argo CD
reconciles it continuously; this repo only handles the host-level package prerequisites Longhorn needs on
every node.

**Capacity model** (see `apps/longhorn/values.yaml` in this repo's `apps/` directory for the actual settings):
- Data replicas live **only** on `rpi-5-2` and `rpi-5-3` (the `storage=true` labeled nodes) — 80GB usable
  per node, and since Longhorn keeps 2 replicas, plan for ~half of requested storage as the real usable ceiling.
- `longhorn-manager`, the UI, the driver, and the CSI components run on **all 6 nodes** — any pod anywhere
  in the cluster can attach and use a Longhorn volume, even though the data itself only ever lives on the
  two storage nodes. This is deliberate: it's the difference between "where Longhorn's software runs" and
  "where replica data is placed."
- No automatic backups, no automatic snapshots (both explicitly disabled).
- `data_locality: best-effort`, `replicas: 2` — a volume survives either storage node going down.

**Deploy/update the host prerequisites only** (for the actual chart config, edit
`apps/longhorn/values.yaml` and commit — Argo CD picks it up on its own):
```bash
ansible-playbook site.yml -i inventory.dist -t storage,longhorn --ask-vault-pass
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

## Monitoring (VictoriaMetrics, Grafana)

Metrics for the whole cluster, retained for **7 days**. Namespace: `monitoring`.
**The chart install and all settings now live in this repo's `apps/` directory** (see [GitOps (Argo CD)](#gitops-argo-cd))
(`apps/victoria-metrics/`) — Argo CD reconciles it continuously. This repo's only
remaining job here is seeding the Grafana admin credentials Secret via the generic `k8s_secrets` role (see
[Secrets bridge](#gitops-argo-cd) above for why that can't live in git).

- **Metrics**: `victoria-metrics-k8s-stack` Helm chart — bundles the VictoriaMetrics operator, `vmsingle`
  (metrics storage), `vmagent` (scraper, cluster-wide), `vmalert`, Alertmanager, kube-state-metrics,
  node-exporter, and **Grafana** (bundled as part of this chart — there's no separate Grafana role).
- Nothing here is pinned to a node. `vmsingle`'s 10Gi PVC is a Longhorn volume (network-attached, so the pod
  can land on any node - on a 4GB Pi 4B too, since its 2Gi memory request is only satisfied where that much
  is free), and Grafana, vmagent, vmalert, kube-state-metrics and node-exporter were never pinned.
- **Grafana auth**: anonymous Admin access is enabled (`disable_login_form: true`) — visiting the UI drops
  you straight in with no login prompt. Reasonable for a single-user homelab already gated by kubeconfig
  access; the admin/password secret still exists underneath if you ever want to re-enable the login form.

**Seed/update the Grafana admin credentials Secret** (for the actual chart config, edit
`apps/victoria-metrics/values.yaml` and commit):
```bash
ansible-playbook site.yml -i inventory.dist -t secrets --ask-vault-pass
```

### Accessing Grafana

```bash
export KUBECONFIG=~/.kube/config_rpi
kubectl -n monitoring port-forward svc/vmks-grafana 3000:80
```
Visit `http://localhost:3000` — no login required.

Pre-configured datasources (all provisioned automatically): **VictoriaMetrics** (x2 — Prometheus-compatible
and native) and **Alertmanager**. See [Logging](#logging-opensearch) below for logs — no longer a Grafana
datasource, since logs moved from VictoriaLogs to OpenSearch.

Dashboards can be imported from grafana.com via `roles/grafana_dashboards/` (`ansible-playbook site.yml -i
inventory.dist --tags grafana`) — see that role's own README for what's included and why, and for the
handful already provisioned automatically by the chart itself (Kubernetes cluster/node views, CoreDNS,
etcd, Node Exporter Full, and all four VictoriaMetrics dashboards).

### Accessing Metrics Directly (optional)

```bash
kubectl -n monitoring port-forward svc/vmsingle-vmks-victoria-metrics-k8s-stack 8428:8428
```
VictoriaMetrics' own UI is at `http://localhost:8428/vmui/`; the raw PromQL-compatible API is at `/api/v1/query`.

## Logging (OpenSearch)

Container + host logs for the whole cluster, retained for **~7 days** (index-boundary granularity, not
an exact cutoff - see below). Namespace: `opensearch`. The **OpenSearch Kubernetes Operator** reconciles
a set of custom resources in `apps/opensearch/manifests/` into the actual running cluster - Argo CD
installs the operator and applies those resources continuously. See `apps/opensearch/README.md` for the
full rationale (why an operator over the plain chart an earlier version of this app used, why OpenSearch
over Elasticsearch/Kibana naming, why TLS + auth are mandatory here unlike everywhere else in this
cluster, why Vector rather than a new log shipper); this section covers day-to-day access.

Dual-shipped to `apps/victoria-logs/` too (VictoriaLogs, re-added alongside OpenSearch rather than
replacing it again - see [Logs, Also in VictoriaLogs](#logs-also-in-victorialogs) below) - the same
Vector DaemonSet writes every log line to both backends, same retention target on both, so either can be
used to cross-check the other.

**Prerequisite**: `opensearch_admin_password` must be set in Vault (`ansible-vault edit
group_vars/all/main.yaml`) before this deploys successfully - see [Secrets & Variables](#secrets--variables).

- **Topology**: an `OpenSearchCluster` custom resource (`apps/opensearch/manifests/cluster.yaml`) with two
  node pools (`client`: cluster-manager + coordinating, no PVC; `data`: the only pool with a PVC,
  `storageClassName: longhorn`), plus its own `dashboards` section (not a separate chart under the
  operator). Single replica per pool - evaluation-scale, not HA. The data pool is left unpinned
  (scheduler's choice of node) - see `cluster.yaml`'s own comment on the tradeoff that implies.
- **Log shipping**: the same Vector DaemonSet from the old VictoriaLogs setup, writing to daily
  `logs-*`/`logs-host-*` indices via OpenSearch's bulk API, now authenticating with TLS + basic auth
  (`apps/opensearch/values-vector.yaml`).
- **Retention**: an `OpenSearchISMPolicy` custom resource (`apps/opensearch/manifests/ism-policy.yaml`)
  deletes `logs-*` indices once `min_index_age: 7d`; an `OpenSearchIndexTemplate`
  (`apps/opensearch/manifests/index-template.yaml`) sets `number_of_replicas: 0` for those same indices
  (required, not an optimization - there's only one data node).
- **Auth**: unlike everywhere else in this cluster (Grafana's anonymous Admin, Argo CD via tailnet),
  **mandatory** here - the operator has no equivalent of a fully-disabled security plugin. TLS is
  operator-generated (self-signed), and Vector/Dashboards authenticate with the same
  `opensearch-admin-credentials` Secret. Dashboards' own TLS to the *browser* is still disabled
  (`dashboards.tls.enable: false` in `cluster.yaml`) - Tailscale remains the access boundary for that leg.
- **Prometheus metrics**: the official `opensearch-project/opensearch-prometheus-exporter` plugin,
  installed declaratively via `cluster.yaml`'s `general.pluginsList` (version-matched exactly to this
  cluster's OpenSearch, 3.8.0.0 - updating that list triggers a rolling restart to install it). Exposes
  `/_prometheus/metrics` on the same port 9200 - the security plugin wraps that endpoint too, so
  `apps/opensearch/manifests/vmservicescrape.yaml` authenticates with the same
  `opensearch-admin-credentials` Secret, over HTTPS with `insecureSkipVerify` (self-signed cert, same as
  Vector). Dashboard: grafana.com ID 20827, built from the plugin's own mixin (the plugin was migrated
  to the `opensearch-project` org from an earlier Aiven-maintained fork - same metric naming lineage).

### Accessing OpenSearch Dashboards

Via Tailscale (see [Accessing things](../README.md#accessing-things) in the main README):
`https://opensearch.<tailnet>.ts.net`. Or port-forward:
```bash
kubectl -n opensearch port-forward svc/opensearch-dashboards 5601:5601
```
Visit `http://localhost:5601` - unlike Grafana, this does need a login: the `opensearch_admin_password`
you set in Vault, username `admin`. Create an index pattern (`logs-*`) on first visit to start browsing.

### Querying OpenSearch directly (optional)

```bash
kubectl -n opensearch port-forward svc/opensearch 9200:9200
```
```bash
curl -k -u admin:<opensearch_admin_password> "https://localhost:9200/logs-*/_search?q=error"
```

### Node Labels Reference

| Label | Nodes | Used by |
|---|---|---|
| `storage=true` | rpi-5-2, rpi-5-3 | Longhorn replica placement (physical data) |
| `pi5=true` | rpi-5-1..4 | OpenSearch (Amazon Linux images need a Pi 5 CPU) |

The former `telemetry=true` (VictoriaMetrics/VictoriaLogs) and `database=true` (Postgres) labels are gone -
those workloads are unpinned. Postgres's optional `local` storage mode pins to `rpi-5-1`/`rpi-5-4` by
hostname instead (`apps/postgres/cluster/components/local`), so no custom label is needed for it.

Labels are declared per-host in `host_vars/rpi-5-*.yaml` under the `k8s_labels` key, and applied to the live
cluster by the `k8s_labels` role (which reads every host's `k8s_labels` var and patches the matching
Kubernetes Node object — not tied to any single chart-deploying role). Labels are deliberately *not* driven
by group_vars, since this repo's `ansible.cfg` doesn't set `hash_behaviour = merge`, so a
group_vars-level `k8s_labels` would be silently replaced outright (not merged) by any host's own
`k8s_labels` in `host_vars/`, rather than combined with it.

## Logs, Also in VictoriaLogs

The same log stream OpenSearch receives is dual-shipped to VictoriaLogs too (`apps/victoria-logs/`,
chart `victoria-logs-single`, namespace `monitoring`) - re-added alongside OpenSearch rather than
replacing it again (this repo ran VictoriaLogs alone before OpenSearch existed, then OpenSearch alone
after - see git history on this directory). Not a migration path or a redundant backup: both are live,
both get every log line, and either can be used to cross-check the other.

- **Shipping**: the one Vector DaemonSet (`apps/opensearch/values-vector.yaml` - still that file, not a
  new one, since Vector is one shared chart release, not one per backend) gained two more sinks (`vlogs`,
  `vlogs_host`) alongside the existing `opensearch`/`opensearch_host` ones, same inputs, same data.
  VictoriaLogs has no native Vector sink in this cluster's pinned `vector:0.58.0-debian` (checked
  upstream's own `src/sinks` tree at that tag - no `victorialogs` directory exists), so these use the
  `elasticsearch` sink type pointed at VictoriaLogs' own Elastic-bulk-compatible endpoint plus its
  `VL-Time-Field`/`VL-Stream-Fields`/`VL-Msg-Field`/`AccountID`/`ProjectID` headers (its own documented
  integration method for exactly this case) - recovered verbatim from this repo's prior VictoriaLogs
  incarnation, not re-derived. No TLS, no auth, unlike the OpenSearch sinks - VictoriaLogs has no
  security-plugin equivalent and this chart runs with none by default.
- **Retention**: `7d`, matching OpenSearch's own `min_index_age` (see [Logging
  (OpenSearch)](#logging-opensearch) above) so both backends hold a comparable, honestly-equal window of
  the same dual-shipped data.
- **Placement**: unpinned, same as `vmsingle` - the PVC is a Longhorn volume, so the pod can run on any node.
- **Grafana datasource**: `victoriametrics-logs-datasource` (`apps/victoria-metrics/values.yaml`'s
  `grafana.plugins`) was explicitly removed when this app was removed the first time - restored now,
  alongside a `grafana-datasource-configmap.yaml` using the same sidecar-provisioning mechanism
  (`grafana_datasource: "1"` label) already used for the metrics datasource.
- **Unconfirmed**: the server's `512Mi` memory limit is carried over from this app's prior incarnation,
  not re-verified against today's actual (dual-shipped) log volume - worth a `kubectl top pod`/OOMKilled
  check after deploy, same as every other live-confirmed resize in this repo (e.g. `vmsingle`'s own).

**Troubleshooting:**
```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=victoria-logs-single
kubectl -n monitoring logs -l app.kubernetes.io/name=victoria-logs-single
```

## DNS (Blocky)

A single [Blocky](https://0xerr0r.github.io/blocky/) instance for the whole LAN — resolves DNS for any
client pointed at it, blocking ads/trackers and forwarding everything else upstream over
**DNS-over-TLS to Cloudflare**. Namespace: `blocky`. DHCP is out of scope — point clients at it manually or
via your router's DNS setting. **The chart install, config, NetworkPolicy, and metrics wiring all live in
the `apps/` directory** (`apps/blocky/`, see [GitOps (Argo CD)](#gitops-argo-cd)) — Argo CD reconciles them
continuously. Unlike every other app here, **this one needs nothing from Ansible at all**: Blocky has no
admin login, so its entire config is non-secret and lives as a plain git-managed manifest.

(Previously AdGuard Home + a separate `adguard-exporter` sidecar. Replaced because Blocky ships native
Prometheus metrics — no exporter needed — and its config is a single static YAML file with no setup wizard
and no self-rewriting state, which is a meaningfully simpler deployment than AdGuard's install-wizard/
ConfigMap-seeding dance. Config schema below was verified directly against
`ghcr.io/0xerr0r/blocky:v0.35.0` — a real `docker run` against a candidate config, not assumed from docs.)

- **Chart**: `bjw-s-labs/app-template` (the same generic "common" chart used for every non-vendor-chart app
  here) running the `ghcr.io/0xerr0r/blocky` image directly — one container, no sidecar.
- **Config**: `apps/blocky/manifests/configmap.yaml`, mounted **read-only** at `/app/config.yml`. No
  init-container seed-once workaround like AdGuard needed: Blocky is genuinely stateless and never
  rewrites its own config, so a plain read-only ConfigMap mount is all that's required.
- **Blocklist**: OISD (small) — same list AdGuard used, a low-false-positive list.
- **Cache backend**: Blocky's native `redis:` config (in `configmap.yaml`) points at `blocky-cache`'s
  Sentinel cluster for master discovery — see [Redis Clusters](#redis-clusters-blocky--searxng-caching)
  below. `required: false`, so a cache outage degrades to in-memory-only caching rather than blocking DNS
  resolution.
- **Storage**: none for Blocky itself — no mutable runtime config, no required local persistence. Its
  cache backend does have storage, see [Redis Clusters](#redis-clusters-blocky--searxng-caching) below.
- **Metrics**: native Prometheus endpoint at `/metrics` (port 4000), wired to `vmagent` via a
  `VMServiceScrape` (`apps/blocky/manifests/vmservicescrape.yaml`) — verified this actually gets scraped
  (`vmagent`'s `serviceScrapeSelector` is `selectAllByDefault: true` in this chart, confirmed against the
  real `victoria-metrics-k8s-stack` chart templates). Worth calling out: the old adguard-exporter never
  actually had this wiring despite the docs here previously claiming it was "scraped automatically" — no
  `VMServiceScrape`/`ServiceMonitor` for it ever existed, so it was never really being scraped. Not
  repeating that mistake for Blocky.
- **Services**: two dedicated `LoadBalancer` Services (via k3s's built-in ServiceLB, same mechanism as
  Traefik) — `blocky-dns` (53/tcp+udp, for LAN clients) and `blocky-http` (4000/tcp, metrics + the
  DNS-over-HTTPS endpoint — Blocky has no admin dashboard to expose, unlike AdGuard, but this is still
  reachable via the Tailscale Operator, see below, for checking `/metrics` remotely).
- **Egress NetworkPolicy** (`apps/blocky/manifests/networkpolicy.yaml`) — same shape as the AdGuard policy
  it replaces: DNS-over-TLS (853/tcp) locked to the exact Cloudflare upstream IPs, port 53 to CoreDNS only
  (blocklist hostname lookups), port 443 left broad (blocklist CDNs rotate IPs).

**Deploy/update**: nothing Ansible-side to run — edit `apps/blocky/manifests/configmap.yaml` (upstreams,
blocklists) directly and commit; Argo CD picks it up on its own.

**Point a client at it**: use either node's IP (ServiceLB exposes every node's own IP) or, once the
Tailscale Operator step below is done, `https://blocky.<tailnet>.ts.net` for `/metrics` — the DNS service
itself is only reachable via plain LAN IP:53, not through Tailscale.

## Search (SearXNG)

A single [SearXNG](https://docs.searxng.org/) metasearch instance — queries multiple search engines
(Google, Bing, DuckDuckGo, Wikipedia, and whatever else ships in its default engine set) and aggregates
results without tracking or profiling you. Namespace: `searxng`. **The chart install, config, and
NetworkPolicy all live in `apps/searxng/`** (see [GitOps (Argo CD)](#gitops-argo-cd)) — Argo CD reconciles
them continuously. **Tailscale-only** — unlike Blocky/AdGuard there's no LAN-wide LoadBalancer, since this
is a web UI, not a port every LAN client needs to hit directly (same pattern as Grafana/Longhorn/Argo CD).

- **Chart**: `bjw-s-labs/app-template`, running the official `docker.io/searxng/searxng` image directly —
  one container, no sidecar.
- **Engines**: ships with SearXNG's own defaults (`use_default_settings: true`) rather than a curated list
  — broad coverage, maintained upstream. Trim or add engines later by editing
  `roles/k8s_secrets/templates/searxng-config.yaml.j2`.
- **Config**: deliberately minimal, matching the vendor's own template settings.yml almost exactly —
  verified directly against `docker.io/searxng/searxng:2026.9.25-12f8b6515` (`docker run`, real startup
  logs, a real `200` from the homepage), not assumed from docs. `server.base_url` is left unset — this
  cluster's tailnet hostname isn't known to Ansible, and SearXNG auto-detects it from request headers
  instead, which is fine here.
- **Secret**: `server.secret_key` has no environment-variable equivalent — confirmed by reading the image's
  actual entrypoint script — so it has to live inside the seeded settings.yml, which is why (unlike Blocky)
  this one *does* need an entry in `group_vars/all/cluster_secrets.yaml` and a vault-encrypted
  `searxng_secret_key`.
- **Storage**: none for SearXNG itself — it stores no user data or query history server-side by design
  (that's the whole point of it), and its on-disk cache is fine to lose on restart. Its own redis/valkey
  cache does have storage, see [Redis Clusters](#redis-clusters-blocky--searxng-caching) below.
- **Rate-limiting / bot-protection**: configured via `valkey.url` in
  `roles/k8s_secrets/templates/searxng-config.yaml.j2`, pointing at `searxng-cache` — see
  [Redis Clusters](#redis-clusters-blocky--searxng-caching) below for the real caveat: SearXNG's client
  can't discover a new master after a failover, unlike Blocky's.
- **Metrics**: SearXNG does have a native OpenMetrics endpoint after all (confirmed directly against its
  source, `searx/settings.yml`/`searx/webapp.py` - an earlier version of this doc claimed otherwise and
  was wrong). `general.enable_metrics`/`general.open_metrics` (set via the same seeded `settings.yml`,
  `searxng_metrics_password`) expose `/metrics`, guarded by HTTP Basic Auth where **only the password is
  ever checked** - the username is never validated, so the `searxng-metrics-basic-auth` Secret's
  username is a fixed placeholder, not a real credential. No community Grafana dashboard exists for this
  (checked) - the metrics are scraped and queryable, just not pre-visualized. Its redis cache's own
  metrics *are* scraped too, and do have a dashboard — see below.
- **Egress NetworkPolicy** (`apps/searxng/manifests/networkpolicy.yaml`): port 443 stays broad by
  necessity — search engines have far too many arbitrary/rotating IPs to allowlist, unlike Blocky/AdGuard's
  fixed Cloudflare DoT IPs. Port 53 to CoreDNS resolves each engine's hostname.

**One-time**: create the secret key and metrics password in Vault before first deploy — fresh random
values are fine, there's nothing to remember about either:
```bash
openssl rand -hex 32
ansible-vault edit group_vars/all/main.yaml
```
Add:
```yaml
searxng_secret_key: "<paste a generated value>"
searxng_metrics_password: "<paste another generated value>"
```

**Seed/update the config:**
```bash
ansible-playbook site.yml -i inventory.dist -t secrets --ask-vault-pass
```

**Access it**: `https://search.<tailnet>.ts.net` once the Tailscale Operator step below has synced.

## Redis Clusters (Blocky + SearXNG Caching)

Two small, independent master+replica redis clusters — one backing Blocky's cache/blocking-state, one
backing SearXNG's rate-limiter — each with automatic failover via Sentinel. **Everything here lives in
`apps/redis-operator/`, `apps/blocky/manifests/`, and `apps/searxng/manifests/`** (see
[GitOps (Argo CD)](#gitops-argo-cd)) — Argo CD reconciles all of it continuously; nothing here needs
Ansible except SearXNG's `valkey.url` setting (part of its seeded `settings.yml`, see
[Search (SearXNG)](#search-searxng) above).

- **Operator**: [OT-Container-Kit redis-operator](https://github.com/OT-CONTAINER-KIT/redis-operator)
  (`apps/redis-operator/`), namespace `redis-operator`, watches every namespace for its `RedisReplication`
  and `RedisSentinel` CRDs. Chosen over a Bitnami-style Helm chart specifically to avoid depending on
  Bitnami's chart/image catalog, which has been moving free rolling updates behind a paid tier. Its own
  controller metrics (distinct from the redis_exporter sidecars below, which scrape the Redis clusters
  it manages, not the operator itself) are scraped via `apps/redis-operator-metrics/` - split into its
  own Application (same `VMServiceScrape`-needs-victoria-metrics'-CRD race Blocky's own sync-wave comment
  describes) rather than folded into `apps/redis-operator/` itself, since that app has to stay at wave 1
  for Blocky's/SearXNG's own redis clusters below to depend on. No dedicated Grafana dashboard exists for
  the controller's own metrics (checked) - the "Redis (Kubernetes mode)" dashboard below covers the
  managed clusters, not this.
- **Topology per cluster**: a `RedisReplication` (`clusterSize: 2` — one master, one replica, each with its
  own 512Mi Longhorn PVC) plus a separate `RedisSentinel` (`clusterSize: 3`, quorum 2-of-3 — a real
  majority, which 2 sentinels can't provide) monitoring it. Namespaces: `blocky-cache`, `searxng-cache` —
  deliberately **not** the `blocky`/`searxng` namespaces themselves, so those apps' existing egress-only
  `NetworkPolicy` (`podSelector: {}` — every pod in the namespace) doesn't accidentally clamp down the
  redis/sentinel pods' own intra-cluster traffic too.
- **Sizing**: `maxmemory 128mb` / `allkeys-lru` (set via `redisConfig.dynamicConfig` on the
  `RedisReplication`) — these are small caches, not a source of truth. Each redis container gets a 192Mi
  memory limit — `maxmemory` plus headroom for redis's own process overhead, client buffers and
  replication backlog, not `maxmemory` itself. Sized for the smaller of this cluster's two node classes
  (the 4B control-plane nodes are 4GB boards, not 8GB — see [Hardware Setup](#hardware-setup)).
- **Metrics**: a `redis_exporter` sidecar on every replication pod (port 9121), scraped by a `VMPodScrape`
  (not a `VMServiceScrape` like Blocky's own — the operator doesn't document a stable Service port *name*
  for the exporter, only the container port number) in each cache namespace.
- **How Blocky connects**: natively Sentinel-aware — its `redis.sentinelAddresses` (in
  `apps/blocky/manifests/configmap.yaml`) points at the round-robin `blocky-cache-sentinel-sentinel`
  Service, and `redis.address: blocky-cache` is the Sentinel master group name
  (`redisSentinelConfig.masterGroupName`). Always finds the current master, even after a failover.
- **How SearXNG connects**: its `valkey.url` only takes a single connection string, with no
  Sentinel-discovery support at the protocol level — but rather than pointing at a specific pod, it points
  at `searxng-cache`'s own operator-maintained **`searxng-cache-master`** Service
  (`searxng-cache-master.searxng-cache.svc.cluster.local`), confirmed live to be exactly what the
  `RedisReplication` CR itself recommends:
  `kubectl -n searxng-cache get redisreplication searxng-cache -o jsonpath='{.status.connectionInfo}'`. The
  redis-operator keeps this Service's endpoint pointed at whichever pod is actually master, so this *is*
  failover-aware despite the plain-URL limitation — SearXNG follows a failover automatically, same as
  Blocky, just via a different (non-Sentinel) mechanism.

**A real gotcha, confirmed live, worth remembering**: the operator appends its own `-sentinel` suffix to
whatever name a `RedisSentinel` CR is given — so a CR named `blocky-cache-sentinel` actually produces a
StatefulSet/Service named `blocky-cache-sentinel-sentinel` (`kubectl -n blocky-cache get svc` to check),
**not** `blocky-cache-sentinel`. This bit the very first deploy of this feature — Blocky logged
`sentinel: ... no such host` and silently ran with no cache until the address was corrected.

**Troubleshooting:**
```bash
# Cluster health
kubectl -n blocky-cache get pods,pvc,redisreplication,redissentinel
kubectl -n searxng-cache get pods,pvc,redisreplication,redissentinel

# Which pod is master right now
kubectl -n blocky-cache get redisreplication blocky-cache

# Actual Service names the operator created (don't assume - check)
kubectl -n blocky-cache get svc

# Confirm Blocky actually connected (look for "sentinel: new master=..." not "no such host")
kubectl -n blocky logs deployment/blocky | grep -i redis
```

Browse both caches in [WhoDB](#whodb) (pre-connected to each cluster's `-master` Service).

## Postgres (CloudNativePG)

A primary + streaming-replica Postgres cluster, managed by the [CloudNativePG](https://cloudnative-pg.io/)
operator (`apps/cloudnative-pg/`) rather than a hand-assembled Patroni+DCS setup - the operator itself is
the "control plane" that handles failover and primary/replica promotion, no separate component needed for
that. The actual cluster (`apps/postgres/`) is internal-only for now (no Tailscale Ingress, no external
exposure) - deliberately, applications are meant to reach it only through the two poolers below, never
directly.

- **Operator**: `apps/cloudnative-pg/`, namespace `cnpg-system`, official `cnpg/cloudnative-pg` chart.
  Installs the `Cluster`/`Pooler`/etc. CRDs `apps/postgres/` depends on. Exports its own controller metrics
  (port 8080) via a hand-written `VMPodScrape` - same reasoning throughout this section as
  [Redis Clusters](#redis-clusters-blocky--searxng-caching)'s own VM*Scrapes: CNPG's native `PodMonitor`
  toggle depends on the VM operator's unverified ServiceMonitor/PodMonitor converter, so this repo's proven
  hand-written mechanism is used instead. Also ships CloudNativePG's own official Grafana dashboard, wired
  straight into the existing Grafana sidecar (`grafana_dashboard: "1"` label) with no extra plumbing.
- **The `Cluster`** (`apps/postgres/cluster/`, a Kustomize dir), namespace `postgres`: `instances: 2`.
  `affinity.podAntiAffinityType: required` (topologyKey `kubernetes.io/hostname`) keeps each instance on a
  *different* node in either storage mode, satisfying "one Postgres instance per node" by construction. Where
  they run and what they store on is the one-line **storage mode** switch described next. CNPG elects one instance primary and streams WAL to the other as a replica, and
  automatically promotes the replica on primary failure - the operator's own job, nothing hand-rolled for
  it. Image: `ghcr.io/cloudnative-pg/postgresql:18.6` (current latest major, confirmed against the real
  registry, not assumed).
- **Storage mode** (`apps/postgres/cluster/kustomization.yaml`): pick exactly one component, one line:
  - `components/longhorn` (default) - volumes use a dedicated `longhorn-postgres` StorageClass (2 Longhorn
    replicas on `rpi-5-2`/`rpi-5-3`, `best-effort` data locality). The instances can run on **any** node and
    reschedule freely (still one per node). Costs: network-attached I/O instead of local disk, and 4 copies
    of the data on disk (2 Postgres instances x 2 Longhorn replicas) plus the replication traffic that
    implies. The StorageClass's `numberOfReplicas: "1"` halves that, but then both instances' volumes could
    land on the same storage node (Longhorn doesn't see CNPG's anti-affinity), so one storage-node loss could
    take the database - `"2"` is the safe default. StorageClass parameters are immutable; change one by
    creating a new class and migrating onto it.
  - `components/local` - volumes on k3s `local-path` (`WaitForFirstConsumer` bakes the node into each PV), and
    the instances pinned by hostname to `rpi-5-1` and `rpi-5-4`. Fastest, no Longhorn
    dependency, redundancy from Postgres replication alone - but the instances cannot move.
  - **Flipping the line does not move a running cluster.** CNPG never migrates an existing PVC to another
    StorageClass; the switch only decides how *new* instances are provisioned. See **Switching Postgres
    storage mode** below.
- **Switching Postgres storage mode** (e.g. `local` -> `longhorn`), with `kubectl cnpg` installed. The
  database stays up throughout (one instance at a time), but redundancy is reduced while a replacement
  instance is rebuilding:
  1. Flip the component line in `apps/postgres/cluster/kustomization.yaml`, commit, push, let Argo CD sync.
     Existing pods keep their old PVCs and stay where they are; CNPG may roll them once for the changed spec.
  2. Replace the **replica** first: find it (`kubectl cnpg status postgres -n postgres`), then delete its PVC
     and pod: `kubectl -n postgres delete pvc <replica> --wait=false && kubectl -n postgres delete pod
     <replica>`. CNPG recreates it as a new instance (next serial number) on the new StorageClass and
     rebuilds it from the primary. Wait until `kubectl cnpg status` shows it streaming and healthy.
  3. Switch over: `kubectl cnpg promote postgres <new-instance> -n postgres`. Confirm the apps are fine.
  4. Replace the old primary the same way as step 2 (delete its PVC and pod); wait for the rebuild.
  5. Done when both instances' PVCs show the new StorageClass: `kubectl -n postgres get pvc`.
  There is no WAL archive or backup (see below), so confirm both instances are healthy between steps.
- **The two Poolers** (`apps/postgres/manifests/pooler-{rw,ro}.yaml`): PgBouncer, fully managed by
  CloudNativePG's own `Pooler` CRD - config, auth (a dedicated `cnpg_pooler_pgbouncer` role + lookup
  function the operator creates itself), and TLS are all operator-managed, confirmed directly against
  CloudNativePG's docs, not hand-rolled. `postgres-pooler-rw` always routes to the current primary via
  CNPG's own `postgres-rw` Service; `postgres-pooler-ro` routes to replicas via `postgres-ro` - both
  Services are kept correct by the operator across a failover, so nothing in this repo tracks "which pod is
  primary" itself. `instances: 1` on each pooler (not pinned - PgBouncer holds no
  data of its own, so it can run anywhere). Native Prometheus metrics on port 9127 per pod, no separate
  exporter needed (unlike ProxySQL, which was considered and dropped - see below).
- **Enforcing "apps talk to the pool, never the databases directly"**: at the network layer, not just
  convention. Two separate NetworkPolicies (`apps/postgres/manifests/networkpolicy.yaml`) - one locks the
  actual Postgres pods down to ingress only from the two poolers, the `cnpg-system` operator, and
  `monitoring`'s vmagent; the other is egress-only on the poolers themselves (same shape as every other
  app's NetworkPolicy in this repo), leaving their own ingress open since their whole purpose is being
  reachable from wherever a future application ends up living.
- **Users/permissions**: CloudNativePG's declarative `DatabaseRole` and `Database` CRDs (not the older,
  inline `Cluster.spec.managed.roles` form) create and own individual roles and databases from git, each
  reconciled independently of the `Cluster` object itself. First real user: Temporal's own `temporal` role
  and its two databases - see [Temporal](#temporal) below,
  `apps/postgres/manifests/temporal-database.yaml`. These CRDs cover role *attributes* (login, password via
  a Secret reference) and database ownership declaratively. They do **not** cover GRANT-level permissions on
  specific schemas/tables beyond ownership - that stays each application's own concern (init SQL,
  migrations), same as most Postgres operators.
- **Why not ProxySQL**: considered first, and its native Postgres protocol support is real and reasonably
  mature (confirmed against ProxySQL's own docs). Dropped in favor of PgBouncer via CNPG's `Pooler` CRD for
  two concrete reasons: ProxySQL's `pgsql_servers` backend registration isn't config-file-driven the way its
  MySQL equivalent is - it requires SQL `INSERT` statements against its admin interface at runtime, which
  would have needed a hand-written sidecar to seed and periodically re-assert (ProxySQL was going to run
  with no PVC, so that state doesn't survive a restart on its own); and no maintained, ready-to-run
  Prometheus exporter image exists for it (`percona/proxysql_exporter`'s only distribution is
  build-from-source, no published container image at all) - a real, honest gap this repo would otherwise
  have had to either accept or take on a custom image build pipeline to close. CNPG's `Pooler` avoids both
  problems entirely: fully operator-managed config/auth, and metrics built in with no exporter needed.
- **No backups configured**: deliberate, for now. Durability comes only from Postgres streaming replication
  across the two instances - no point-in-time recovery, and losing both at once loses everything. Revisit with CloudNativePG's Barman Cloud plugin (`cnpg/plugin-barman-cloud`) if/when
  object storage exists in this cluster.

**Troubleshooting:**
```bash
# Cluster + pooler health
kubectl -n postgres get cluster,pooler,pods

# Which pod is currently primary
kubectl -n postgres get cluster postgres -o jsonpath='{.status.currentPrimary}'

# CNPG's own view of the cluster
kubectl -n postgres cnpg status postgres   # requires the kubectl-cnpg plugin

# Poolers actually reachable
kubectl -n postgres get svc postgres-pooler-rw postgres-pooler-ro
```

## Temporal

[Temporal](https://temporal.io/) workflow orchestration, deployed via the official `temporal/temporal` Helm
chart (`apps/temporal/`, chart repo `https://go.temporal.io/helm-charts`) with its bundled Cassandra/Elasticsearch/
Postgres subcharts all disabled - it connects to the existing [Postgres cluster](#postgres-cloudnativepg)
through `postgres-pooler-rw` instead of running its own datastore, the same "apps talk to the pool, never a
database directly" pattern as everything else in this repo.

- **Database/role**: `apps/postgres/manifests/temporal-database.yaml` creates a CNPG `DatabaseRole` named
  `temporal` (password from the `temporal-db-credentials` Secret) and two CNPG `Database` resources it owns -
  `temporal` and `temporal_visibility` - reconciled by the CloudNativePG operator against the `postgres`
  `Cluster`, not hand-run SQL. See [Users/permissions](#postgres-cloudnativepg) above.
- **Persistence**: both the `default` (workflow history/state) and `visibility` (search/list-workflows)
  stores point at the same Postgres cluster via `postgres-pooler-rw.postgres.svc.cluster.local:5432`, using
  the `postgres12_pgx` SQL driver - standard/SQL-backed visibility, not Elasticsearch, so there's no separate
  search cluster to run or keep in sync. Since this reuses the existing poolers, Temporal adds no new
  connection-pooling component of its own.
- **`numHistoryShards: 4`**: a one-way door - this value is baked into the schema on first deploy and cannot
  be changed later without standing up a new cluster. Set low deliberately for a homelab's workflow volume;
  revisit only via a rebuild if that ever changes.
- **Web UI**: `web.enabled: true`, exposed via the Tailscale Operator like every other UI in this repo - see
  [Exposing UIs via Tailscale Operator](#exposing-uis-via-tailscale-operator) and the Accessing Things table
  in the main README. The frontend gRPC API itself (`temporal-frontend:7233`) is left reachable
  cluster-internally with no additional restriction, the same way the Postgres poolers are, since it's meant
  to be a general access point for future application workloads.
- **Metrics**: all four server components (frontend/history/matching/worker) export native Prometheus
  metrics on port 9090 - scraped via a hand-written `VMPodScrape`
  (`apps/temporal/manifests/vmpodscrape.yaml`), same reasoning as [Postgres](#postgres-cloudnativepg) and
  [Redis Clusters](#redis-clusters-blocky--searxng-caching): the native chart toggle depends on the VM
  operator's unverified ServiceMonitor/PodMonitor converter. The Web UI component exposes no metrics port
  and isn't scraped.
- **Sync-wave**: `argocd.argoproj.io/sync-wave: "3"` - strictly after `cloudnative-pg` (wave 1) and
  `postgres` (wave 2), so the operator and the `temporal` role/databases exist before Temporal's Helm-hook
  schema-setup Job tries to run against them. Like the original Postgres init, a first-attempt failure here
  (databases not fully reconciled yet) self-heals via Argo CD's automated retry, not a wait-for step in this
  repo.

**Prerequisite**: `temporal_db_password` must be set in Vault (`ansible-vault edit group_vars/all/main.yaml`)
before this deploys successfully - see [Secrets & Variables](#secrets--variables).

**Troubleshooting:**
```bash
# Server + web pods
kubectl -n temporal get pods

# Schema-setup Job logs (first deploy only)
kubectl -n temporal logs job/temporal-schema-setup

# Confirm the role/databases actually reconciled
kubectl -n postgres get databaserole,database
```

## Home Dashboard (Homepage)

[Homepage](https://gethomepage.dev/) (`gethomepage/homepage`), a landing page linking out to every other UI in
this repo, deployed via the same `bjw-s-labs/app-template` chart as Blocky/SearXNG/WhoDB - Homepage
ships no official Helm chart of its own, only Docker instructions.

- **Config**: `configMaps.config` in `apps/homepage/values.yaml` - `settings.yaml`, `bookmarks.yaml`, `widgets.yaml`
  (unused, empty), and `services.yaml` (one entry per `Ingress` in
  `apps/tailscale-operator/manifests/ingresses.yaml`, grouped by what the service does). Entirely
  git-managed and portable, like Blocky's config - no credentials, and the one per-cluster value it needs
  (this tailnet's hostname) is a runtime placeholder, not baked in at commit time - see below.
- **Tailnet hostname**: `services.yaml`'s links use `{{HOMEPAGE_VAR_TAILNET_DOMAIN}}`, Homepage's own
  runtime env-var substitution syntax (any `HOMEPAGE_VAR_*` env var is replaced by literal string match
  across every config file before it's parsed as YAML). The actual value, plus the separate
  `HOMEPAGE_ALLOWED_HOSTS` env var Homepage requires for any non-`localhost` access (both derived from
  `tailnet_domain`), come from the `homepage-env` ConfigMap - one more entry in the generic `k8s_secrets`
  bridge (`group_vars/all/cluster_secrets.yaml`), wired in via `apps/homepage/values.yaml`'s `envFrom`. Not
  a credential like this bridge's other entries, but still kept out of `apps/` for the same reason
  `tailnet_domain` is kept out of it everywhere else in this repo.
- **Icons**: all `mdi-` (Material Design Icons bundled in the Homepage image itself), not the slug-based
  icons Homepage can otherwise fetch from an external CDN - keeps `apps/homepage/manifests/networkpolicy.yaml`
  from needing broad egress just to draw them. That NetworkPolicy does still allow broad `443/tcp` for one
  other reason: Homepage's own built-in update-check API route
  (`https://api.github.com/repos/gethomepage/homepage/releases`), hit server-side on every page load.
- **Access**: `https://home.<tailnet>.ts.net` - see [Exposing UIs via Tailscale
  Operator](#exposing-uis-via-tailscale-operator) below. To add a newly-exposed service to the dashboard,
  add an entry to `services.yaml` in `apps/homepage/values.yaml` and commit - no Ansible run needed, same
  as adding the `Ingress` itself. Homepage restarts itself on any change here: the chart hashes the
  ConfigMap into a pod annotation (Homepage's config is `subPath`-mounted, which Kubernetes never refreshes
  in a running pod). In `services.yaml`, write the tailnet hostname as `{{ $d }}` (defined at the top of that
  file) - the chart's own templating would choke on the literal `{{HOMEPAGE_VAR_TAILNET_DOMAIN}}`.

## Node Rebalancing (descheduler)

The kube-scheduler only ever places a pod once, at creation - it never moves a running pod to rebalance
load across nodes. Confirmed live the gap this left: right after `rpi-5-4` joined, it sat at 19%
memory/12 pods while `rpi-5-2` was at 69% memory/22 pods, with no mechanism to ever reconsider that.
[kubernetes-sigs/descheduler](https://github.com/kubernetes-sigs/descheduler) (`apps/descheduler/`,
SIG Scheduling's own project, no vendor chart) is what actually moves already-running pods.

- **Mode**: `kind: CronJob`, every 30 minutes - runs, evicts whatever the policy below flags, then exits.
  Picked over the chart's `Deployment` mode (a long-lived pod doing the same thing via its own internal
  `--descheduling-interval`) for no benefit on a 7-node homelab.
- **Policy** (`apps/descheduler/values.yaml`'s `deschedulerPolicy`): `LowNodeUtilization` - a node under
  30% cpu/memory/pods is a valid eviction target, a node over 60% on any of those is a source to evict
  from. Thresholds picked against this cluster's own real numbers (the 69%/19% split above).
- **Safety**: `DefaultEvictor`'s `nodeFit: true` simulates whether an evicted pod could actually be
  rescheduled (nodeSelector, taints, resource requests) before evicting it - protects e.g. Longhorn's
  `storage=true` pin or OpenSearch's `pi5=true` one. The `postgres` namespace is excluded outright via
  `evictableNamespaces` regardless of storage mode: in `local` mode an evicted instance could only restart on
  the same node (PV node affinity + the hostname pin), and in `longhorn` mode evicting a
  primary/replica for rebalancing is still a needless disruption to a stateful pair. `kube-system` is excluded too - standard "don't let a descheduler touch core cluster
  services" default.

**Troubleshooting:**
```bash
# Did the last run evict anything
kubectl -n descheduler get jobs
kubectl -n descheduler logs job/<latest-job-name>

# Current pod distribution per node
kubectl get pods -A -o custom-columns='NODE:.spec.nodeName' --no-headers | sort | uniq -c | sort -rn
```

## Vulnerability Scanning (Trivy Operator)

Continuous vulnerability/misconfiguration scanning for every workload already running in the cluster
([aquasecurity/trivy-operator](https://github.com/aquasecurity/trivy-operator), `apps/trivy-operator/`,
namespace `trivy-system`). Watches Pods cluster-wide and runs a Trivy scan Job against each distinct
image, publishing results as CRDs rather than needing a UI of its own.

- **What it scans**: vulnerabilities (`VulnerabilityReport`), misconfigurations (`ConfigAuditReport`),
  exposed secrets (`ExposedSecretReport`), and RBAC over-permissiveness (`RbacAssessmentReport`) - all
  three scanner toggles left on.
- **Concurrency**: `scanJobsConcurrentLimit: 2`, down from the chart's default of 10 - each concurrent
  scan Job gets its own CPU/memory footprint, and 10 at once on a mix of 4GB/8GB Pi boards would compete
  hard with every other workload here. Costs a slower first full pass across every image already running.
- **No NetworkPolicy**: same reasoning as `cnpg-system`/`redis-operator`, the two other pure-operator
  namespaces in this repo - scan Jobs pull each image's own registry plus the vulnerability DB from
  `mirror.gcr.io`, not a fixed IP set worth allowlisting.
- **CRDs**: bundled in the chart (same large-annotation issue as Longhorn's/CNPG's own), hence
  `ServerSideApply=true` on the Application.
- **Sync-wave 2, not 1**: `apps/trivy-operator/manifests/vmservicescrape.yaml` needs victoria-metrics'
  own CRD (wave 1) to exist first - same race class Blocky's own sync-wave comment describes; nothing
  else depends on trivy-operator's own CRDs at any particular wave, so bumping this app's wave (unlike
  redis-operator's, see [Redis Clusters](#redis-clusters-blocky--searxng-caching) above) was the simpler
  fix, no split-app needed.
- **Prometheus metrics**: `metricsFindingsEnabled` (chart default `true`) plus `metricsVulnIdEnabled`/
  `metricsExposedSecretInfo`/`metricsConfigAuditInfo`/`metricsRbacAssessmentInfo` (chart default `false`,
  turned on here - each adds real cardinality per upstream's own warning, revisit if vmsingle's memory
  ever gets tight again). Dashboard: grafana.com ID 22010, which explicitly requires
  `metricsVulnIdEnabled: true` - confirmed this cluster's config satisfies that.
- **Resources**: the controller's own `resources.limits.memory` is `512Mi`, not the original `256Mi` -
  confirmed live, OOMKilled (`exitCode: 137`) repeatedly on first deploy. Reconciling against every pod
  already running in this ~150-pod cluster on first start is a bigger initial spike than steady-state.

**Troubleshooting:**
```bash
# Reports across the whole cluster
kubectl get vulnerabilityreports,configauditreports,exposedsecretreports -A

# A specific image's findings
kubectl get vulnerabilityreport -n <namespace> -l trivy-operator.resource.name=<deployment-name> -o yaml
```

## Open WebUI

A self-hosted chat UI for LLMs ([open-webui/open-webui](https://github.com/open-webui/open-webui),
`apps/open-webui/`, namespace `open-webui`). Deliberately deployed with **no LLM backend configured** -
no Ollama, no OpenAI/Anthropic API key, nothing baked into git. Which provider to use is a runtime
choice made through Open WebUI's own Settings UI once it's running (it adds OpenAI-compatible endpoints
directly, no redeploy needed) - not something this repo should decide on your behalf.

- **Chart**: the official `open-webui/open-webui` chart (`helm.openwebui.com`) - unlike Homepage/SearXNG/
  WhoDB, this project does publish and maintain its own chart, so no `bjw-s-labs/app-template`
  fallback was needed. Its `image.tag` is pinned explicitly (`v0.11.4`, the actual latest tagged GitHub
  release) rather than trusting the chart's own default, which resolves to its `appVersion` - literally
  `dev`, since this chart has no separate stable release line.
- **Bundled subcharts off**: `ollama.enabled`/`pipelines.enabled` both default `true` in this chart (they
  auto-install a local Ollama and a plugin middleware) - turned off here to match the no-backend scope
  above. `websocket.manager` left as the in-memory default (`redis.enabled: false`) - only needed for
  multi-replica websocket fan-out, and this is a single replica.
- **Database**: `DATABASE_URL` points at the cluster's existing CloudNativePG Postgres, through
  `postgres-pooler-rw` - same "apps talk to the pool, never the database directly" pattern as Temporal
  (`apps/postgres/manifests/open-webui-database.yaml`, a `DatabaseRole`/`Database` pair). Moves
  chats/users/settings off local SQLite onto the HA, replicated cluster. Does **not** remove the need for
  the PVC below - file uploads (`STORAGE_PROVIDER`) and RAG vector embeddings (`VECTOR_DB`) are separate
  env vars, both still local/default, confirmed against Open WebUI's own docs. Switching didn't migrate
  whatever was already in the old `webui.db` - deliberate, given how little was in it at the time.
- **Persistence**: a 2Gi Longhorn PVC - file uploads and RAG vector embeddings now (chats/users/settings
  moved to Postgres, above) - unlike Homepage (stateless) or SearXNG (deliberately no PVC), this app
  still genuinely has state to keep across restarts.
- **`WEBUI_SECRET_KEY`**: signs session cookies - not an LLM-backend credential, same category as
  Homepage's own `HOMEPAGE_ALLOWED_HOSTS` was (required for the app to run at all, not a provider API
  key). Wired via `extraEnvVars` + a pre-created Secret, seeded by the `k8s_secrets` bridge with a new
  `openwebui_secret_key` Vault variable - see [Secrets & Variables](#secrets--variables).
- **Egress NetworkPolicy**: DNS + Postgres (`postgres-pooler-rw`, port 5432) - couldn't fully confirm or
  rule out a startup update-check call in the time available, so this otherwise stays conservative rather
  than guessing a broad `443` rule it might not need. Whichever LLM backend gets configured later (an
  external API, or an in-cluster Ollama) will need its own egress rule added at that point regardless.

**One-time**: create the session-signing key and database password in Vault before first deploy:
```bash
openssl rand -hex 32
ansible-vault edit group_vars/all/main.yaml
```
Add:
```yaml
openwebui_secret_key: "<paste a generated value>"
openwebui_db_password: "<paste another generated value>"
```

**Access it**: `https://chat.<tailnet>.ts.net` once the Tailscale Operator step below has synced.

## WhoDB

A single web UI (`apps/whodb/`, namespace `whodb`) for the cluster's Postgres, OpenSearch and Redis -
replaces the former pgAdmin and RedisInsight apps. Runs the official `clidey/whodb` image via the
`bjw-s-labs/app-template` chart (no Helm chart worth depending on).

- **Pre-registered connections**: WhoDB login profiles, set via `WHODB_<TYPE>` env vars (JSON arrays; format
  confirmed against `core/src/envconfig` in clidey/whodb).
  - **Postgres** (`WHODB_POSTGRES`): one profile per database (`postgres`, `grafana`, `open_webui`,
    `temporal`, `temporal_visibility`) via `postgres-pooler-ro`, as the read-only `whodb` role
    (`apps/postgres/manifests/whodb-role.yaml`, member of `pg_read_all_data`). For writes use
    `kubectl -n postgres exec -it postgres-1 -c postgres -- psql -U postgres`.
  - **OpenSearch** (`WHODB_OPENSEARCH`): `opensearch.opensearch:9200` as `admin` (the cluster requires TLS +
    auth), `SSL Mode: insecure` since the operator's cert is self-signed. This is the admin login, so
    WhoDB can write to OpenSearch.
  - **Redis** (`WHODB_REDIS`, plain env in `values.yaml` - no auth): `blocky-cache` and `searxng-cache`, via
    each cluster's operator-maintained `-master` Service (failover-aware).
  - Postgres and OpenSearch profiles carry passwords, so they're in the `whodb-env` Secret, built from
    `whodb_postgres_profiles` / `whodb_opensearch_profiles` in `group_vars/all/cluster_secrets.yaml` and
    seeded by `k8s_secrets`. The Postgres password is the existing Vault variable `pgadmin_db_password`
    (name kept from the pgAdmin days).
- **WhoDB's own login**: none beyond picking a profile - the tailnet is the access control.
- **Redis caching**: WhoDB does not use Redis itself. Its only state is an encrypted session store
  (`/data`, 256Mi Longhorn PVC); there is no cache-backend setting.
- **Egress NetworkPolicy**: DNS, 5432 to `postgres`, 9200 to `opensearch`, 6379 to `blocky-cache` /
  `searxng-cache`.

**Access it**: `https://whodb.<tailnet>.ts.net`.

**Migration note**: the old `pgadmin` DatabaseRole is replaced by `whodb`; the stale `pgadmin` Postgres role
may linger - drop it with `DROP ROLE pgadmin;` as `postgres`. The old `pgadmin-db-credentials` Secret in the
`postgres` namespace can be deleted too.

## LiteLLM

An OpenAI-compatible gateway in front of LLM providers (`apps/litellm/`, namespace `litellm`): one endpoint,
virtual API keys, per-key/team spend tracking, an admin UI. Deployed from BerriAI's official Helm chart, which
is published only as an OCI artifact (`ghcr.io/berriai/litellm-helm`) - so `roles/argocd` registers that
registry with `enableOCI` and the AppProject allows it. Chart version = LiteLLM version (default image tag is
the chart's `appVersion`); re-pin deliberately.

- **Database**: the cluster's CloudNativePG Postgres through `postgres-pooler-rw`, database/role `litellm`
  (`apps/postgres/manifests/litellm-database.yaml`) - the chart's bundled Postgres is off. The chart's PreSync
  migration Job runs the Prisma schema push as that role.
- **Cache**: `litellm-cache`, its own Redis replication + Sentinel (`apps/litellm/manifests/redis-*.yaml`,
  namespace `litellm-cache`), same shape as the Blocky/SearXNG ones. Used for response caching
  (`cache_params`, 10 min TTL) and router state (`router_settings.redis_*`). LiteLLM connects to the
  operator-maintained `litellm-cache-master` Service - failover-aware, no Sentinel client needed.
- **Metrics**: `callbacks: ["prometheus"]` (request/token/spend/latency/failure counters per model, key, team)
  plus `service_callback: ["prometheus_system"]` (Redis/Postgres latency), at `/metrics` on :4000. `/metrics`
  needs an API key by default, so the `VMServiceScrape` (`apps/litellm/manifests/vmservicescrape.yaml`) sends
  the master key as a bearer token. The Redis exporter sidecars are scraped by a `VMPodScrape` like the other
  caches.
- **Models** (`apps/litellm/values.yaml`, `proxy_config.model_list`): wildcards `anthropic/*` and `openai/*`
  (anything the provider offers, no edits needed) plus aliases `claude-sonnet`, `claude-opus`, `claude-haiku`.
  `store_model_in_db: true` also lets you add models and keys in the UI (stored encrypted in Postgres).
- **Secrets** (Vault, seeded by `k8s_secrets` -> `make deploy-secrets`): `litellm_master_key` (admin key / UI
  login, must start with `sk-`), `litellm_salt_key` (encrypts DB-stored provider credentials; **never change it
  once set**), `litellm_db_password`, and optionally `anthropic_api_key` / `openai_api_key`. Provider keys are
  read at process start: after adding one, re-seed and `kubectl -n litellm rollout restart deploy/litellm`.
- **Egress NetworkPolicy**: DNS, 5432 to `postgres`, 6379 to `litellm-cache`, and 443 to anywhere outside the
  private ranges (provider APIs).

**First-time order**: add the Vault vars -> `make deploy-secrets` -> `make deploy-argocd` (registers the OCI
registry, allows the namespaces) -> push. **Use it**: sign in to `/ui` with the master key (username `admin`),
create a virtual key, then point clients (e.g. Open WebUI's OpenAI connection) at
`http://litellm.litellm.svc.cluster.local:4000/v1` or `https://litellm.<tailnet>.ts.net/v1`.

**Open WebUI** uses LiteLLM as its only LLM backend (`OPENAI_API_BASE_URL` / `OPENAI_API_KEY` in
`apps/open-webui/values.yaml`, in-cluster URL, plus an egress rule). Its key is a *virtual key*, not the master
key: generate a value (`sk-` + `openssl rand -hex 24`), store it in Vault as `openwebui_litellm_key`, and create
a key with that exact value in the LiteLLM UI (Virtual Keys -> Create, "Key" field, alias `open-webui`, models
`claude-sonnet`/`claude-opus`/`claude-haiku`). Then `make deploy-secrets` and restart Open WebUI. Those env vars
only seed Open WebUI's connection on first start; afterwards edit it in Admin Settings -> Connections.

**Access it**: `https://litellm.<tailnet>.ts.net/ui`.

## GO Feature Flag

[GO Feature Flag](https://github.com/thomaspoignant/go-feature-flag) relay proxy (`apps/go-feature-flag/`, namespace
`go-feature-flag`): an HTTP API that evaluates feature flags, so other services ask it instead of embedding flag logic.
Image `gofeatureflag/go-feature-flag:v1.56.0` (ARM64), run through the generic `bjw-s-labs/app-template` chart rather
than the official `relay-proxy` chart: that chart builds its config from a ConfigMap, but this config embeds the
database password and API keys, so it is rendered by Ansible into a Secret and mounted instead
(`roles/k8s_secrets/templates/go-feature-flag-config.yaml.j2`). Env-var overrides for flag sets/retrievers are undocumented,
so the chart can't carry the secrets any other way.

- **Storage**: Postgres. Database `go_feature_flag`, role `goff` (`apps/postgres/manifests/go-feature-flag-database.yaml`),
  reached through `postgres-pooler-rw`. Flags are rows in the `go_feature_flag` table (`flag_name`, `flagset`, `config`
  JSONB). The relay proxy reads but doesn't create the table, so a PreSync Job (`manifests/schema-job.yaml`) creates it
  (idempotent). The relay proxy polls every 10 s, so an edited row is live within that long;
  `POST /admin/v1/retriever/refresh` (admin key) forces an immediate re-poll.
- **No Redis**: GO Feature Flag has no cache feature (Redis is only supported as a flag-storage *retriever*), and flags are
  in Postgres, so a Redis cache would have nothing to attach to. None is provisioned.
- **Availability**: 2 replicas on different nodes with a PDB (a tiny Go service others will depend on); updates start the
  new pod first. Flip `replicas` to 1 in `values.yaml` if memory ever matters more.
- **Logs**: nothing to configure. The relay proxy logs JSON to stdout (`logFormat: json`), and Vector tails every pod, so it
  lands in both OpenSearch and VictoriaLogs like everything else. Evaluation events are also emitted as log lines (the `log`
  exporter is on by default).
- **Metrics**: Prometheus `/metrics` on the monitoring port (1032), scraped by a `VMServiceScrape`
  (`manifests/vmservicescrape.yaml`). No API key needed on that port.
- **Egress NetworkPolicy**: DNS and Postgres (5432) only.

**Secrets** (Vault variables in `group_vars/all/main.yaml`, seeded by `k8s_secrets` via `make deploy-secrets`):
| Variable | Used for |
|---|---|
| `goff_db_password` | the `goff` Postgres role (also the writable WhoDB connection) |
| `goff_admin_api_key` | `X-API-Key` for `/admin/v1/*` (retriever refresh) |
| `goff_evaluation_api_key` | `X-API-Key` that consumers send to evaluate flags in flag set `main` |

Generate each with `openssl rand -hex 32`.

**Using it from another service** (none exist yet). In-cluster, no hostname or TLS needed:
`http://go-feature-flag.go-feature-flag.svc.cluster.local:1031`. Ingress to the namespace is open (the cluster's
NetworkPolicies are egress-only); the API key is the gate, and the consuming namespace's own egress policy has to allow
port 1031 to `go-feature-flag`. Evaluate a flag:
```bash
curl -s -X POST http://go-feature-flag.go-feature-flag.svc.cluster.local:1031/v1/feature/new-checkout/eval \
  -H "X-API-Key: <goff_evaluation_api_key>" -H 'Content-Type: application/json' \
  -d '{"evaluationContext":{"key":"user-1"},"defaultValue":false}'
```
The API also speaks [OFREP](https://openfeature.dev/specification/appendix-c) (`/ofrep/v1/evaluate/flags`) for OpenFeature
clients. A service that needs its own isolated flags gets its own flag set (and key) added in the config template.

**Authoring flags.** In this release (v1.56.0) the relay proxy has **no flag create/update/delete API** (the PR adding one is
still unmerged), and the "UI" is Swagger - an evaluation console only. Flags are edited as rows in Postgres. WhoDB has a
writable **`go_feature_flag (writable)`** connection (the `goff` role through the primary): open the `go_feature_flag`
table and add or edit rows, with `flagset` = `main` and `config` = the flag's JSON. Or with SQL:
```sql
INSERT INTO go_feature_flag (flag_name, flagset, config) VALUES
  ('new-checkout', 'main', '{"variations":{"on":true,"off":false},"defaultRule":{"variation":"off"}}');
```
`config` is the flag object from GO Feature Flag's [flag format](https://gofeatureflag.org/docs/configure_flag/flag_format)
(variations, targeting, defaultRule, ...). Test a flag in the Swagger UI, then check it in the metrics.

**Access**: `https://flags.<tailnet>.ts.net/swagger/index.html` (Swagger / evaluation console; also on Homepage). The whole API
is on the tailnet at `https://flags.<tailnet>.ts.net`.

**First-time order**: add the three Vault variables -> `make deploy-secrets` -> `make deploy-argocd` (allows the new
namespace in the Argo CD project) -> push. The Argo CD app then creates the table and starts the relay proxy.

## Snowflake (Tor)

A [Tor Snowflake](https://snowflake.torproject.org) proxy (`apps/snowflake/`, namespace `snowflake`) that lends a little
bandwidth to censored Tor users. Image `thetorproject/snowflake-proxy:v2.14.1` (ARM64) via `app-template`.

- **Not a relay or exit node.** It only forwards a user's WebRTC connection to the Tor project's own Snowflake bridge; no
  user traffic exits from here and it never appears in the relay consensus.
- **No inbound ports.** WebRTC NAT traversal is outbound-only, so nothing is forwarded on the router. (A classic obfs4
  bridge was rejected for exactly that reason - it needs an open port.)
- **Bandwidth is a soft bound**: the proxy has no rate flag, only `-capacity` (4 concurrent clients per pod, 2 pods).
  Flannel doesn't honour `kubernetes.io/*-bandwidth` annotations, so there is no hard 5 Mb/s shaper; watch the metrics
  and lower `-capacity` in `apps/snowflake/values.yaml` if it uses more than you want.
- **Egress-only NetworkPolicy**: DNS + the public internet, with RFC1918, CGNAT/Tailscale and link-local ranges excluded
  so it can't be used to reach the LAN, cluster or tailnet.
- **Metrics**: `/internal/metrics` on port 9999, scraped by a `VMServiceScrape` (connections, bytes in/out, by country).
- 2 replicas (soft anti-affinity) + PDB; no state, no secrets, no Vault vars.

## Availability and node maintenance

**Goal**: mirror a managed cloud cluster. Any *one* node can be drained and rebooted with a plain
`kubectl drain --ignore-daemonsets --delete-emptydir-data <node>` and nothing user-visible drops. The cluster
does **not** have the spare capacity for more than one node out at a time, so the model assumes exactly one.
(See [Node Maintenance](#node-maintenance) for the procedure.)

**Rules the definitions follow** (apply them to anything new):
- Anything on a request path that is stateless (or whose state is in Postgres/Redis) runs **2 replicas**, with
  *required* pod anti-affinity on `kubernetes.io/hostname` and a **PodDisruptionBudget** (`maxUnavailable: 1`), so
  a drain evicts one, waits for its replacement to be Ready, then continues. It needs a real **readiness probe**:
  without one the replacement receives traffic before it can answer.
- Stateful single-instance apps on an RWO volume can't run 2 replicas; they take a short blip while the pod and
  its Longhorn volume move.
- No `nodeSelector` unless the workload can't run elsewhere (OpenSearch: `pi5=true`). Volumes are Longhorn, so
  pods are free to move; only Longhorn's *replica data* is pinned (`storage=true`: `rpi-5-2`, `rpi-5-3`).
- No special-casing in maintenance tooling: whether a drain is safe is decided by the resources' own budgets.

**What happens when one node is drained** (config in parentheses):
| Component | Behaviour |
|---|---|
| Postgres primary | Evicted (no PDB: `enablePDB: false`); CNPG promotes the replica and re-creates the old primary on another node. `smartShutdownTimeout: 10` so the primary shuts down fast and the failover isn't delayed by the 180s default |
| Postgres replica | Evicted and rescheduled elsewhere (required anti-affinity keeps it off the primary's node); its Longhorn volume follows |
| CNPG operator | 2 replicas, leader-elected - the standby can promote even if the active one was on the drained node |
| PgBouncer poolers (rw, ro) | 2 each on different nodes + PDB |
| Longhorn | `nodeDrainPolicy: block-if-contains-last-replica`: a node can be drained while every volume has a second healthy replica; Longhorn refuses a second concurrent node. CSI controllers run 2 replicas |
| Blocky (LAN DNS) | 1 replica: a drain reschedules it, ~10-30s gap in which LAN DNS is down (accepted; flip to 2 replicas with anti-affinity + a PDB to remove it). Updates start the new pod first (`RollingUpdate`, surge 1) and it is readiness-gated |
| Tailscale ingress proxies | 2, required anti-affinity + PDB |
| Redis caches (3 clusters) | master/replica and the 3 sentinels each on different nodes, PDB `maxUnavailable: 1` (keeps sentinel quorum) |
| GO Feature Flag relay proxy | 2 replicas on different nodes + PDB + readiness probe; rolling update starts the new pod first |
| LiteLLM, Grafana, Homepage | 1 replica each (stateless - state is in Postgres/Redis); a drain reschedules them, gaps of roughly 1-2 min, 30-90s and 10-30s (Pi start-up, plus an image pull on a node that hasn't run them) |

**Accepted blips** (single replica by design; recover when the pod reschedules, typically under a minute or two):
Blocky, LiteLLM, Grafana and Homepage, Open WebUI and WhoDB (RWO volume), SearXNG, Temporal (all services), OpenSearch and its Dashboards,
VictoriaMetrics/VictoriaLogs/Alertmanager (vmagent and Vector buffer or retry), Argo CD, and the other
operators. None are on a path that other workloads need to keep running.

**Known gaps** (not yet addressed):
- **CoreDNS** is a single replica managed by k3s - draining its node blips cluster-internal DNS. Scaling it with
  `kubectl scale` works but k3s can reset it on an upgrade; the durable fixes are disabling the k3s addon and
  running your own, or an Ansible step that re-asserts the replica count.
- **Traefik** (k3s default) is a single replica and unused (every Ingress is Tailscale). Disabling it
  (`--disable traefik`) removes it and its per-node load balancers.
- **API endpoint**: agents, the Ansible-installed agent kubeconfig, and your laptop's kubeconfig point at the first
  server (`rpi-5-1`). While it is down, `kubectl` from those places fails - run it from another control-plane node.
  A stable endpoint (kube-vip / a DNS name over all three servers) would fix this.
- **LAN DNS clients** should be given at least two node IPs: Blocky is reachable on every node IP, and a rebooting
  node's IP stops answering.
- While a storage node (`rpi-5-2`/`rpi-5-3`) is out, every Longhorn volume has one replica until it returns.
- Control plane: `rpi-5-1/2/3` are the etcd members; one at a time keeps quorum (2 of 3).
- **Not yet verified on the live cluster**: the real write-outage time when the primary's node is drained. Test:
  run a write loop through `postgres-pooler-rw`, drain the primary's node, and measure the gap.

## Exposing UIs via Tailscale Operator

Reaches Grafana, Alertmanager, the VictoriaMetrics UI, the Longhorn UI, Blocky's `/metrics`, SearXNG, the Argo CD
UI, and Homepage (a dashboard linking to all of them) privately from any device signed into your tailnet
(e.g. the Tailscale app on your phone) — no VPN
config, no port-forwarding, valid HTTPS. This is **not** Funnel — nothing here is reachable from the public
internet, only from devices in your own tailnet. **The operator install, ProxyGroup, and per-service
Ingresses now live in this repo's `apps/` directory** (`apps/tailscale-operator/`, see [GitOps (Argo CD)](#gitops-argo-cd)) — this
repo's only remaining job is seeding the OAuth credentials Secret.

This is a different thing from the [Tailscale Integration](#tailscale-integration-optional) section
below: that one installs the Tailscale *client* on each Pi node itself (node-level VPN/SSH access).
This one runs the Tailscale *Kubernetes Operator* as an in-cluster pod (`apps/tailscale-operator/`), which
creates tailnet-only HTTPS ingress for specific services — distinct from `roles/tailscale`.

### One-time tailnet setup (do this before deploying)

1. **Create an OAuth client** — Tailscale admin console → Settings → OAuth clients → Generate. Grant
   `write` scope for **Services**, **Devices Core**, and **Keys / Auth Keys**, tagged `tag:k8s-operator`.

2. **Add ACL tags** — Settings → Access Controls, merge this into your policy:
   ```json
   "tagOwners": {
     "tag:k8s-operator": [],
     "tag:k8s": ["tag:k8s-operator"]
   }
   ```

3. **Add ACL auto-approvers for Services** — merge this too, into the same policy file. This is a
   **separate block from `tagOwners` above and easy to miss** — without it, the operator successfully
   registers each UI as a [Tailscale Service](https://tailscale.com/kb/1483/services) (it'll show up in
   `tailscale service list`), but the service is never actually approved to serve traffic: the hostname
   never resolves, and the proxy's own `tailscale cert <hostname>` fails with
   `invalid domain "...": must be one of [...]`. This is exactly the failure mode you'll hit if you skip
   this step:
   ```json
   "autoApprovers": {
     "services": {
       "tag:k8s": ["tag:k8s"]
     }
   }
   ```
   (ProxyGroup pods are tagged `tag:k8s` by default, and the Services they advertise inherit that tag —
   this line says "a device tagged tag:k8s is auto-approved to advertise a Service tagged tag:k8s.")

4. **Enable HTTPS Certificates** — Settings → enable "HTTPS Certificates" (required for valid `.ts.net`
   HTTPS certs).

5. **Store the OAuth credentials in Vault** — never paste the client secret into a chat session or
   commit it in plaintext:
   ```bash
   ansible-vault edit group_vars/all/main.yaml
   ```
   Add:
   ```yaml
   tailscale_oauth_client_id: "<your client ID>"
   tailscale_oauth_client_secret: "<your client secret>"
   ```

### Deploying

Seed the OAuth Secret (the only Ansible-driven step left — Argo CD handles the actual operator install and
Ingresses once it's bootstrapped, see [GitOps (Argo CD)](#gitops-argo-cd)):
```bash
ansible-playbook site.yml -i inventory.dist -t secrets --ask-vault-pass
```

### Access URLs

Replace `<tailnet>` with your tailnet's `.ts.net` domain — find it via the admin console's DNS tab, or
just run `tailscale status` on any device already in the tailnet (it's the suffix on every device's
hostname shown there):

| Service | URL |
|---|---|
| Homepage (links to everything below) | `https://home.<tailnet>.ts.net` |
| Grafana | `https://grafana.<tailnet>.ts.net` |
| Alertmanager | `https://alertmanager.<tailnet>.ts.net` |
| VictoriaMetrics | `https://victoriametrics.<tailnet>.ts.net` |
| OpenSearch Dashboards | `https://opensearch.<tailnet>.ts.net` |
| Longhorn | `https://longhorn.<tailnet>.ts.net` |
| Blocky (`/metrics`) | `https://blocky.<tailnet>.ts.net` |
| SearXNG | `https://search.<tailnet>.ts.net` |
| Temporal Web UI | `https://temporal.<tailnet>.ts.net` |
| Argo CD | `https://argocd.<tailnet>.ts.net` |
| Open WebUI | `https://chat.<tailnet>.ts.net` |
| WhoDB | `https://whodb.<tailnet>.ts.net` |
| LiteLLM | `https://litellm.<tailnet>.ts.net/ui` |
| GO Feature Flag (Swagger) | `https://flags.<tailnet>.ts.net/swagger/index.html` |

Confirmed working from a phone with the Tailscale app active. If you test from a **Mac terminal or
Safari** and it doesn't resolve, see the Troubleshooting note below before assuming the deployment is
broken — there's a known, unrelated local-resolver quirk that can affect just that one machine.

### Configuration

- **Application**: `apps/tailscale-operator/` — `values.yaml` (chart values, oauth
  deliberately left unset) and `manifests/` (the `ProxyGroup` plus one `Ingress` per exposed UI, sharing
  a single ProxyGroup, `ingress-proxies`, 2 replicas for HA, instead of one proxy pod per service).
- **Secret**: the `operator-oauth` Secret the chart expects to find pre-created is one entry in the
  generic `k8s_secrets` role's list (`group_vars/all/cluster_secrets.yaml`) — see
  [Secrets bridge](#gitops-argo-cd).
- To add another service later, add an `Ingress` to `apps/tailscale-operator/manifests/ingresses.yaml`
  and commit — no Ansible run needed, Argo CD picks it up on its own.
- **Proxy connectivity metrics**: `manifests/proxyclass.yaml` (a `ProxyClass` with `spec.metrics.enable:
  true`, referenced by `manifests/proxygroup.yaml`'s `spec.proxyClass`) makes the `ingress-proxies` pods
  serve Tailscale connectivity metrics (bytes in/out, peer status - the `tailscaled` daemon's own stats,
  **not** operator-reconciliation metrics - this chart has no toggle for the latter at all, confirmed via
  `helm template`) at a `ingress-proxies-metrics` Service, scraped by `manifests/vmservicescrape.yaml`. No
  compatible Grafana dashboard exists - the one candidate found (24177) polls the Tailscale *admin API*,
  a different data source entirely, and would just show empty panels.
- To make a specific one of these public (Funnel, not tailnet-only), add the annotation
  `tailscale.com/funnel: "true"` to that service's Ingress — deliberately not done here by default.

### Troubleshooting

```bash
kubectl -n tailscale get pods
kubectl -n tailscale logs deployment/operator
kubectl -n tailscale get proxygroup ingress-proxies -o yaml   # check status.conditions
kubectl -n monitoring get ingress grafana -o yaml             # check .metadata.annotations, .status
```
(`tailscale.com/proxy-group` is set as an **annotation**, not a label — `kubectl ... -l` won't match it.)

**Service registers but never becomes reachable** — `tailscale service list` (run from any tailnet
device, or `kubectl -n tailscale exec ingress-proxies-0 -c tailscale -- tailscale service list`) shows
the hostname with a real IP, but the hostname never resolves and the proxy's own
`tailscale cert <hostname>` fails with `invalid domain "...": must be one of [...]`. This means the
`autoApprovers.services` ACL block (above) is missing or wasn't saved before the Ingress was created.
Add it, then restart the proxy pods to force them to pick up the new authorization immediately rather
than wait for their own poll cycle:
```bash
kubectl -n tailscale rollout restart statefulset ingress-proxies
```

**Works on phone, not from a Mac terminal/Safari** — a known, per-machine macOS quirk, not a deployment
problem. Confirm the deployment is actually fine first: `tailscale service list` shows the service, and
connecting by the Service's virtual IP directly (bypassing DNS) succeeds —
`curl -k --resolve <hostname>:443:<service-ip> https://<hostname>/`. If that works but the plain hostname
doesn't, it's an isolated DNS-resolution issue on that one Mac (a flaky `mDNSResponder` state, not a
scutil/config problem — `scutil --dns` will show the split-DNS entry as present and "Reachable" even
while it's broken). Try `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder` and retest
after a few minutes; if it's still broken, it doesn't indicate anything wrong with the actual
deployment — test from any other device on the tailnet instead.

If an Ingress never gets a tailnet hostname at all (not even a pending Service registration), check the
operator's logs for OAuth/ACL errors first — the most common cause is the `tag:k8s-operator`/`tag:k8s`
`tagOwners` entries not being present yet.

## Tailscale Integration (Optional)

Tailscale is a zero-config VPN built on WireGuard that securely connects nodes over the internet. This
installs the Tailscale *client* directly on each Pi's OS for node-level SSH/VPN access — distinct from the
Tailscale *Kubernetes Operator* (`apps/tailscale-operator/`) that exposes in-cluster UIs; see
[Exposing UIs via Tailscale Operator](#exposing-uis-via-tailscale-operator) for that one.

### One-time setup (before first deploy)

Uses a **dedicated** OAuth client, deliberately separate from the one `apps/tailscale-operator/` uses for
the in-cluster operator — least-privilege, so a leaked node-join credential can't also act as the
Kubernetes operator:

1. Tailscale admin console → Settings → OAuth clients → Generate. `write` scope for **Auth Keys** only.
   Tag: `tag:pi-node`.
2. Settings → Access Controls, merge in: `"tagOwners": { "tag:pi-node": [] }`
3. `ansible-vault edit group_vars/all/main.yaml`, add `tailscale_node_oauth_client_id` and
   `tailscale_node_oauth_client_secret`.

### Installation

```bash
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags tailscale
```

Or just run `make deploy` — it's part of the full playbook now.

**Deployed to:** Pi4 and Pi5 instances (`hosts: pi4,pi5` in `site.yml`) - every node in this cluster's
inventory.

### Configuration

Nodes join the tailnet automatically — no manual step needed. On every run, the role checks
`tailscale status --json` first; if a node isn't already connected, it exchanges the OAuth credentials
above for an API token, mints a one-time auth key (tagged `tag:pi-node`, expiring in 5 minutes), and runs
`tailscale up --authkey=... --hostname={{ inventory_hostname }}` — see `roles/tailscale/README.md` for the
full mechanics. Already-connected nodes skip this entirely, so routine `make deploy` runs don't mint new
keys.

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

Edit `group_vars/k3s_cluster/k3s.yaml` (shared by every server + agent node — was previously duplicated
identically in separate `group_vars/server/k3s.yaml` and `group_vars/agent/k3s.yaml` files):

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

- **Encrypted with Vault**: `group_vars/all/main.yaml` — `k3s_join_token`, `tailscale_oauth_client_id`,
  `tailscale_oauth_client_secret` (used by `apps/tailscale-operator/`), `tailscale_node_oauth_client_id`,
  `tailscale_node_oauth_client_secret` (used by `roles/tailscale` to join nodes to the tailnet -
  deliberately a separate OAuth client from the operator's), `searxng_secret_key`,
  `searxng_metrics_password` (SearXNG's own `open_metrics` Basic Auth password - see [Search
  (SearXNG)](#search-searxng) - only the password is ever checked, there's no real "username" behind
  it), `temporal_db_password` (used by both `apps/postgres/manifests/temporal-database.yaml` and
  `apps/temporal/` - see [Temporal](#temporal)), `opensearch_admin_password` (used by `apps/opensearch/`
  - unlike Grafana's admin login, this one is a real, actively-used credential, since the OpenSearch
  Kubernetes Operator makes auth mandatory on the cluster itself; min 8 chars, upper, lower, digit,
  special char - see [Logging](#logging-opensearch)), `openwebui_secret_key` (signs Open WebUI's session
  cookies, `WEBUI_SECRET_KEY` - not an LLM-provider credential; no API key for any backend lives in this
  repo at all, that's configured through Open WebUI's own Settings UI after it's running), and
  `openwebui_db_password` (used by both `apps/postgres/manifests/open-webui-database.yaml` and
  `apps/open-webui/` - same pattern as `temporal_db_password`, see [Open WebUI](#open-webui)). The first
  pair never appear in `apps/` — see [GitOps (Argo CD)](#gitops-argo-cd)'s "Secrets bridge"; the
  node-join pair are consumed directly by `roles/tailscale` and never touch `apps/` either.
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
- **Server unreachable**: Check server IP in `group_vars/k3s_cluster/k3s.yaml`
- **Port blocked**: Ensure port 6443 is open between nodes

### System Pods Not Running

```bash
ssh ansible@rpi-5-1
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

The `helm_drift_check` role now only runs after Argo CD's own chart install (the one Helm release Ansible
still manages directly) and checks whether every resource in its current manifest actually exists live.
For every other chart (Longhorn, VictoriaMetrics, OpenSearch, Blocky, SearXNG, redis-operator,
WhoDB, CloudNativePG, Tailscale Operator), this
class of drift can't happen anymore in practice — Argo CD's continuous reconciliation would just re-apply
the missing resource on its next sync — but for the Argo CD install itself, if it detects drift, the
playbook **fails with the exact recovery command to run** (a `helm upgrade` invoked directly rather than
through Ansible, which resolves it):

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
