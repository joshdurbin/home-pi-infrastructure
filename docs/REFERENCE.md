# Reference

> Looking for a quick setup? See the [main README](../README.md) — this is the deep-dive version:
> architecture rationale, every config option, and troubleshooting. Everything here is optional reading;
> the main README is all you need to get the cluster running.

A comprehensive Ansible-based infrastructure automation for Raspberry Pi clusters running k3s Kubernetes. This project configures Raspberry Pi instances (Pi 3B+, Pi 4B, Pi 5) as a lightweight k3s Kubernetes cluster, optimized for minimal resource usage by disabling unnecessary hardware features (Bluetooth, audio, camera, HAT interfaces, etc.).

**Table of Contents:**
- [Hardware Setup](#hardware-setup)
- [Quick Start](#quick-start)
- [Makefile Commands](#makefile-commands)
- [System Optimizations](#system-optimizations)
- [User Management](#user-management)
- [K3S Verification](#k3s-verification)
- [Node Maintenance](#node-maintenance)
- [Telemetry and phone-home](#telemetry-and-phone-home)
- [kubectl Access From Your Machine](#kubectl-access-from-your-machine)
- [GitOps (Argo CD)](#gitops-argo-cd)
- [Storage (Longhorn)](#storage-longhorn)
- [Monitoring (VictoriaMetrics, Grafana)](#monitoring-victoriametrics-grafana)
- [UniFi telemetry (UnPoller)](#unifi-telemetry-unpoller)
- [Logging (OpenSearch; VictoriaLogs scaled to zero)](#logging-opensearch)
- [DNS (Blocky)](#dns-blocky)
- [Search (SearXNG)](#search-searxng)
- [Redis Clusters (Blocky + SearXNG Caching)](#redis-clusters-blocky--searxng-caching)
- [Postgres (CloudNativePG)](#postgres-cloudnativepg)
- [Temporal](#temporal)
- [Home Dashboard (Homepage)](#home-dashboard-homepage)
- [Node Rebalancing (descheduler)](#node-rebalancing-descheduler)
- [Vulnerability Scanning (Trivy Operator)](#vulnerability-scanning-trivy-operator)
- [Open WebUI](#open-webui)
- [Bifrost](#bifrost)
- [GO Feature Flag](#go-feature-flag)
- [Collision tracker](#collision-tracker)
- [Snowflake (Tor)](#snowflake-tor)
- [Audio node and shairport-sync](#audio-node-and-shairport-sync)
- [Availability and node maintenance](#availability-and-node-maintenance)
- [Testing failover (Postgres, Redis)](#testing-failover-postgres-redis)
- [Exposing UIs via Tailscale Operator](#exposing-uis-via-tailscale-operator)
- [Tailscale Integration (Optional)](#tailscale-integration-optional)
- [Cluster Configuration](#cluster-configuration)
- [Troubleshooting](#troubleshooting)
- [References](#references)

## Hardware Setup

| Node | IP | Board | Role | Labels / notes |
|---|---|---|---|---|
| `rpi-5-1` | 192.168.1.30 | Pi 5 (8GB) | control plane | `pi5=true`, `storage=true` (256GiB for Longhorn) |
| `rpi-5-2` | 192.168.1.41 | Pi 5 (8GB) | control plane | `pi5=true` |
| `rpi-5-3` | 192.168.1.28 | Pi 5 (8GB) | control plane | `pi5=true` |
| `rpi-5-4` | 192.168.1.83 | Pi 5 (8GB) | worker | `pi5=true` |
| `rpi-5-5` | 192.168.1.95 | Pi 5 | worker | `pi5=true`, `storage=true` (256GiB for Longhorn) |
| `rpi-4b-1` | 192.168.1.13 | Pi 4B (4GB, 128GB SSD) | worker | |
| `rpi-4b-2` | 192.168.1.14 | Pi 4B (4GB, 128GB SSD) | worker | |
| `rpi-4b-3` | 192.168.1.18 | Pi 4B (4GB, 128GB SSD) | worker | |
| `rpi-3bplus-1` | 192.168.1.15 | Pi 3B+ (1GB, SD card) | audio node | `audio_output=true`, taint `dedicated=audio:NoSchedule` |

- **Control plane** (`[server]`): the three Pi 5s are the etcd members. etcd is very sensitive to disk fsync
  latency, and the Pi 4B disks are too slow for it, so only Pi 5s are control plane. The membership is
  deliberately fixed at three (an odd-sized quorum; a fourth member would tolerate no more failures than three).
  `rpi-5-4` is a Pi 5 that is a worker only (`[agent]`, never `[server]`).
- **Pi 5 nodes** also carry the disk-heavy workloads (Longhorn replicas, VictoriaMetrics, OpenSearch, Postgres
  by default), alongside etcd. Revisit if their disks don't keep up with both.
- **Longhorn**: `rpi-5-1` and `rpi-5-5` carry `storage=true` and hold every volume's replica *data* (256GiB each: `longhorn_disk_reserved_gib` in their host vars); the volumes
  attach over the network to pods on any node.
- **`pi5=true`** marks the Pi 5s (derived from the board model each node reports, not declared per host); OpenSearch requires it (its Amazon Linux images won't run on a Pi 4B).
- **Audio node** (`[audio]`): see [Audio node and shairport-sync](#audio-node-and-shairport-sync). It runs only the
  k3s agent, node-exporter, Vector and shairport-sync.
- Everything else, including VictoriaMetrics and (by default) Postgres, is unpinned and can schedule
  on any node with capacity. Size container memory limits for the smallest node that can run them: the Pi 4Bs
  report ~3.9GiB (`kubectl get nodes -o jsonpath='{.status.capacity.memory}'`).

See also [Logging](#logging-opensearch), [Storage (Longhorn)](#storage-longhorn) and
[Monitoring](#monitoring-victoriametrics-grafana).


## Project Structure

```
home-pi-infrastructure/
├── site.yml                      # PRIMARY: Unified infrastructure configuration
├── Makefile                      # Convenient commands (make deploy, make verify, etc.)
├── inventory.dist                # Ansible inventory: nodes, IPs and groups
├── requirements.yaml             # Ansible collections
├── ansible.cfg                   # Ansible configuration
├── apps/                         # Argo CD's half of this repo - see GitOps (Argo CD) below.
│   │                              # Ansible never reads this directory; Argo CD never reads
│   │                              # anything outside it. Same repo, two independent consumers.
│   │                              # One directory per app: application.yaml, values.yaml, and
│   │                              # (where needed) manifests/.
│   ├── longhorn, victoria-metrics, victoria-logs (scaled to zero), opensearch, argocd-metrics
│   ├── cloudnative-pg, proxysql-operator (ProxySQL, scaled to zero), zot, postgres, temporal
│   ├── redis-operator, redis-operator-metrics, redis
│   ├── blocky, searxng, homepage, whodb
│   ├── bifrost, open-webui, go-feature-flag
│   ├── shairport-sync, snowflake
│   ├── descheduler, trivy-operator
│   └── tailscale-operator
├── group_vars/                   # Group-based variables
│   ├── all/                      # All hosts (Vault secrets, cluster_secrets.yaml)
│   ├── k3s_cluster/              # Shared server+agent config (k3s version, cluster API facts)
│   └── pi3/ pi4/ pi5/            # board_model per hardware class
├── host_vars/                    # Per-node k8s_labels (and the audio node's taint)
├── roles/                        # Custom Ansible roles
│   ├── setup/                    # System optimization, packages, unattended-upgrades
│   ├── user_management/          # User & SSH key management
│   ├── helm/                     # Helm binary install (apt + official GPG key)
│   ├── k8s_labels/               # Applies node labels declared in host_vars (k8s_labels var)
│   ├── argocd/                   # Bootstraps Argo CD + the root Application (see GitOps section)
│   ├── k8s_secrets/              # Seeds every Secret/ConfigMap apps/ can't (see GitOps section)
│   ├── helm_drift_check/         # Post-install verification that Helm's manifest matches live state
│   ├── grafana_dashboards/       # Imports community Grafana dashboards
│   ├── longhorn_prereqs/         # Host prereqs (open-iscsi/nfs-common); skipped on the audio node
│   └── tailscale/                # Tailscale VPN client on each node
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
rpi-5-1      ansible_host=192.168.1.30
rpi-5-2      ansible_host=192.168.1.41
rpi-5-3      ansible_host=192.168.1.28
rpi-5-4      ansible_host=192.168.1.83
rpi-5-5      ansible_host=192.168.1.95
rpi-4b-1     ansible_host=192.168.1.13
rpi-4b-2     ansible_host=192.168.1.14
rpi-4b-3     ansible_host=192.168.1.18
rpi-3bplus-1 ansible_host=192.168.1.15

[all:vars]
ansible_user=ansible
ansible_python_interpreter=/usr/bin/python3
ansible_password=ansible
ansible_become_password=ansible
```

There are no hardware-class groups: each node's board model (`pi5` / `pi4` / `pi3`) is read from its device tree at the
start of every run (`roles/board_facts`), which sets `board_model` and creates those groups for the run (so `hosts: pi4` works in
a play, but `--limit pi4` does not: limit by host name). The inventory defines only decisions: `[server]` (the three
control-plane nodes), `[agent]` (all workers, including the audio node), `[audio]` (the audio node) and
`[k3s_cluster]` (server + agent).

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
`sudo kubectl`. Agent nodes (`rpi-4b-*`, `rpi-5-4`, `rpi-3bplus-1`) run no API server and have no kubeconfig, so `kubectl` there
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

**2. Cordon, then drain the node**:
```bash
sudo kubectl cordon <node>          # no new pods land on it
sudo kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```
(`drain` cordons too, so the first line is optional - it just holds the node out of rotation before you start.)
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
- **Storage nodes** (`rpi-5-1`, `rpi-5-5`) hold the Longhorn replica data. While one is out, every volume runs
  on a single replica; Longhorn itself refuses to drain a node that holds the *last* healthy copy of a volume.
- OpenSearch must run on a Pi 5 (`pi5=true`); with five Pi 5s there is always somewhere for it to go.
- **The audio node** (`rpi-3bplus-1`) is the only place shairport-sync can run, so draining it stops AirPlay until it
  is uncordoned. Nothing else is affected.

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
- **OpenSearch**: two data nodes with one replica of every index and PDBs on both pools, so a drain takes one pod at a
  time and stays green once shards re-sync (check `_cluster/health` between nodes). Its client and data nodes are cluster-manager-eligible and on persistent volumes, so evicting either keeps
  its identity. (See `apps/opensearch/manifests/cluster.yaml` for why that matters.)

## Telemetry and phone-home

**Policy**: nothing running here sends usage data, analytics, crash reports, "check for updates" calls or client logs off the network
that it does not need to function. Downloads the services need (container images, the Trivy and Blocky databases, Grafana plugin
installs, Bifrost's model pricing list, SearXNG's search queries, Argo CD reading git) are not telemetry and are left alone. Check
every new service against this list before adding it, and put its opt-out in git, not in the UI.

**Defence in depth.** The switches below are the primary control. Some namespaces also have egress NetworkPolicies that cannot reach
the internet at all (Temporal, WhoDB, Open WebUI, Go Feature Flag, Postgres, Redis), which contains a service even if a switch is
missed or an image update adds a new call. Namespaces without one (`monitoring`, `kube-system`, `trivy-system`, `tailscale`, ...)
rely on the switches alone, so those are the ones to re-check after an upgrade.

| Service | What it sends by default | Opt-out (where it lives) |
|---|---|---|
| Tailscale: node `tailscaled`, operator, ingress proxies | client logs to Tailscale's log service; network flow logs ride the same pipeline if the tailnet has them on | `TS_NO_LOGS_NO_SUPPORT=true` in `/etc/default/tailscaled` (`roles/tailscale`), `operatorConfig.extraEnv` (`apps/tailscale-operator/values.yaml`), ProxyClass `tailscaleContainer.env` (`manifests/proxyclass.yaml`) |
| Grafana | usage statistics (stats.grafana.org), update checks, plugin update checks, news feed | `analytics.reporting_enabled`, `check_for_updates`, `check_for_plugin_updates`, `feedback_links_enabled`, `news.news_feed_enabled` all `false` (`apps/victoria-metrics/values.yaml`) |
| Traefik (k3s) | update check to update.traefik.io (anonymous usage is opt-in, off) | removed: `disable: [traefik]` in `group_vars/server/main.yaml` (it was unused) |
| Longhorn | upgrade checker to Longhorn's upgrade-responder (usage metrics only if enabled, they are not) | `defaultSettings.upgradeChecker: false` and `allowCollectingLonghornUsageMetrics: false` (`apps/longhorn/values.yaml`) |
| Trivy | after every run the client calls check.trivy.dev, sending a machine identifier (hash of hostname + MAC), the command and its flags; skipped only if both `SKIP_VERSION_CHECK` and `DISABLE_TELEMETRY` are set | server: `TRIVY_SKIP_VERSION_CHECK`, `TRIVY_DISABLE_TELEMETRY` via `trivy.valuesFromConfigMap` (`apps/trivy-operator/manifests/trivy-env-configmap.yaml`); scan Jobs (the operator cannot pass them env): `check.trivy.dev` is NXDOMAIN in CoreDNS (`apps/k3s-addons/manifests/coredns-telemetry-sinkhole.yaml`) |
| Temporal server | version service gets product, version, CPU arch, OS, DB type, cluster ID and connected SDKs | `TEMPORAL_VERSION_CHECK_DISABLED=true` (`apps/temporal/values.yaml`, `server.additionalEnv`) |
| WhoDB | update check; daily anonymous install heartbeat to PostHog (other analytics are consent-gated in the UI) | `WHODB_DISABLE_UPDATE_CHECK`, `WHODB_HEARTBEAT_DISABLED` (`apps/whodb/values.yaml`) |
| Open WebUI | update check (default on); telemetry/analytics libraries default off in the image | `ENABLE_VERSION_UPDATE_CHECK=false`, plus `ANONYMIZED_TELEMETRY`, `SCARF_NO_ANALYTICS`, `DO_NOT_TRACK` stated explicitly (`apps/open-webui/values.yaml`) |
| Homepage | update check (GitHub releases API) | `hideVersion` and `disableUpdateCheck: true` (`apps/homepage/values.yaml`) |

Checked and found to have nothing to opt out of: Argo CD (Google Analytics is off unless a tracking ID is set; none is), Headlamp,
Bifrost (its "telemetry" plugin is the local Prometheus endpoint), Zot, CloudNativePG and PgBouncer, the Redis operator and caches,
the descheduler, Vector, VictoriaMetrics/VictoriaLogs/vlagent/vmalert, kube-state-metrics and node-exporter, Blocky and SearXNG
(which only make the requests they exist for), shairport-sync, and k3s's CoreDNS, metrics-server and local-path provisioner.
The disabled ProxySQL config has not been audited; check it before bringing it back. OpenSearch Dashboards 3.8 has no
telemetry or newsfeed settings at all (it rejects `telemetry.*` / `newsfeed.*` as unknown keys), so there is nothing to opt out of.

**DNS backstop.** `apps/k3s-addons/manifests/coredns-telemetry-sinkhole.yaml` makes four names that exist only for telemetry or update
checks answer NXDOMAIN to every pod: `check.trivy.dev`, `update.traefik.io`, `stats.grafana.org` and
`longhorn-upgrade-responder.rancher.io`. It is the only control for Trivy's scan Jobs (the operator cannot set their environment) and
a second line for the others. It does not cover the node's own DNS (nodes do not use CoreDNS) or a program that hardcodes its resolver.
If a new entry does not take effect, `kubectl -n kube-system rollout restart deploy/coredns` (one replica: a few seconds of DNS blip).

**Tailnet-level settings this repo cannot change.** Network flow logs (Premium/Enterprise plans) and other logging are switched on or
off in the Tailscale admin console, not by any device. A device that opts out of client logging stops uploading its logs; whether that
also removes it from flow logs is not documented clearly, so if flow logging is on, turn it off in the admin console (Logs).

**Applying changes to a running cluster.** Most of the above is picked up when Argo CD syncs. Two things are not:
```bash
# Longhorn only applies defaultSettings on first install; patch the live setting
kubectl -n longhorn patch settings.longhorn.io upgrade-checker --type merge -p '{"value":"false"}'
# tailscaled on each node: run the Ansible role, one node at a time, against the LAN addresses
# (restarting tailscaled drops the tailnet connection, which would cut a tailnet-addressed SSH session)
make deploy-tailscale   # one node at a time; --limit <node> via: ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags tailscale --limit <node>
```

**Verifying.** Grafana's effective settings: `kubectl -n monitoring exec <grafana-pod> -c grafana -- cat /etc/grafana/grafana.ini | grep -E 'reporting_enabled|check_for|news_feed'`
(`/api/admin/settings` does not work here: anonymous access is an org Admin, not a Grafana server admin, so it returns 403). A pod's environment: `kubectl -n <ns> exec <pod> -- env | grep -iE 'telemetry|update|no_logs'`. Tailscale:
`systemctl show tailscaled -p Environment` on a node, and `kubectl -n tailscale get deploy operator -o yaml | grep -A1 NO_LOGS`.
Egress that actually leaves a namespace can be confirmed from the Pi side with `ss -tnp` / the router's connection log.

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

Longhorn, VictoriaMetrics, OpenSearch, Blocky, SearXNG, redis-operator, WhoDB,
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
gracefully; a one-shot Ansible task wouldn't). Dashboards: grafana.com IDs 19993 and 19974 (the maintained
"ArgoCD / Operational" and "/ Application" overviews).

**Secrets bridge**: `apps/` must never contain real credentials, but a few of these apps need some (Grafana
admin password, Tailscale OAuth client, SearXNG's `secret_key` and metrics password, OpenSearch's admin
password, Open WebUI's session-signing key — Blocky needs none at all, see below).
Those stay exactly where they already were — Ansible Vault, in `group_vars/all/main.yaml` — and a single
role, **`k8s_secrets`**, applies the resulting `Secret`/`ConfigMap` objects directly to the cluster,
decoupled from git
entirely.

`k8s_secrets` is deliberately generic and data-driven: it's a two-task loop (`roles/k8s_secrets/tasks/main.yaml`) over a single list,
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

**Reading a secret back out of the cluster** (from a control-plane node, or anywhere with a kubeconfig):
```bash
kubectl -n <namespace> get secret <name> -o jsonpath='{.data.<key>}' | base64 -d; echo
kubectl -n <namespace> get secret <name> -o json | jq -r '.data | map_values(@base64d)'   # every key
kubectl -n <namespace> get secret <name> -o json | jq -r '.data | keys[]'                  # key names only
```
The commonly wanted ones are tabled in the main [README](../README.md#get-secrets-out-of-the-cluster). The values
you chose yourself live in the Vault (`ansible localhost -e @group_vars/all/main.yaml --ask-vault-pass -m debug -a var=<name>`), which is the source of
truth: editing a Secret with `kubectl` is overwritten by the next `make deploy-secrets`.

## Storage (Longhorn)

Distributed block storage backing every PVC that requests the `longhorn` StorageClass. Namespace: `longhorn`.
**The chart install and all settings now live in this repo's `apps/` directory** (see [GitOps (Argo CD)](#gitops-argo-cd)) — Argo CD
reconciles it continuously; this repo only handles the host-level package prerequisites Longhorn needs on
every node.

**Capacity model** (see `apps/longhorn/values.yaml` in this repo's `apps/` directory for the actual settings):
- Data replicas live **only** on `rpi-5-1` and `rpi-5-5` (the `storage=true` labeled nodes) — 256GiB usable
  per node, and since Longhorn keeps 2 replicas, plan for ~half of requested storage as the real usable ceiling.
- `longhorn-manager`, the UI, the driver, and the CSI components run on every node except the tainted audio Pi — any pod anywhere
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

- **Metrics**: `victoria-metrics-k8s-stack` Helm chart — bundles the VictoriaMetrics operator, a
  `vmcluster` (metrics storage, below), `vmagent` (scraper, cluster-wide), `vmalert`, Alertmanager, kube-state-metrics,
  node-exporter, and **Grafana** (bundled as part of this chart — there's no separate Grafana role).
- **Cluster-mode storage** (so a node in maintenance never stops ingestion or queries): **2 `vminsert`**
  (stateless, receive writes), **2 `vmstorage`** (each with its own 10Gi Longhorn PVC; `replicationFactor: 2`, so each
  holds a full copy) and **2 `vmselect`** (stateless, serve queries; cache in an emptyDir), all behind a `VMCluster`
  CR (`vmcluster` in `apps/victoria-metrics/values.yaml`; the single-node `vmsingle` is off). **2 `vmagent`s** scrape
  every target independently; the duplicate samples are collapsed by `dedup.minScrapeInterval: 30s` on vmstorage and
  vmselect. Every component has required anti-affinity (one per node) and a PDB (`maxUnavailable: 1`), so a drain
  evicts one at a time and the other keeps serving. Retention is 7d. The `vmstorage` Longhorn volumes keep Longhorn's
  default of 2 replicas on purpose: with 1, draining the `storage=true` node holding one would be blocked by
  Longhorn's last-replica drain policy.
- Nothing here is pinned to a node. Everything - including vmstorage, with its PVCs on Longhorn - can schedule on
  a 4GB Pi 4B as well as a Pi 5 (vmstorage requests 1Gi, vmselect 512Mi, vminsert 512Mi, vmagent 512Mi, all of which
  are only placed where that much is free), and Grafana, vmalert, kube-state-metrics and node-exporter were never
  pinned.
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
and native), **Alertmanager**, and **OpenSearch** (the logs store; VictoriaLogs is scaled to zero; see [Logging](#logging-opensearch) below).

Dashboards can be imported from grafana.com via `roles/grafana_dashboards/` (`make deploy-dashboards`; it is not part of `make deploy`) — see that role's own README for what's included and why, and for the
handful already provisioned automatically by the chart itself (Kubernetes cluster/node views, CoreDNS,
etcd, Node Exporter Full, and all four VictoriaMetrics dashboards).

### Accessing Metrics Directly (optional)

```bash
kubectl -n monitoring port-forward svc/vmselect-vmks-victoria-metrics-k8s-stack 8481:8481
```
VictoriaMetrics' own UI is at `http://localhost:8481/select/0/vmui/`; the raw PromQL-compatible API is at
`/select/0/prometheus/api/v1/query`. (Over Tailscale: `https://victoriametrics.<tailnet>.ts.net/select/0/vmui/`.)

## UniFi telemetry (UnPoller)

[UnPoller](https://github.com/unpoller/unpoller) (`apps/unpoller/`, namespace `unpoller`, one pod) logs in to the UniFi Network
application on the UDM (`https://192.168.1.1`) and exposes what it reads - sites, the gateway, switches, access points and every
client - as Prometheus metrics on `:9130/metrics`. vmagent scrapes it (`VMServiceScrape`), so the data lands in VictoriaMetrics next
to everything else, and the Prometheus-datasource UniFi-Poller dashboards (grafana.com 11311 Network Sites, 11313 USG/UDM, 11312
switches, 11314 access points, 11315 clients; 11310 DPI if enabled) are in `roles/grafana_dashboards`.

- **Credential**: a UniFi API key (UniFi Network > Settings > Control Plane > Integrations), or a local read-only account.
  Vault variable `unifi_poller_api_key` (`ansible-vault encrypt_string`, see Secrets & Variables) -> Secret `unpoller-credentials`
  (key `UP_UNIFI_DEFAULT_API_KEY`) via `make deploy-secrets`. UnPoller only issues GET requests.
- **Configuration** is environment variables (`UP_<SECTION>_<KEY>`) in `apps/unpoller/values.yaml`: Prometheus output on, InfluxDB and
  Loki off (InfluxDB is ON by default in UnPoller and would otherwise retry a database that does not exist), self-signed certificate
  accepted, DPI off (about 150 extra series per client).
- **Network**: a NetworkPolicy lets it reach DNS and `192.168.1.1:443` only; only the `monitoring` namespace may reach `:9130`. If the
  UDM's address ever changes, update the policy and `UP_UNIFI_DEFAULT_URL`.
- **Footprint**: a 10 MB image, requests 25m / 48Mi, limit 128Mi.

## Logging (OpenSearch)

Container and host (journald) logs, retained **7 days**, in the shared **OpenSearch** cluster (details below).
**VictoriaLogs** (`apps/victoria-logs/`) is scaled to zero - `replicaCount: 0` on the server and vlagent, Grafana
datasource excluded, Ingress commented out, config and PVCs kept; its old design was two independent full copies
fed through vlagent. Bring it back by restoring those replica counts, the datasource, the Ingress and the
`vlogs`/`vlogs_host` Vector sinks (git history, `values-vector.yaml`).

### OpenSearch

Container + host logs for the whole cluster, retained for **~7 days** (index-boundary granularity, not
an exact cutoff - see below). Namespace: `opensearch`. The **OpenSearch Kubernetes Operator** reconciles
a set of custom resources in `apps/opensearch/manifests/` into the actual running cluster - Argo CD
installs the operator and applies those resources continuously. See `apps/opensearch/README.md` for the
full rationale (why an operator over the plain chart an earlier version of this app used, why OpenSearch
over Elasticsearch/Kibana naming, why TLS + auth are mandatory here unlike everywhere else in this
cluster, why Vector rather than a new log shipper); this section covers day-to-day access.

**Prerequisite**: `opensearch_admin_password` must be set in Vault (`ansible-vault encrypt_string --stdin-name opensearch_admin_password`,
pasted into `group_vars/all/main.yaml`) before this deploys successfully - see [Secrets & Variables](#secrets--variables).

- **Topology**: an `OpenSearchCluster` custom resource (`apps/opensearch/manifests/cluster.yaml`) with two
  node pools - `client` (cluster-manager + ingest, 2Gi PVC) and `data` (data + cluster-manager, 10Gi PVC,
  `storageClassName: longhorn`) - plus its own `dashboards` section (not a separate chart under the operator).
  Two pods of each (client, data, dashboards) on different nodes with required anti-affinity (and PDBs for the pools):
  four manager-eligible nodes give a 3-voter set that survives any one node, and indices keep one replica so every
  shard exists on both data nodes. All pods pinned to the Pi 5s (the image can't run on a Pi 4B CPU). About 7Gi of
  limits; `apps/opensearch/README.md` describes running lean and, importantly, how to scale down safely (a naive
  `replicas` decrease turned the cluster red once).
- **Log shipping**: one Vector DaemonSet, writing to daily
  `logs-*`/`logs-host-*` indices via OpenSearch's bulk API, now authenticating with TLS + basic auth
  (`apps/opensearch/values-vector.yaml`).
- **Retention**: an `OpenSearchISMPolicy` custom resource (`apps/opensearch/manifests/ism-policy.yaml`)
  deletes `logs-*` indices once `min_index_age: 7d`; an `OpenSearchIndexTemplate`
  (`apps/opensearch/manifests/index-template.yaml`) sets `number_of_replicas: 1` for those same indices
  (a primary on one data node, a replica on the other). Indices created earlier keep their old count: raise them
  once with `PUT logs-*,logs-host-*/_settings {"index":{"number_of_replicas":1}}`.
- **Auth**: unlike everywhere else in this cluster (Grafana's anonymous Admin, Argo CD via tailnet),
  **mandatory** here - the operator has no equivalent of a fully-disabled security plugin. TLS is
  operator-generated (self-signed), and Vector/Dashboards authenticate with the same
  `opensearch-admin-credentials` Secret. Dashboards' own TLS to the *browser* is still disabled
  (`dashboards.tls.enable: false` in `cluster.yaml`) - Tailscale remains the access boundary for that leg.
- **Prometheus metrics**: the official `opensearch-project/opensearch-prometheus-exporter` plugin,
  installed declaratively via `cluster.yaml`'s `general.pluginsList` (version-matched exactly to this
  cluster's OpenSearch, 3.9.0.0 - updating that list triggers a rolling restart to install it). Exposes
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
| `storage=true` | rpi-5-1, rpi-5-5 | Longhorn replica placement (physical data) |
| `pi5=true` | rpi-5-1..5 | OpenSearch (Amazon Linux images need a Pi 5 CPU) |

The former `telemetry=true` (VictoriaMetrics) and `database=true` (Postgres) labels are gone -
those workloads are unpinned. Postgres's optional `local` storage mode pins to `rpi-5-1`/`rpi-5-4` by
hostname instead (`apps/postgres/cluster/components/local`), so no custom label is needed for it.

Labels are declared per-host in `host_vars/rpi-5-*.yaml` under the `k8s_labels` key (decisions such as `storage=true`; `pi5=true` is
derived from the hardware by `roles/board_facts`), and applied to the live
cluster by the `k8s_labels` role (which reads every host's `k8s_labels` var and patches the matching
Kubernetes Node object — not tied to any single chart-deploying role). Labels are deliberately *not* driven
by group_vars, since this repo's `ansible.cfg` doesn't set `hash_behaviour = merge`, so a
group_vars-level `k8s_labels` would be silently replaced outright (not merged) by any host's own
`k8s_labels` in `host_vars/`, rather than combined with it.

## DNS (Blocky)

A single [Blocky](https://0xerr0r.github.io/blocky/) instance for the whole LAN — resolves DNS for any
client pointed at it, blocking ads/trackers and forwarding everything else upstream over
**DNS-over-TLS to Cloudflare**. Namespace: `blocky`. DHCP is out of scope — point clients at it manually or
via your router's DNS setting. **The chart install, config, NetworkPolicy, and metrics wiring all live in
the `apps/` directory** (`apps/blocky/`, see [GitOps (Argo CD)](#gitops-argo-cd)) — Argo CD reconciles them
continuously. Unlike every other app here, **this one needs nothing from Ansible at all**: Blocky has no
admin login, so its entire config is non-secret and lives as a plain git-managed manifest.

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
  has no exporter at all - it is scraped directly through that `VMServiceScrape`.
- **Services**: two dedicated `LoadBalancer` Services (via k3s's built-in ServiceLB, which stays enabled
  for these) — `blocky-dns` (53/tcp+udp, for LAN clients) and `blocky-http` (4000/tcp, metrics + the
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
ansible-vault encrypt_string --stdin-name <name>
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
- **Topology**: everything lives in ONE namespace, `redis` (`apps/redis/`, its own Argo CD app),
  deliberately **not** the consuming apps' namespaces, so their egress-only `NetworkPolicy`
  (`podSelector: {}` — every pod in the namespace) doesn't clamp down the redis/sentinel pods' own traffic.
  It holds one `RedisReplication` per cache — `blocky-cache` and `searxng-cache` (each
  `clusterSize: 2`: one master, one replica, own 512Mi Longhorn PVC) — and ONE shared `RedisSentinel`
  (`redis-sentinels`, `clusterSize: 3`, quorum 2-of-3) monitoring both, one master group per cache,
  named after it. The operator wires only one `RedisReplication` per Sentinel and only from the Sentinel's own
  namespace (`blocky-cache`, via `redisReplicationName`); the other two groups are `sentinel monitor` lines in a
  ConfigMap (`redis-sentinels-config`, key `redis-sentinel-additional.conf`) that `additionalSentinelConfig`
  *names* (it is a ConfigMap name, not inline config), by each cache's `-master` Service hostname
  (`resolveHostnames: "yes"`). If the sentinel StatefulSet's pod-0 is stuck on an old revision, delete that pod.
  **Unverified live when written** - check `sentinel masters` (below) shows all three groups.
- **Known operator quirk**: if a sentinel *container* restarts in place, the image appends its
  `sentinel monitor` line to the persisted config again and crashes with `Duplicate master name`. Delete that
  pod (`kubectl -n redis delete pod redis-sentinels-sentinel-<n>`) to get a fresh volume.
- **No Bifrost cache.** There used to be a third cache, `bifrost-cache`, that nothing used: Bifrost's Redis mode is a
  semantic cache and needs the RediSearch module (`FT.*`), which neither the operator's Redis image nor the official
  `redis:8` image ships (both only have `vectorset`; `redis/redis-stack-server` does, and runs under the operator, but it
  would also need an embedding model). Removed rather than kept idle; the pods, volumes and its Sentinel group are gone.
- **Sizing**: `maxmemory 128mb` / `allkeys-lru` (set via `redisConfig.dynamicConfig` on the
  `RedisReplication`) — these are small caches, not a source of truth. Each redis container gets a 192Mi
  memory limit — `maxmemory` plus headroom for redis's own process overhead, client buffers and
  replication backlog, not `maxmemory` itself. Sized for the smaller of this cluster's two node classes
  (the Pi 4B nodes are 4GB boards, not 8GB — see [Hardware Setup](#hardware-setup)).
- **Metrics**: a `redis_exporter` sidecar on every replication pod (port 9121), scraped by a `VMPodScrape`
  (not a `VMServiceScrape` like Blocky's own — the operator doesn't document a stable Service port *name*
  for the exporter, only the container port number) in each cache namespace.
- **How Blocky connects**: natively Sentinel-aware — its `redis.sentinelAddresses` (in
  `apps/blocky/manifests/configmap.yaml`) points at the round-robin `redis-sentinels-sentinel`
  Service (the shared Sentinel), and `redis.address: blocky-cache` is the Sentinel master group name
  (`redisSentinelConfig.masterGroupName`). Always finds the current master, even after a failover.
- **How SearXNG connects**: its `valkey.url` only takes a single connection string, with no
  Sentinel-discovery support at the protocol level — but rather than pointing at a specific pod, it points
  at `searxng-cache`'s own operator-maintained **`searxng-cache-master`** Service
  (`searxng-cache-master.redis.svc.cluster.local`), confirmed live to be exactly what the
  `RedisReplication` CR itself recommends:
  `kubectl -n redis get redisreplication searxng-cache -o jsonpath='{.status.connectionInfo}'`. The
  redis-operator keeps this Service's endpoint pointed at whichever pod is actually master, so this *is*
  failover-aware despite the plain-URL limitation — SearXNG follows a failover automatically, same as
  Blocky, just via a different (non-Sentinel) mechanism.

**A real gotcha, confirmed live, worth remembering**: the operator appends its own `-sentinel` suffix to
whatever name a `RedisSentinel` CR is given — so the CR named `redis-sentinels` actually produces a
StatefulSet/Service named `redis-sentinels-sentinel` (`kubectl -n redis get svc` to check),
**not** `redis-sentinels`. This bit the very first deploy of this feature — Blocky logged
`sentinel: ... no such host` and silently ran with no cache until the address was corrected.

**Troubleshooting:**
```bash
# Cluster health
kubectl -n redis get pods,pvc,redisreplication,redissentinel

# Which pod is master right now
kubectl -n redis get redisreplication blocky-cache

# Does the shared Sentinel monitor all three groups?
kubectl -n redis exec redis-sentinels-sentinel-0 -- redis-cli -p 26379 sentinel masters | grep -A1 '^name'

# Actual Service names the operator created (don't assume - check)
kubectl -n redis get svc

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
  it. Image: `ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:c7747d8d...` (pinned by digest because CNPG re-pushes the floating `18.6` tag and the Zot cache never rechecks a cached tag; current latest major, confirmed against the real
  registry, not assumed).
- **Storage mode** (`apps/postgres/cluster/kustomization.yaml`): pick exactly one component, one line:
  - `components/longhorn` (default) - volumes use a dedicated `longhorn-postgres` StorageClass (2 Longhorn
    replicas on `rpi-5-1`/`rpi-5-5`, `best-effort` data locality). The instances can run on **any** node and
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
  primary" itself. `instances: 2` on each pooler, on different nodes with a PDB (PgBouncer holds no data of
  its own, so it can run anywhere). Native Prometheus metrics on port 9127 per pod, no separate
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
- **ProxySQL (scaled to zero)**: tried as the connection proxy in place of the poolers and rolled back. Its whole
  configuration is still in `apps/postgres/manifests/proxysql*.yaml` and `apps/proxysql-operator/`, switched off by a
  `directory.exclude` in `apps/postgres/application.yaml`. Why it did not work: **ProxySQL 3.0.11 rejects the mixed
  per-column result formats pgx (Bifrost, Temporal) and lib/pq (Grafana) send** - `ERROR: per-column result formats are
  not supported: all result columns must request the same format code (SQLSTATE 0A000)` - so all three crashed on
  start. Fixed upstream in sysown/proxysql#6206 (merged 2026-09-29 into the `v3.0` branch) but **not in any release**
  (latest is v3.0.11, 2026-08-27; Docker Hub has nothing newer). Re-try when a v3.0.x after that ships.
  - **To bring it back**: set `image.tag` in `apps/postgres/manifests/proxysql.yaml` to the fixed release; delete the
    `directory` block from `apps/postgres/application.yaml`; point the apps' hosts at `postgres-proxy` (the
    `postgres-pooler-rw`/`-ro` references in `apps/*/values.yaml`, `group_vars/all/cluster_secrets.yaml` and
    `apps/go-feature-flag/`); remove `pooler-*.yaml` once it is verified; `make deploy-secrets`.
  - **Design, as built**: one `ProxySQLCluster` `postgres-proxy` (2 pods, no PVC) on port 5432 behind one Service;
    read/write split per *user* (hostgroup 0 = `postgres-rw`, 1 = `postgres-ro`; only `whodb` defaults to 1; no query
    rules); user passwords read from the existing `*-db-credentials` Secrets; backend TLS to CNPG's CA
    (`useSSL` + `tls.backend.caSecretName: postgres-ca`); `pgsql-multiplexing: "false"` to match the old session mode.
  - **Runs on the Pi 4Bs only**: the ProxySQL image aborts on the Pi 5 nodes with `jemalloc: Unsupported system page size`
    (16K-page kernel, allocator built for 4K), hence the `pi5` DoesNotExist node affinity in `proxysql.yaml`.
  - **Where the pieces are**: the operator (`apps/proxysql-operator/`) is scaled to zero too (`replicaCount: 0`; it only
    has to run to clear the `ProxySQLConfig` finalizer when that config is pruned - set it back to 1 first if one
    exists). Its image is built into Zot ([Local registry](#local-registry-zot)) because
    upstream's is private (ProxySQL/proxysql-on-k8s#83). The `proxysql-auth` / `proxysql-monitor-credentials` Secrets
    stay in `cluster_secrets.yaml`.
  - **Measured cost, for reference**: PgBouncer is ~180Mi / ~50m across its four pods (31-53Mi each, idle); ProxySQL was
    expected to be roughly 2-3x that in memory.
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

## Local registry (Zot)

An in-cluster OCI registry, [Zot](https://zotregistry.dev) (`apps/zot/`, namespace `zot`, **sync-wave 0** alongside Longhorn,
chart `project-zot/zot`), doing two jobs:

1. **A pull-through cache** for every registry the cluster pulls from - Docker Hub, `ghcr.io`, `quay.io`,
   `registry.k8s.io`, `mirror.gcr.io` and `ecr-public.aws.com`. An image that moves between nodes is served from the LAN
   rather than the internet, and Docker Hub's anonymous pull limit is hit far less often.
2. **Home for images we build ourselves** because upstream's is not pullable - today the ProxySQL operator
   (`localhost:30500/proxysql-operator`; upstream's package is private, [ProxySQL/proxysql-on-k8s#83](https://github.com/ProxySQL/proxysql-on-k8s/issues/83)).

**How a pull works.** Each node's k3s is configured (`roles/k3s_registries`, below) to try Zot first for every one of those
registries, and k3s always tries the real registry *last*:
- *Hit*: Zot has the image, the node pulls it from `localhost:30500`.
- *Miss*: Zot answers `404` immediately (`onDemandInBackground`), the node falls back to the real registry and pulls there as it
  always did, and Zot fetches the image in the background - so the **next** pull anywhere in the cluster is a hit. The first pull
  of anything is therefore never slower than before.
- *Zot down, restarting, or its volume gone*: connection refused, the node falls back to the real registry. Nothing in the
  cluster (Zot, Argo CD, Longhorn, k3s itself) depends on Zot to start, so it can always recover. Do **not** start k3s with
  `--disable-default-registry-endpoint` - that removes the fallback.

**What is cached, and what is not.** Image pulls made by containerd on the nodes. Not cached: pulls Trivy makes itself when it
scans an image, and anything referenced as `localhost:30500/...` (the self-built images - those have no upstream to fall back to).
Mutable tags (`:latest`) would be served stale from the cache; none of the images in use today use one, so pin versions.

**Storage.** A 40Gi Longhorn volume (80Gi raw with Longhorn's two replicas), with dedupe and 6-hourly garbage collection.
- *Sizing*: the 62 images running when this was set up are ~4.9GiB on disk (arm64), ~2.2GiB compressed. Zot's on-demand sync
  copies the **whole multi-arch index** of every image it caches (its `platforms` filter only applies to periodic sync, not on-demand),
  so roughly 3x that: ~7GiB for today's set, ~15GiB after a few generations of upgrades. 40Gi leaves ~2.5x headroom.
- *Retention*: cached tags that have been neither pulled nor synced for 30 days are removed, only under the mirror prefixes
  (`docker-hub/`, `ghcr/`, `quay/`, `k8s/`, `mirror-gcr/`, `ecr-public/`) - the self-built `proxysql-operator` is never touched. Watch the
  size with `zot_repo_storage_bytes` (metrics are scraped; see `apps/zot/manifests/vmpodscrape.yaml`).

**Upstream rate limits.** Docker Hub counts manifest requests, and syncing a whole multi-arch index fetches one manifest per
platform (plus attestation manifests), so Zot's population can use *more* of the anonymous quota than the cluster's own pulls would.
Two mitigations are built in: Docker Hub content is fetched from `mirror.gcr.io` (Google's Docker Hub cache, no pull limit)
first and `registry-1.docker.io` second, and sync retries (`maxRetries: 3`, `retryDelay: 5m`) when it is rate limited. If it still
runs into 429s, give Zot Docker Hub credentials (a `credentialsFile` in the sync config, from a Secret) - not wired up.

**Node configuration** (`roles/k3s_registries`, `make deploy-registries`). Writes `/etc/rancher/k3s/registries.yaml` - one mirror per
registry, endpoint `http://localhost:30500`, with a `rewrite` that maps the image name under that registry's prefix in Zot
(`docker.io/library/redis` becomes `docker-hub/library/redis`). k3s only reads the file at startup, so a change restarts k3s on each node
(the pods keep running; the container shims survive), **one node at a time**, waiting for it to be Ready before the next. It is a
no-op once the file is in place. On a bootstrap the file is written *before* k3s is installed (the "Seed the registry mirror config"
play), so the first start already has it and nothing restarts; afterwards a parallel read-only check finds the nodes whose file would
change, and only those are restarted one at a time. Not done through the k3s-ansible `registries_config_yaml` variable because that role never restarts k3s.

**Rollout order** (a node only starts using Zot once it has the file, so do these in order):
1. Push; Argo syncs Zot (wave 0). If the volume is still the old 30Gi one, resize it first (below).
2. Wait for `zot-0` Ready: `kubectl -n zot get pod zot-0`.
3. `make deploy-registries`.
4. Check it is working: `kubectl -n monitoring` / VictoriaMetrics `zot_http_requests_total` by status code, and
   `kubectl -n zot exec zot-0 -- ls /var/lib/registry` shows the mirror prefixes appearing as images are pulled.

**Resizing the volume.** A StatefulSet's `volumeClaimTemplate` is immutable, so changing `pvc.storage` in `apps/zot/values.yaml` alone makes
Argo's sync fail on an existing install. Expand the live claim, then let Argo recreate the StatefulSet around it:
```bash
kubectl -n zot patch pvc zot-pvc-zot-0 -p '{"spec":{"resources":{"requests":{"storage":"40Gi"}}}}'   # Longhorn expands it
kubectl -n zot delete statefulset zot --cascade=orphan       # keeps the pod and the volume; Argo recreates the StatefulSet
```
(While it only holds the self-built operator image you can instead delete the claim and re-run `make build-proxysql-operator`.)

**Pushing a self-built image**: `make build-proxysql-operator` (`scripts/build-proxysql-operator.sh`). It clones the operator's release
tag, cross-compiles the manager for linux/arm64, appends it as one layer onto upstream's distroless base with the same `/manager`
entrypoint and nonroot user, and pushes through `kubectl port-forward svc/zot`. No Docker daemon; needs `git`, `go`, `kubectl` and
`crane` (`brew install crane`). Re-run it when the operator chart's `targetRevision` moves.

**No auth**: any pod can push to or pull from Zot. Fine for a homelab cache and self-built images; add Zot's htpasswd auth and an
imagePullSecret before storing anything sensitive. Its NetworkPolicy allows DNS and HTTPS to the internet (outside the cluster's
private ranges) - the sync needs it.

**Back out**: delete the `k3s_registries` play from `site.yml`, remove `/etc/rancher/k3s/registries.yaml` from the nodes and restart k3s
on each (or leave Zot as is - without the file nothing uses it). To drop only the ProxySQL operator's image, remove the `image:` block from
`apps/proxysql-operator/values.yaml` once upstream publishes a public one.

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

**Prerequisite**: `temporal_db_password` must be set in Vault (`ansible-vault encrypt_string --stdin-name <name>`)
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
- **Trivy server (ClientServer mode)**: `operator.builtInTrivyServer: true` runs the chart's built-in `trivy-server`
  StatefulSet (5Gi Longhorn volume, 200m/512Mi requests, 1Gi limit) behind `trivy-service:4954`, and the scan Jobs
  query it instead of each downloading the vulnerability database. The default Standalone mode did the latter on
  every Job, and Jobs for multi-container pods (Grafana has four) fought over one database lock ("cache may be in use
  by another process: timeout"), failed, and were retried every 30s - re-downloading each time. That saturated a Pi
  4B's disk (~100% busy, 6-13 MB/s of writes, 33-62% iowait on `rpi-4b-3`). The server has no web UI of its own (it is
  an API: health, version, metrics); findings are viewed in Grafana (the Trivy dashboard the `grafana_dashboards`
  role imports) or with `kubectl get vulnerabilityreports`. If the server is down, scan Jobs fail and retry; nothing
  else in the cluster depends on it.
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
`apps/open-webui/`, namespace `open-webui`). Its LLM backend is the in-cluster
[Bifrost](#bifrost) gateway (`http://bifrost.bifrost.svc.cluster.local:8080/v1`), with no inference auth.
Provider keys live in Bifrost, not here; there is no Ollama and nothing credential-bearing in git.

- **Chart**: the official `open-webui/open-webui` chart (`helm.openwebui.com`) - unlike Homepage/SearXNG/
  WhoDB, this project does publish and maintain its own chart, so no `bjw-s-labs/app-template`
  fallback was needed. Chart 17.0.0 is the first stable release (it used to publish only per-commit `-dev`
  versions); its `image.tag` is still pinned explicitly (`v0.12.0`) rather than trusting the chart's `appVersion`.
  Moving from 0.11.4 to 0.12.0 was done on a wiped database (the old one was dropped, not migrated).
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
ansible-vault encrypt_string --stdin-name <name>
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
  - **Redis** (`WHODB_REDIS`, plain env in `values.yaml` - no auth): `blocky-cache` and `searxng-cache` (namespace `redis`), via
    each cluster's operator-maintained `-master` Service (failover-aware).
  - Postgres and OpenSearch profiles carry passwords, so they're in the `whodb-env` Secret, built from
    `whodb_postgres_profiles` / `whodb_opensearch_profiles` in `group_vars/all/cluster_secrets.yaml` and
    seeded by `k8s_secrets`. The Postgres password is the existing Vault variable `pgadmin_db_password`
    (name kept from the pgAdmin days).
- **WhoDB's own login**: none beyond picking a profile - the tailnet is the access control.
- **Redis caching**: WhoDB does not use Redis itself. Its only state is an encrypted session store
  (`/data`, 256Mi Longhorn PVC); there is no cache-backend setting.
- **Egress NetworkPolicy**: DNS, 5432 to `postgres`, 9200 to `opensearch`, 6379 to `redis`.

**Access it**: `https://whodb.<tailnet>.ts.net`.

**Migration note**: the old `pgadmin` DatabaseRole is replaced by `whodb`; the stale `pgadmin` Postgres role
may linger - drop it with `DROP ROLE pgadmin;` as `postgres`. The old `pgadmin-db-credentials` Secret in the
`postgres` namespace can be deleted too.

## Bifrost

An OpenAI-compatible gateway in front of LLM providers (`apps/bifrost/`, namespace `bifrost`): one endpoint
(`/v1`), a web UI for providers, keys, request logs and spend. Replaced LiteLLM. Deployed from Bifrost's official
Helm chart (classic repo `https://maximhq.github.io/bifrost/helm-charts`, allowed in the AppProject). The chart
requires an explicit image tag: `values.yaml` pins `image.tag` to `v2.2.5`, the latest gateway release - newer
than the chart's own (stale) `appVersion` 1.5.12. The chart's generated `config.json` was validated against the
current v2 schema (`https://www.getbifrost.ai/schema`); re-check that and re-pin both deliberately on bumps.

- **Database**: the cluster's CloudNativePG Postgres through `postgres-pooler-rw`, database/role `bifrost`
  (`apps/postgres/manifests/bifrost-database.yaml`), for both the config store and the request-log store.
- **Providers and keys**: added in the UI (stored encrypted in Postgres), not in git. Models are addressed as
  `<provider>/<model>`, e.g. `anthropic/claude-sonnet-5-5`.
- **Auth**: none in-app (`enforceAuthOnInference: false`), like the other UIs here - the Service is only
  reachable in-cluster or over Tailscale.
- **Metrics**: `/metrics` on the `http` port (8080), scraped by `apps/bifrost/manifests/vmservicescrape.yaml`.
- **Secrets** (seeded by `k8s_secrets` -> `make deploy-secrets`): `bifrost_db_password` and
  `bifrost_encryption_key`. Both are currently aliases in `group_vars/all/main.yaml` of the old vaulted
  `litellm_db_password` / `litellm_salt_key` (the encryption key is a 32-hex-char SHA-256 derivation); replace
  them with dedicated vault values if you like. **Never change the encryption key once providers are stored.**
- **Egress NetworkPolicy**: DNS, 5432 to `postgres`, and 443 to anywhere outside the private ranges (provider
  APIs, pricing sync).
- **Cache**: none. Bifrost's semantic cache needs a vector store with RediSearch, which the cluster's Redis does not have, so
  there is no response cache (a former idle `bifrost-cache` was removed).

**Use it**: open the UI, add a provider (e.g. Anthropic) with its API key, then point clients at
`http://bifrost.bifrost.svc.cluster.local:8080/v1` or `https://bifrost.<tailnet>.ts.net/v1`.

**Open WebUI** uses Bifrost as its only LLM backend (`openaiBaseApiUrl` in `apps/open-webui/values.yaml`,
in-cluster URL, plus an egress rule); its API key is a placeholder. Those values only seed Open WebUI's
connection on first start; afterwards edit it in Admin Settings -> Connections.

**Access it**: `https://bifrost.<tailnet>.ts.net`.

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
  lands in OpenSearch like everything else. Evaluation events are also emitted as log lines (the `log`
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

## Collision tracker

Finds news reports of motor-vehicle collisions involving pedestrians, cyclists and other vulnerable road users, extracts
structured facts with an LLM, merges reports of the same collision, and shows them on a map with trends and a review queue
(`apps/collision-tracker/`, namespace `collision-tracker`). The application, its Helm chart, design and runbooks live in
[joshdurbin/vulnerable_user_incident_tracking](https://github.com/joshdurbin/vulnerable_user_incident_tracking) (`docs/design.md`, `deploy/helm/collision-tracker`,
`docs/runbooks/`); this repo only holds the Argo CD Application and its values (`apps/collision-tracker/`) plus the pieces
that belong to the cluster.

- **Pieces**: `api` (Go REST API), `worker` (Go Temporal workflows and activities), `crawler` (Python Temporal worker that
  fetches and parses pages), `web` (nginx + React). Go and Python never call each other directly: they meet through
  Temporal task queues.
- **Postgres**: database `collisions`, role `collisions` (`apps/postgres/manifests/collisions-database.yaml`), through
  `postgres-pooler-rw` (session mode, so pgx prepared statements are safe). It needs **PostGIS**, so the shared cluster
  image (`apps/postgres/cluster/cluster.yaml`) is the CloudNativePG PostGIS variant: same PostgreSQL 18.6 and Debian 13,
  plus the extension files. The `Database` resource creates `postgis`, `pg_trgm`, `btree_gist` and `pgcrypto` because the
  role is not a superuser and PostGIS is not a trusted extension.
- **Temporal**: namespace `collisions` with 72 h retention (the app's database is the system of record, so history is
  disposable), and seven custom search attributes. A PreSync Job in the chart creates both, idempotently. Schedules (one per
  discovery source, plus a daily retention job) are kept in step with the configured sources by a PostSync Job (and by the
  admin UI whenever a source is saved) and keep any pause set in the Temporal UI.
- **Sources**: none are compiled in. On every start the API checks whether its database has any source and, only if it has
  none, loads a seed list (`COLLISION_SOURCES_SEED_FILE`; the image carries a starter set, `sources.seed` in the values
  replaces it, `sources.seedFile: ""` turns seeding off) and creates their schedules. After that sources and search queries
  are managed in the app's `/admin` page (admin token required) and the seed file is never read again. Deleting every source
  and restarting the API seeds again.
- **LLM**: through Bifrost (`bifrost.bifrost:8080/v1`) with an OpenRouter provider. Add the provider and key in Bifrost's UI,
  then set `llm.model` in `apps/collision-tracker/values.yaml`. The chart refuses to render until it is set.
- **Network**: egress-only NetworkPolicies per component. The worker and crawler may reach public HTTP(S) but never private
  ranges (a second layer behind the crawler's own SSRF guard); the API only reaches Postgres and Temporal.
- **Metrics and alerts**: `/metrics` on port 9100 of the api, worker and crawler, scraped by a `VMPodScrape`. The chart
  also ships a `VMRule` (stalled pipeline, failing sources, queue backlog, API errors) and a Grafana dashboard
  ConfigMap in `monitoring` (labelled for the Grafana sidecar).
- **Images**: built by the app repo's CI and pushed to `ghcr.io/joshdurbin/vulnerable_user_incident_tracking/{collisionctl,crawler,crawler-render,web}` (`crawler-render` is only used when `render.enabled`). The nodes
  pull through Zot, which must be able to read them: make the packages public or give Zot credentials. The Argo CD
  AppProject lists the app repo as a source; if it is private, Argo CD needs a repository credential for it.

**Secrets** (Vault variables in `group_vars/all/main.yaml`, seeded by `k8s_secrets` via `make deploy-secrets`):
| Variable | Used for |
|---|---|
| `collisions_db_password` | the `collisions` Postgres role (also embedded in the app's connection URL Secret) |
| `collisions_api_admin_token` | bearer token for review decisions and every `/admin` route (sources, queries, schedules); unset disables them |

Generate each with `openssl rand -hex 32` and add with `ansible-vault encrypt_string '<value>' --name <variable>`.
**Add both before `make deploy-secrets`**, or the play fails on an undefined variable.

**Order of operations for a first deploy**: add the Vault variables and run `make deploy-secrets`; merge the PostGIS image
change in a quiet window and wait for both Postgres instances to be healthy (`kubectl cnpg status postgres -n postgres`);
add the OpenRouter provider in Bifrost; set `llm.model`; let Argo CD sync the Application. Keep most sources disabled at first
and enable them as the pipeline proves itself (see the app's `docs/runbooks/deploy.md`).

**Access**: `https://collisions.<tailnet>.ts.net` (Tailscale Ingress, tailnet only). Dashboard: Grafana, folder "Collision
Tracker".

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

## Audio node and shairport-sync

`rpi-3bplus-1` (192.168.1.15) is a Pi 3B+ with 1GB RAM and an SD card - much slower and smaller than every other node - so it
is dedicated to one job: an AirPlay receiver playing to a USB audio device (`apps/shairport-sync/`, namespace
`shairport-sync`, `mikebrady/shairport-sync` classic/AirPlay 1).

How it is kept to that job:
- **Label** `audio_output=true` (`host_vars/rpi-3bplus-1.yaml`, applied by the `k8s_labels` role) says what the node is for;
  shairport-sync selects on it.
- **Taint** `dedicated=audio:NoSchedule` is what keeps everything else off. It is set with `--node-taint` when the k3s
  agent first registers, so there is no window for other pods to land first. It also blocks DaemonSets, so Longhorn
  and servicelb never run there. The only things that tolerate it are node-exporter
  (`apps/victoria-metrics/values.yaml`), Vector (`apps/opensearch/values-vector.yaml`) and shairport-sync.
- k3s's own pieces (kubelet, containerd, kube-proxy, Flannel) are part of the agent process, not pods, so the base set is
  agent + node-exporter + Vector + shairport-sync. No Longhorn host packages (`site.yml` skips `[audio]`).
- To change the taint on an already-joined node, use `kubectl taint`; `--node-taint` only applies at registration.

shairport-sync runs `hostNetwork` (mDNS discovery and the stream come straight from the sender), `Recreate` strategy
(one USB device, one owner), privileged for `/dev/snd`. It outputs to ALSA `hw:CARD=AUDIO` (the USB DAC, by name, since its card number changes once the onboard audio is
disabled). Vector tolerates the taint, so logs ship to OpenSearch like everywhere else; its 256Mi
request is the heaviest item on the 1GB node besides the k3s agent. Tailscale is installed on the host (the `pi3` board
group is in that play).

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
  pods are free to move; only Longhorn's *replica data* is pinned (`storage=true`: `rpi-5-1`, `rpi-5-5`).
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
| VictoriaMetrics (vminsert, vmstorage, vmselect, vmagent) | 2 of each on different nodes + PDBs; vmstorage holds a full copy per pod (`replicationFactor: 2`), vmagents scrape independently and are de-duplicated. Ingestion and queries continue with either node out |
| Tailscale ingress proxies | 2, required anti-affinity + PDB |
| Redis caches (2 clusters) | master/replica and the 3 sentinels each on different nodes, PDB `maxUnavailable: 1` (keeps sentinel quorum) |
| GO Feature Flag relay proxy | 2 replicas on different nodes + PDB + readiness probe; rolling update starts the new pod first |
| shairport-sync (audio node) | 1 replica, only schedulable on `rpi-3bplus-1`; a drain of that node stops AirPlay until it returns |
| Bifrost, Homepage | 1 replica each (stateless - state is in Postgres/Redis); a drain reschedules them, gaps of roughly 1-2 min, 30-90s and 10-30s (Pi start-up, plus an image pull on a node that hasn't run them) |

**Accepted blips** (single replica by design; recover when the pod reschedules, typically under a minute or two):
Blocky, Bifrost and Homepage, Open WebUI and WhoDB (RWO volume), SearXNG, Temporal (all services), (OpenSearch runs two data nodes with a replica of every index, as do Grafana, vmalert and Alertmanager),
Alertmanager (Vector buffers or retries), vmalert, Argo CD, and the other
operators. None are on a path that other workloads need to keep running.

**Known gaps** (not yet addressed):
- **CoreDNS** is a single replica managed by k3s - draining its node blips cluster-internal DNS. Scaling it with
  `kubectl scale` works but k3s can reset it on an upgrade; the durable fixes are disabling the k3s addon and
  running your own, or an Ansible step that re-asserts the replica count.
- **API endpoint**: agents, the Ansible-installed agent kubeconfig, and your laptop's kubeconfig point at the first
  server (`rpi-5-1`). While it is down, `kubectl` from those places fails - run it from another control-plane node.
  A stable endpoint (kube-vip / a DNS name over all three servers) would fix this.
- **LAN DNS clients** should be given at least two node IPs: Blocky is reachable on every node IP, and a rebooting
  node's IP stops answering.
- While a storage node (`rpi-5-1`/`rpi-5-5`) is out, every Longhorn volume has one replica until it returns.
- Control plane: `rpi-5-1/2/3` are the etcd members; one at a time keeps quorum (2 of 3).
- **Not yet verified on the live cluster**: the real write-outage time when the primary's node is drained. Test:
  run a write loop through `postgres-pooler-rw`, drain the primary's node, and measure the gap.

## Testing failover (Postgres, Redis)

Both fail over on their own (CloudNativePG for Postgres, Sentinel for the three Redis caches). These commands trigger
it on purpose, to rehearse or to check the apps ride through. Do one at a time and confirm health before the next.

**Postgres** (needs the `kubectl cnpg` plugin; the cluster is `postgres` in namespace `postgres`):
```bash
kubectl cnpg status postgres -n postgres                  # who is primary, replication state

# Planned switchover: clean, no data loss, the old primary becomes the replica
kubectl cnpg promote postgres <replica-instance> -n postgres        # e.g. postgres-2

# Crash simulation: kill the primary and let CNPG fail over
kubectl -n postgres delete pod <primary-instance>                   # add --grace-period=0 --force for a hard kill
watch kubectl cnpg status postgres -n postgres          # or re-run status until healthy
```
Done when `status` shows a healthy primary and a streaming replica again. The `postgres-rw` Service and the
`postgres-pooler-rw` PgBouncer follow the new primary on their own; apps reconnect without config changes. A failover
takes a few seconds to tens of seconds (`failoverDelay: 0`); a planned `promote` is quicker.

**Redis** (one shared Sentinel in `redis`; the caches are `blocky-cache` and `searxng-cache`,
and each Sentinel master group is named after its cache):
```bash
NS=redis
CACHE=blocky-cache                                        # or searxng-cache

# Which pod is master now (the redis-role label is maintained by the operator)
kubectl -n $NS get pods -l app=$CACHE,redis-role=master
kubectl -n $NS exec redis-sentinels-sentinel-0 -- redis-cli -p 26379 sentinel get-master-addr-by-name $CACHE

# Ask Sentinel to fail over to the replica
kubectl -n $NS exec redis-sentinels-sentinel-0 -- redis-cli -p 26379 sentinel failover $CACHE

# Crash simulation instead: delete the master pod
kubectl -n $NS delete pod $(kubectl -n $NS get pods -l app=$CACHE,redis-role=master -o name | cut -d/ -f2)
```
After a few seconds the `redis-role=master` label and `get-master-addr-by-name` point at the other pod. Blocky and
SearXNG discover the new master through Sentinel; the others use the operator-maintained `<name>-master`
Service. They need no change. Check `sentinel master $CACHE` shows `num-slaves 1` once the old master has rejoined as the
replica.

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
   ansible-vault encrypt_string --stdin-name <name>
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
| VictoriaMetrics | `https://victoriametrics.<tailnet>.ts.net/select/0/vmui/` |
| VictoriaLogs | scaled to zero (Ingress disabled) |
| Zot (image registry) | `https://zot.<tailnet>.ts.net` |
| OpenSearch Dashboards | `https://opensearch.<tailnet>.ts.net` |
| Longhorn | `https://longhorn.<tailnet>.ts.net` |
| Blocky (`/metrics`) | `https://blocky.<tailnet>.ts.net` |
| SearXNG | `https://search.<tailnet>.ts.net` |
| Temporal Web UI | `https://temporal.<tailnet>.ts.net` |
| Argo CD | `https://argocd.<tailnet>.ts.net` |
| Open WebUI | `https://chat.<tailnet>.ts.net` |
| WhoDB | `https://whodb.<tailnet>.ts.net` |
| Bifrost | `https://bifrost.<tailnet>.ts.net` |
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
3. `ansible-vault encrypt_string --stdin-name <name>`, add `tailscale_node_oauth_client_id` and
   `tailscale_node_oauth_client_secret`.

### Installation

```bash
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags tailscale
```

Or just run `make deploy` — it's part of the full playbook now.

**Deployed to:** Pi 3B+, Pi 4B and Pi 5 instances (`hosts: pi4,pi5,pi3` in `site.yml`) - every node in this
cluster's inventory.

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

Edit `group_vars/k3s_cluster/k3s.yaml` (shared by every server + agent node):

```yaml
k3s_version: v1.36.5+k3s1
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
ansible-vault encrypt_string --stdin-name <name>
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

`group_vars/all/main.yaml` is not an encrypted file but plain YAML with a separately encrypted value per secret, so there is no
whole-file `encrypt`/`decrypt`/`rekey`. Change one secret by encrypting the new value and pasting it over the old block:

```bash
printf '%s' '<new value>' | ansible-vault encrypt_string --stdin-name <name>
```

To change the vault PASSWORD itself, decrypt every value with the old one and re-encrypt it with the new one (each is its own block).

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
ansible localhost -e @group_vars/all/main.yaml --ask-vault-pass -m debug -a var=<name> --vault-password-file=<your-password-file>

ansible localhost -e @group_vars/all/main.yaml --ask-vault-pass -m debug -a var=<name>
```

## Advanced Commands

### Target Specific Groups

```bash
# Only run on k3s servers
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --limit server

# Only run on k3s agents
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --limit agent

# Only run on the Pi 4B nodes (limit by name: the pi4 group only exists once the run has started)
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --limit 'rpi-4b-*'
```

### K3S Management Playbooks

```bash
# Upgrade k3s: bump k3s_version in group_vars/k3s_cluster/k3s.yaml, then
# `make deploy` / `make deploy-k3s` leave a node alone when its k3s is already the target version and running
# (the vendored k3s-ansible roles reinstall and restart on every run, all servers at once); add `-e k3s_force=true`
# to the ansible-playbook call to run them on every node anyway.
make upgrade-k3s    # = ansible-playbook upgrade-k3s.yml -i inventory.dist --ask-vault-pass (roles/k3s_rolling_upgrade)
# Server settings (group_vars/server/main.yaml: disable traefik, secrets encryption, control-plane
# metrics): after changing them, `make reconfigure-k3s` restarts the servers one at a time and, with
# secrets-encryption on, re-encrypts the Secrets already stored in etcd.
# Checks the cluster is healthy, takes an etcd snapshot, then upgrades the servers and the
# agents ONE node at a time, waiting for each to be Ready on the new version and for Longhorn
# to be healthy again; stops if a node doesn't come back; skips nodes already on the target
# (safe to re-run). Don't use k3s-ansible/playbooks/upgrade.yml directly: it restarts every
# agent at once with no health checks.

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
