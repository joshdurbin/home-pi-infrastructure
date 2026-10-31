# Credentials come from the environment, never from files in the repo:
#   TAILSCALE_OAUTH_CLIENT_ID / TAILSCALE_OAUTH_CLIENT_SECRET
# The client needs the policy_file, oauth_keys, and (for tailnet_settings) feature_settings scopes.
# The tailnet defaults to "-" (the one the credentials belong to).
provider "tailscale" {}
