output "k8s_operator_oauth_client_id" {
  value = tailscale_oauth_client.k8s_operator.id
}

output "k8s_operator_oauth_client_secret" {
  value     = tailscale_oauth_client.k8s_operator.key
  sensitive = true
}

output "pi_node_oauth_client_id" {
  value = tailscale_oauth_client.pi_node.id
}

output "pi_node_oauth_client_secret" {
  value     = tailscale_oauth_client.pi_node.key
  sensitive = true
}
