# Home Pi Infrastructure

A k3s Kubernetes cluster on a mix of Raspberry Pi 4s and 5s. Ansible handles the bare-metal and cluster
bootstrap; Argo CD handles everything that runs inside the cluster.

For the deeper "why" behind any of this — architecture notes, per-app config, troubleshooting — see
[docs/REFERENCE.md](docs/REFERENCE.md). This file is just the steps to get it running.

## Hardware

- Control plane: 3x Raspberry Pi 4B — `rpi-4b-1`, `rpi-4b-2`, `rpi-4b-3`
- Workers: 3x Raspberry Pi 5 — `rpi-5-1`, `rpi-5-2`, `rpi-5-3`

## Setup (one time)

1. Clone and pull submodules:
   ```bash
   git clone https://github.com/joshdurbin/home-pi-infrastructure.git
   cd home-pi-infrastructure
   git submodule update --init --recursive
   ```

2. Edit `inventory.dist` with your node IPs.

3. Install Ansible collections:
   ```bash
   make install
   ```

4. Set up Tailscale (needed before deploying) — **two** separate OAuth clients, least-privilege (one lets
   nodes join the tailnet, the other lets the in-cluster operator expose UIs; a leaked credential for one
   shouldn't work for the other):
   - **Node-join client**: Tailscale admin console → Settings → OAuth clients → Generate. Scope: `write`
     for **Auth Keys** only. Tag: `tag:pi-node`.
   - **Operator client**: Generate another. Scope: `write` for Services, Devices Core, and Auth Keys. Tag:
     `tag:k8s-operator`.
   - Settings → Access Controls, merge into your policy:
     ```json
     "tagOwners": {
       "tag:pi-node": [],
       "tag:k8s-operator": [],
       "tag:k8s": ["tag:k8s-operator"]
     },
     "autoApprovers": { "services": { "tag:k8s": ["tag:k8s"] } }
     ```
   - Settings → enable "HTTPS Certificates".

5. Add secrets to Vault:
   ```bash
   ansible-vault edit group_vars/all/main.yaml
   ```
   ```yaml
   k3s_join_token: "<any random string>"
   tailscale_node_oauth_client_id: "<node-join client from step 4>"
   tailscale_node_oauth_client_secret: "<node-join client from step 4>"
   tailscale_oauth_client_id: "<operator client from step 4>"
   tailscale_oauth_client_secret: "<operator client from step 4>"
   searxng_secret_key: "<output of: openssl rand -hex 32>"
   ```

6. Deploy everything:
   ```bash
   make deploy
   ```

7. Check it worked:
   ```bash
   make status
   ```
   All nodes should show `Ready`, all Argo CD Applications `Synced`/`Healthy`.

From there, Longhorn (storage), VictoriaMetrics/VictoriaLogs/Grafana (monitoring), Blocky (DNS), SearXNG
(search), the redis-operator (Blocky's and SearXNG's own small caching clusters), RedisInsight (a UI for
browsing those caches), and the Tailscale Operator all come up on their own — Argo CD manages them from
this repo's `apps/` directory. See [docs/REFERENCE.md](docs/REFERENCE.md) for what each one does.

## Make targets

| Command | What it does |
|---|---|
| `make install` | Install required Ansible collections |
| `make deploy` | Run everything (`site.yml`) |
| `make deploy-system` | OS setup only (hardening, overclock, packages) |
| `make deploy-k3s` | k3s cluster install only |
| `make deploy-users` | User/SSH management only |
| `make deploy-secrets` | Seed cluster Secrets/ConfigMaps only |
| `make deploy-argocd` | Bootstrap Argo CD only |
| `make deploy-maintenance` | Deploy the k3s-maintenance script only |
| `make verify` | Node health + Argo CD Application status |
| `make status` | Node status + Argo CD Application status |
| `make logs` | Tail k3s logs from the first server |
| `make drain NODE=<name>` | Drain a node before maintenance |
| `make uncordon NODE=<name>` | Return a node to service |
| `make syntax-check` | Validate playbook syntax |
| `make lint` | Run `ansible-lint` |
| `make clean` | Remove local temp files |
| `make help` | Show this list |

## Accessing things

Once Tailscale is set up and synced:

| Service | URL |
|---|---|
| Argo CD | `https://argocd.<tailnet>.ts.net` |
| Grafana | `https://grafana.<tailnet>.ts.net` |
| Alertmanager | `https://alertmanager.<tailnet>.ts.net` |
| VictoriaMetrics | `https://victoriametrics.<tailnet>.ts.net` |
| Longhorn | `https://longhorn.<tailnet>.ts.net` |
| SearXNG | `https://search.<tailnet>.ts.net` |
| Blocky metrics | `https://blocky.<tailnet>.ts.net` |
| RedisInsight | `https://redisinsight.<tailnet>.ts.net` |

(Replace `<tailnet>` with your tailnet's `.ts.net` domain — run `tailscale status` on any connected device
to find it.)

DNS (Blocky) itself is plain LAN access, not Tailscale — point clients at any node's IP on port 53.

**kubectl from your own machine:**
```bash
ssh jdurbin@<a-server-ip> sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config_rpi
sed -i '' 's/127.0.0.1/<that-same-ip>/' ~/.kube/config_rpi
export KUBECONFIG=~/.kube/config_rpi
kubectl get nodes
```

## More detail

[docs/REFERENCE.md](docs/REFERENCE.md) covers: project structure, the GitOps split between Ansible and
Argo CD, per-app configuration (Longhorn, VictoriaMetrics/VictoriaLogs, Blocky, SearXNG, Tailscale
Operator), user management, node maintenance, and troubleshooting.
