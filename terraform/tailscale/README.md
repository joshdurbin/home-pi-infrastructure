# Tailscale tailnet as code

Manages the tailnet itself (the parts Ansible and Argo CD can't see): the policy file,
tailnet settings, MagicDNS, and the two OAuth clients the repo consumes.

| File | Manages |
|---|---|
| `policy.hujson` / `acl.tf` | Policy file: tags, access rules, `ssh`, `autoApprovers` |
| `settings.tf` | HTTPS certs, device auto-updates, MagicDNS, console-edit lock |
| `oauth.tf` | `tag:k8s-operator` client (operator) and `tag:pi-node` client (node join) |

## Credentials

Export an OAuth client with scopes `policy_file`, `oauth_keys`, `feature_settings`, `dns`
(not one of the two it manages) before running anything:

```bash
export TAILSCALE_OAUTH_CLIENT_ID=... TAILSCALE_OAUTH_CLIENT_SECRET=...
```

State is in S3 (`backend.hcl`, gitignored; copy `backend.hcl.example`). The OAuth client
secrets are stored in state, so the bucket must be encrypted and private.

## Adopting the existing tailnet (first time)

WARNING: `policy.hujson` ships as a starter. Applying it unchanged would replace your live
policy and drop every rule not in it.

1. `make tf-init`
2. `make tf-export-policy` - overwrites `policy.hujson` with the live policy; review the diff.
3. `terraform -chdir=terraform/tailscale import tailscale_acl.this acl`
4. `make tf-plan` - the ACL should show no change. Fix `policy.hujson` until it does.
5. `make tf-apply`

## OAuth clients and ansible-vault

`oauth.tf` creates *new* clients; the ones already in `group_vars/all/main.yaml` are not
imported (their secrets can't be recovered). After apply, `make tf-oauth-secrets`, re-encrypt
the values with `ansible-vault encrypt_string` into `tailscale_oauth_client_*` and
`tailscale_node_oauth_client_*`, run `make deploy-secrets`, then delete the old clients in
the admin console.

`acls_externally_managed_on = true` blocks console edits to the policy; change it in
`settings.tf` if you'd rather keep the console editable.
