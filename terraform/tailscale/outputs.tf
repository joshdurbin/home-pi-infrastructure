output "k8s_operator_oauth_client_id" {
  value = tailscale_oauth_client.k8s_operator.id
}

output "pi_node_oauth_client_id" {
  value = tailscale_oauth_client.pi_node.id
}
