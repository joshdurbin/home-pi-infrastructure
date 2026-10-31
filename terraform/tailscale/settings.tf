resource "tailscale_tailnet_settings" "this" {
  # Required for valid .ts.net HTTPS certs (the operator's Ingresses and the proxies'
  # `tailscale cert`); see "One-time tailnet setup" in docs/REFERENCE.md.
  https_enabled = true

  # Keep nodes patched automatically: the Tailscale SSH fixes shipped in 1.104.4 only
  # help if clients actually update.
  devices_auto_updates_on = true

  # The policy file is owned by this repo; stop console edits drifting from it.
  acls_externally_managed_on = true
  acls_external_link         = "https://github.com/joshdurbin/home-pi-infrastructure/tree/master/terraform/tailscale"

  depends_on = [tailscale_acl.this]
}

resource "tailscale_dns_preferences" "this" {
  magic_dns = true
}
