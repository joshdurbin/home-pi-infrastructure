# The tailnet policy file (tags, grants/ACLs, ssh rules, autoApprovers). Kept as HuJSON in
# policy.hujson so comments survive and the file diffs cleanly.
#
# overwrite_existing_content is deliberately left false: the first apply refuses to clobber a
# live policy that hasn't been imported, which is the safe behaviour for a tailnet this repo
# didn't create. See README.md for the adoption order (export, import, plan, apply).
resource "tailscale_acl" "this" {
  acl = file("${path.module}/policy.hujson")
}
