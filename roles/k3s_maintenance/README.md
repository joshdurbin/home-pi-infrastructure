# K3S Maintenance Role

Deploys the k3s-maintenance utility script to all k3s cluster nodes for safe node maintenance and reboots.

## What It Does

- Copies k3s-maintenance script to `/usr/local/bin/k3s-maintenance`
- Makes script executable and owned by root

## Script Features

The k3s-maintenance script provides:
- Node draining (evict workloads before maintenance)
- Node uncordoning (return to service after maintenance)
- Maintenance state tracking (when nodes were drained/returned)
- Safe reboot workflow

## Usage

```bash
# Deploy maintenance tools to cluster
make deploy-maintenance

# Or via Ansible directly
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags maintenance
```

## Using the Maintenance Script

**Server nodes only** — the script shells out to local `kubectl`, which only has a working kubeconfig on
server nodes (`/etc/rancher/k3s/k3s.yaml`). Agent nodes (the `pi5` group) have the `kubectl` binary but no
kubeconfig, so running this there fails with a connection-refused error against `localhost:8080`. To
drain/uncordon an *agent* node, run the commands below from a server node, targeting the agent by name —
see the "Reboot nodes with pending config.txt changes" play in `site.yml` for a worked example of exactly
this (drain/uncordon delegated to a server, targeting any node by `inventory_hostname`).

```bash
# Enable maintenance mode (drain node)
sudo k3s-maintenance -e

# Check status
sudo k3s-maintenance -s

# Disable maintenance mode (uncordon node)
sudo k3s-maintenance -d
```

## Reboot Workflow

```bash
# 1. Drain the node
make drain NODE=rpi-5-1

# 2. Reboot (from control machine or node)
ssh ansible@rpi-5-1 sudo reboot

# 3. Wait for reboot

# 4. Return to service
make uncordon NODE=rpi-5-1
```

## State File

The script maintains state in `/var/lib/k3s-maintenance.state`:

```json
{
  "in_maintenance": false,
  "enabled_at": "2026-09-18T15:30:00.123456",
  "disabled_at": "2026-09-18T15:45:00.654321",
  "node_name": "rpi-5-1"
}
```

This file:
- Persists across reboots
- Tracks maintenance duration
- Can be inspected for audit/logging

## Tags

- `maintenance` - Deploy maintenance tools
- `k3s` - Included in full k3s deployment

## Dependencies

- Python 3.6+
- A working local kubeconfig — present on server nodes only, not agents (see above)
- Proper RBAC permissions to drain/uncordon nodes

## Notes

- Script runs locally on each node (not dependent on Ansible during use)
- Idempotent - safe to run multiple times
- State file is local to each node
- Script uses kubectl to interact with Kubernetes API
