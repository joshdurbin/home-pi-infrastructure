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

Works on **every** node, including agents. The script shells out to local `kubectl`, which needs a kubeconfig
at `/etc/rancher/k3s/k3s.yaml`. Servers have one natively; agent nodes (`rpi-4b-*`, `rpi-5-4`) don't run an API
server and used to have none, so `kubectl` there failed with `connection refused` against `localhost:8080`.
This role now installs a root-only (`0600`) kubeconfig on agents, copied from the first server and pointed at
its API (`k3s_server`, the endpoint agents already join through). Trade-offs, both deliberate:

- It is the **cluster-admin** kubeconfig, so a compromised agent could administer the cluster. Remove the two
  agent tasks in `tasks/main.yml` (and the file) if agents should stay credential-free.
- It pins the API endpoint to the first server. If that server is down, on-node `kubectl` fails until it's
  back - use your laptop or another server meanwhile.

The script drains **the node it runs on**: it takes the node name from the host's hostname (k3s names nodes
after the hostname; set `K3S_NODE_NAME` for a custom `--node-name`) and checks that node exists before
touching it. (Earlier versions drained the *first node in the cluster* regardless of where they ran.)

### Taking every node out, one at a time

`sudo k3s-maintenance -e` is built for this. Before it drains it:

1. **Refuses if another node is already cordoned** - finish and uncordon that one first.
2. **Refuses if any attached Longhorn volume isn't fully healthy** (a replica is still rebuilding), since draining
   a storage node then could take a volume's last good copy.
3. **Promotes a replica first if this node hosts a CloudNativePG primary**, for a clean switchover (with
   `kubectl cnpg promote`, installed by this role) and waits for it. This is a nicety, not a requirement: the
   Postgres `Cluster` has `enablePDB: false`, so a plain `kubectl drain` also works - CNPG fails over by itself
   (an abrupt failover: brief write interruption, connections cut). If there's no healthy replica on another
   schedulable node the script refuses rather than take the database down.
4. **Drains**, with no special cases. Draining is safe or blocked according to the cluster's own definitions,
   not exceptions in this script:
   - **Longhorn** (`nodeDrainPolicy: block-if-contains-last-replica`, `apps/longhorn/values.yaml`): its
     `instance-manager` PodDisruptionBudgets block a drain only if this node holds the *last healthy replica* of
     some volume. So any one storage node (`rpi-5-2` or `rpi-5-3`) can be drained while the other is healthy, and
     Longhorn itself refuses the second. (The old `block-for-eviction` made every node undrainable: it demanded
     replicas be moved to other nodes, and there are only two storage nodes.)
   - **Postgres** (`enablePDB: false`, `apps/postgres/cluster/cluster.yaml`): no budget on the primary.
   - Plain `kubectl drain --ignore-daemonsets --delete-emptydir-data <node>` therefore works too.

`sudo k3s-maintenance -d` uncordons and then **waits for Longhorn volumes to be healthy again**, so "done" means
the node is safe to follow with the next one. `--no-wait` skips that.

Flags: `-n/--dry-run` runs the checks and says what it would do without changing anything; `-f/--force`
skips checks 1 and 2.

The reboot play in `site.yml` still passes `--pod-selector 'longhorn.io/component!=instance-manager'` (written
for the old drain policy). With the current policy that exclusion is no longer needed and bypasses Longhorn's
last-replica protection; drop it if you'd rather the reboot play honour it.

To use the script, or to drain from your laptop or a server instead:

```bash
# Enable maintenance mode (drain node)
sudo k3s-maintenance -e

# Check status
sudo k3s-maintenance -s

# Disable maintenance mode (uncordon node)
sudo k3s-maintenance -d
```

## Reboot Workflow

For an **agent** node (`rpi-4b-*`) - `make drain`/`make uncordon` delegate to a server via Ansible, so this
works regardless of the target having its own kubeconfig:
```bash
# 1. Drain the node
make drain NODE=rpi-4b-1

# 2. Reboot (from control machine or node)
ssh ansible@rpi-4b-1 sudo reboot

# 3. Wait for reboot

# 4. Return to service
make uncordon NODE=rpi-4b-1
```

For a **server** node (`rpi-5-*`), the same commands work, but only reboot one at a time - rebooting
multiple control-plane nodes together risks etcd losing quorum. `site.yml`'s own "Reboot nodes with pending
config.txt changes" play already handles this correctly (`serial: 1`); do the same by hand here.

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
