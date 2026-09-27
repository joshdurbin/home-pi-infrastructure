# Tailscale Role

Deploys Tailscale VPN to enable secure remote access to Raspberry Pi cluster nodes.

**Not the same thing as `apps/tailscale-operator`** — that one runs the Tailscale *Kubernetes Operator*
in-cluster to expose specific web UIs (Grafana, Longhorn, etc.) at tailnet-only HTTPS hostnames. This role
installs the Tailscale *client* directly on each Pi's OS, for VPN/SSH access to the node itself. See the
main README's "Exposing UIs via Tailscale Operator" section for that one.

## What It Does

- Adds Tailscale GPG key and repository
- Installs tailscale package
- Enables and starts tailscaled service
- Joins the tailnet automatically, non-interactively, if not already connected (see below) — no manual
  `tailscale up` needed

## One-time setup (before first deploy)

Node-level joins use a **dedicated** OAuth client — deliberately separate from the one
`apps/tailscale-operator/` uses (see the main README's "Exposing UIs via Tailscale Operator" section),
least-privilege: a leaked node-join credential shouldn't also be able to act as the Kubernetes operator,
and vice versa.

1. **Create the OAuth client** — Tailscale admin console → Settings → OAuth clients → Generate. `write`
   scope for **Auth Keys** only. Tag: `tag:pi-node`.

2. **Add the tag to your ACL** — Settings → Access Controls, merge in:
   ```json
   "tagOwners": {
     "tag:pi-node": []
   }
   ```

3. **Store the credentials in Vault:**
   ```bash
   ansible-vault edit group_vars/all/main.yaml
   ```
   ```yaml
   tailscale_node_oauth_client_id: "<client ID from step 1>"
   tailscale_node_oauth_client_secret: "<client secret from step 1>"
   ```

## How the automatic join works

On every run, this role checks `tailscale status --json` first. If the node isn't already connected
(`BackendState` isn't `"Running"`), it:
1. Exchanges the OAuth client credentials for a short-lived API access token
   (`POST /api/v2/oauth/token`).
2. Mints a **one-time, non-ephemeral** auth key tagged `tag:pi-node`, pre-authorized, expiring in 5 minutes
   (`POST /api/v2/tailnet/-/keys`) — long enough for this same playbook run to consume it, short enough
   that a leaked/unused key is worthless shortly after.
3. Runs `tailscale up --authkey=... --hostname={{ inventory_hostname }}` locally.

Already-connected nodes skip all of this — no new key gets minted on every routine `make deploy`.

## Usage

```bash
# Full deployment (includes Tailscale)
make deploy

# Or just this role, via its tag
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags tailscale
```

## Accessing Nodes

Once authenticated:

```bash
# Via Tailscale IP (from any device on your Tailscale network)
ssh ansible@100.x.x.x

# Or by hostname
ssh ansible@rpi-4b-1
```

## Targets

- **Included**: Pi4 and Pi5 instances (`hosts: pi4,pi5` in `site.yml`) - every node currently in this
  cluster's inventory.

## Tags

- `tailscale` - Run Tailscale deployment

## Dependencies

- Internet connectivity
- Tailscale account (free for up to 100 devices)
- `tailscale_node_oauth_client_id` / `tailscale_node_oauth_client_secret` in Vault (see One-time setup above)

## Advanced Features

**Subnet Router** - Route home network through a Tailscale node:
```bash
sudo tailscale up --advertise-routes=192.168.1.0/24
```

**Exit Node** - Route internet traffic through a Tailscale node:
```bash
sudo tailscale up --advertise-exit-node
```

## Troubleshooting

```bash
# Check service status
sudo systemctl status tailscaled

# View logs
sudo journalctl -u tailscaled -f

# See network status
sudo tailscale status

# Logout (remove from network)
sudo tailscale logout
```

## Security

- All traffic encrypted with WireGuard
- Authentication via Tailscale account
- ACLs available in Tailscale admin panel
- Keys expire after 180 days by default

## Notes

- Idempotent - safe to run multiple times; the join step is skipped entirely once a node is connected
- Free tier includes up to 100 devices
