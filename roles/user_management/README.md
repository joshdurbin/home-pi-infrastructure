# User Management Role

Manages system users with SSH key authentication and passwordless sudo access.

## What It Does

- Creates system users with no password (SSH key auth only)
- Configures SSH public keys for authentication
- Adds users to specified groups
- Configures passwordless sudo for `adm` group members

## Configuration

Edit `roles/user_management/defaults/main.yml`:

```yaml
managed_users:
  - username: jdurbin
    groups:
      - adm
    ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKO2h8..."
  - username: other_user
    groups:
      - adm
      - sudo
    ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxx..."
```

## Variables

- `managed_users` - List of users to create (see defaults/main.yml)
  - `username` - Login name
  - `groups` - List of groups to add user to
  - `ssh_public_key` - SSH public key for authentication

## User Properties

- **No Password Login**: Password set to `!` (invalid hash)
- **SSH Key Only**: Authenticated via SSH public key
- **Passwordless Sudo**: Users in `adm` group can run `sudo` without password

## Common Groups

- `adm` - Full passwordless sudo access
- `sudo` - Standard sudo group (requires password)
- `docker` - Docker access (if installed)
- `video` - GPU/video device access
- `dialout` - Serial port access

## Tags

- `user_management` - Run all user management tasks

## Dependencies

- None (uses built-in Ansible modules)

## Usage

```bash
# Deploy user management only
make deploy-users

# Or via Ansible directly
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags user_management
```

## Adding Users

1. Edit `roles/user_management/defaults/main.yml`
2. Add new user to `managed_users` list
3. Run deployment: `make deploy-users`

## Removing Users

1. Remove from `managed_users` list in defaults/main.yml
2. Manually delete if needed: `sudo userdel -r username`

## Important Notes

- The `ansible` user is NOT managed by this role
- Changes only apply when playbook runs
- SSH keys are added via `authorized_keys`
- Idempotent - safe to run multiple times
