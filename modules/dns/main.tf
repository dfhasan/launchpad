# Cloudflare in front of the ALB: proxied CNAME per environment
# (free plan: CDN, DDoS protection, edge TLS, WAF managed rules on paid plans).

terraform {
  required_version = ">= 1.10"
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
  }
}

variable "zone_id" { type = string }
variable "records" {
  description = "hostname => target (ALB DNS name)"
  type        = map(string)
}

resource "cloudflare_dns_record" "this" {
  for_each = var.records
  zone_id  = var.zone_id
  name     = each.key
  type     = "CNAME"
  content  = each.value
  proxied  = true
  ttl      = 1 # 1 = automatic (required when proxied)
  comment  = "managed by launchpad"
}

output "hostnames" { value = keys(cloudflare_dns_record.this) }
