terraform {
  required_version = ">= 1.10"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.21"
    }
  }

  # Partial config: bucket/key/region/endpoint come from backend.hcl (see backend.hcl.example).
  backend "s3" {}
}
