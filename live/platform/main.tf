# Layer 1 — shared platform (changes rarely, owned by the platform team).

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # Filled at init time:  terraform init -backend-config=../backend.hcl
  backend "s3" {
    key          = "platform/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "launchpad", managed_by = "terraform", layer = "platform" }
  }
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  type    = string
  default = "launchpad"
}

variable "apps" {
  type    = set(string)
  default = ["safebrief"]
}

variable "certificate_arn" {
  type    = string
  default = null
}

variable "restrict_to_cloudflare" {
  description = "Only accept ALB traffic from Cloudflare's IP ranges (use once DNS is proxied)."
  type        = bool
  default     = false
}

# Cloudflare's published IPv4 ranges (https://www.cloudflare.com/ips-v4/)
locals {
  cloudflare_ipv4 = [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
  ]
}

module "network" {
  source = "../../modules/network"
  name   = var.name
}

module "platform" {
  source                = "../../modules/platform"
  name                  = var.name
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  apps                  = var.apps
  certificate_arn       = var.certificate_arn
  allowed_ingress_cidrs = var.restrict_to_cloudflare ? local.cloudflare_ipv4 : ["0.0.0.0/0"]
}

output "region" { value = var.region }
output "vpc_id" { value = module.network.vpc_id }
output "public_subnet_ids" { value = module.network.public_subnet_ids }
output "private_subnet_ids" { value = module.network.private_subnet_ids }
output "cluster_name" { value = module.platform.cluster_name }
output "cluster_arn" { value = module.platform.cluster_arn }
output "alb_dns_name" { value = module.platform.alb_dns_name }
output "alb_arn_suffix" { value = module.platform.alb_arn_suffix }
output "listener_arn" { value = module.platform.listener_arn }
output "tasks_security_group_id" { value = module.platform.tasks_security_group_id }
output "ecr_repository_urls" { value = module.platform.ecr_repository_urls }
