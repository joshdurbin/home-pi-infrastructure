# Two deliberately separate OAuth clients (least privilege): a leaked node-join credential
# must not also be able to act as the Kubernetes operator, and vice versa. See
# roles/tailscale/defaults/main.yml and apps/tailscale-operator/.
#
# The client secrets land in Terraform state, so the state backend must be encrypted and
# access-restricted. Copy them into ansible-vault with `make tf-oauth-secrets`.

# Kubernetes operator (consumed by roles/cluster_secrets as tailscale_oauth_client_*).
resource "tailscale_oauth_client" "k8s_operator" {
  description = "k8s operator"
  scopes      = ["devices:core", "auth_keys", "services"]
  tags        = ["tag:k8s-operator"]

  depends_on = [tailscale_acl.this]
}

# Node join (consumed by roles/tailscale as tailscale_node_oauth_client_*): mints one-time
# auth keys for tag:pi-node.
resource "tailscale_oauth_client" "pi_node" {
  description = "pi node join"
  scopes      = ["auth_keys"]
  tags        = ["tag:pi-node"]

  depends_on = [tailscale_acl.this]
}
