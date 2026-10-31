#!/usr/bin/env bash
# Writes the tailnet's live policy file to terraform/tailscale/policy.hujson.
# Needs TAILSCALE_OAUTH_CLIENT_ID / TAILSCALE_OAUTH_CLIENT_SECRET (scope policy_file:read).
set -euo pipefail

out="$(dirname "$0")/../terraform/tailscale/policy.hujson"
: "${TAILSCALE_OAUTH_CLIENT_ID:?set TAILSCALE_OAUTH_CLIENT_ID}"
: "${TAILSCALE_OAUTH_CLIENT_SECRET:?set TAILSCALE_OAUTH_CLIENT_SECRET}"

token=$(curl -fsS https://api.tailscale.com/api/v2/oauth/token \
  -d "client_id=${TAILSCALE_OAUTH_CLIENT_ID}" \
  -d "client_secret=${TAILSCALE_OAUTH_CLIENT_SECRET}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

curl -fsS -H "Authorization: Bearer ${token}" -H 'Accept: application/hujson' \
  https://api.tailscale.com/api/v2/tailnet/-/acl > "${out}.new"
mv "${out}.new" "${out}"
echo "wrote ${out}"
