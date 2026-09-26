# Tailscale Role

Deploys Tailscale VPN to enable secure remote access to Raspberry Pi cluster nodes.

**Not the same thing as `roles/tailscale_operator`** — that one runs the Tailscale *Kubernetes Operator*
in-cluster to expose specific web UIs (Grafana, Longhorn, etc.) at tailnet-only HTTPS hostnames. This role
installs the Tailscale *client* directly on each Pi's OS, for VPN/SSH access to the node itself. See the
main README's "Exposing UIs via Tailscale Operator" section for that one.

## What It Does

- Adds Tailscale GPG key and repository
- Installs tailscale package
- Enables and starts tailscaled service

## Configuration

After installation, each node must be authenticated:

```bash
ssh ansible@rpi-4b-1
sudo tailscale up
# Follow the login URL to authenticate
```

## Usage

There is no standalone playbook for this role — uncomment its play in `site.yml` first, then:

```bash
# Full deployment (includes Tailscale once uncommented)
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

- **Included**: Pi4 and Pi5 instances
- **Excluded**: Pi 3B+

## Tags

- `tailscale` - Run Tailscale deployment

## Dependencies

- Internet connectivity
- Tailscale account (free for up to 100 devices)

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

- Currently commented out in site.yml (disabled by default)
- Idempotent - safe to run multiple times
- Nodes must be individually authenticated after installation
- Free tier includes up to 100 devices
