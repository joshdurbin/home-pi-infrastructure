# Two deliberately separate OAuth clients (least privilege): a leaked node-join credential
# must not also be able to act as the Kubernetes operator, and vice versa. See
# roles/tailscale/defaults/main.yml and apps/tailscale-operator/.
#
# The client secrets land in Terraform state, so the state backend must be encrypted and
# access-restricted. Clients adopted via import have no secret in state (the API never returns it).

# Kubernetes operator (consumed by roles/cluster_secrets as tailscale_oauth_client_*).
resource "tailscale_oauth_client" "k8s_operator" {
  description = "ansible"
  scopes      = ["devices:core", "auth_keys", "services"]
  tags        = ["tag:k8s-operator"]

  depends_on = [tailscale_acl.this]

  lifecycle {
    ignore_changes = [key]
  }
}

# Node join (consumed by roles/tailscale as tailscale_node_oauth_client_*): mints one-time
# auth keys for tag:pi-node.
resource "tailscale_oauth_client" "pi_node" {
  description = "pi-host-daemon"
  scopes      = ["auth_keys"]
  tags        = ["tag:pi-node"]

  depends_on = [tailscale_acl.this]

  lifecycle {
    # Imported: the API never returns the secret, so state holds none. It lives in ansible-vault.
    ignore_changes = [key]
  }
}
