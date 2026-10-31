# Adopt the existing OAuth clients so their secrets (already in ansible-vault) stay valid.
import {
  to = tailscale_oauth_client.pi_node
  id = "k4RHYfBXBq11CNTRL"
}

import {
  to = tailscale_oauth_client.k8s_operator
  id = "kcPhrJkNAG11CNTRL"
}
