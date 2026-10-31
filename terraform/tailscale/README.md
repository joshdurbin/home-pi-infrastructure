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

## OAuth clients

Both existing clients are adopted with `import` blocks in `imports.tf`, so nothing is
re-created and the secrets already in ansible-vault stay valid (the API never returns a
secret, so state holds none; `ignore_changes = [key]`). `scopes`, `tags` and `description`
must match the live clients exactly: a plan that shows a *replace* would destroy the client
and its secret, so never apply one. Fix `oauth.tf` until the plan is clean.

`acls_externally_managed_on = true` blocks console edits to the policy; change it in
`settings.tf` if you'd rather keep the console editable.
