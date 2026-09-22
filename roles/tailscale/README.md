# Tailscale Role

Deploys Tailscale VPN to enable secure remote access to Raspberry Pi cluster nodes.

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

```bash
# Enable Tailscale deployment (uncomment in site.yml)
# Then run full deployment
make deploy

# Or deploy Tailscale only
ansible-playbook tailscale_deploy.yml -i inventory.dist --ask-vault-pass
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
