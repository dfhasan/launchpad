# Layer 2 — self-service environments.
# Every file in /environments/*.yaml becomes a running environment.
# Add a file in a PR  -> plan is posted on the PR -> merge -> it exists.
# Delete the file     -> the environment is destroyed.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    random     = { source = "hashicorp/random", version = "~> 3.7" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
  }
  backend "s3" {
    key          = "environments/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

variable "state_bucket" {
  description = "Bucket created by /bootstrap (same one passed in backend.hcl)"
  type        = string
}

variable "environments_dir" {
  description = "Override only in tests; defaults to /environments at the repo root."
  type        = string
  default     = null
}

variable "region" {
  description = "Region of the state bucket / platform layer"
  type        = string
  default     = "eu-central-1"
}

variable "base_domain" {
  description = "e.g. dev.example.com -> envs become <name>.dev.example.com. null = no domain."
  type        = string
  default     = null
}

variable "cloudflare_zone_id" {
  type    = string
  default = null
}

variable "cloudflare_api_token" {
  type      = string
  default   = null
  sensitive = true
}

variable "datadog_api_key_ssm_name" {
  description = "Name of an SSM SecureString holding the Datadog API key (enables the agent sidecar)."
  type        = string
  default     = null
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.eu"
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "platform/terraform.tfstate"
    region = var.region
  }
}

locals {
  p = data.terraform_remote_state.platform.outputs

  env_dir = coalesce(var.environments_dir, "${path.root}/../../environments")
  files   = fileset(local.env_dir, "*.yaml")
  raw     = { for f in local.files : trimsuffix(f, ".yaml") => yamldecode(file("${local.env_dir}/${f}")) }

  # Defaults = the golden path. Teams only override what they need.
  envs = { for k, e in local.raw : k => {
    name      = e.name
    app       = e.app
    team      = e.team
    owner     = e.owner
    image_tag = tostring(e.image_tag)
    size      = try(e.size, "small")
    replicas  = try(e.replicas, 1)
    database  = try(e.database, "sqlite")
    worker    = try(e.worker, false)
    spot      = try(e.spot, true)
    primary   = try(e.primary, false)
    expires   = try(tostring(e.expires), null)
    env       = { for ek, ev in try(e.env, {}) : ek => tostring(ev) }
  } }

  ordered = sort(keys(local.envs))
}

provider "aws" {
  region = local.p.region
  default_tags {
    tags = { project = "launchpad", managed_by = "terraform", layer = "environments" }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "aws_ssm_parameter" "datadog_api_key" {
  count = var.datadog_api_key_ssm_name != null ? 1 : 0
  name  = var.datadog_api_key_ssm_name
}

# Fail the plan early with a clear message instead of a cryptic AWS error.
resource "terraform_data" "validate" {
  for_each = local.envs
  lifecycle {
    precondition {
      condition     = each.value.name == each.key
      error_message = "environments/${each.key}.yaml: `name` must match the file name."
    }
    precondition {
      condition     = can(regex("^[a-z][a-z0-9-]{2,24}$", each.value.name))
      error_message = "${each.key}: name must be 3-25 chars, lowercase letters, digits and dashes."
    }
    precondition {
      condition     = contains(keys(local.p.ecr_repository_urls), each.value.app)
      error_message = "${each.key}: unknown app '${each.value.app}'. Register it in live/platform (var.apps) first."
    }
    precondition {
      condition     = each.value.database == "mysql" || (each.value.replicas <= 1 && !each.value.worker)
      error_message = "${each.key}: sqlite lives inside one container — use replicas: 1 and worker: false, or database: mysql."
    }
    precondition {
      condition     = length([for e in local.envs : e if e.primary]) <= 1
      error_message = "Only one environment can be primary."
    }
  }
}

module "env" {
  source   = "../../modules/service"
  for_each = local.envs

  name     = each.value.name
  app      = each.value.app
  team     = each.value.team
  image    = "${local.p.ecr_repository_urls[each.value.app]}:${each.value.image_tag}"
  size     = each.value.size
  replicas = each.value.replicas
  worker   = each.value.worker
  spot     = each.value.spot
  database = each.value.database
  env      = each.value.env
  primary  = each.value.primary
  hostname = var.base_domain != null ? "${each.value.name}.${var.base_domain}" : null

  # Primary (catch-all) must be evaluated last.
  listener_priority = each.value.primary ? 50000 : 100 + index(local.ordered, each.key) * 10

  region                  = local.p.region
  vpc_id                  = local.p.vpc_id
  subnet_ids              = local.p.public_subnet_ids
  db_subnet_ids           = local.p.private_subnet_ids
  cluster_arn             = local.p.cluster_arn
  listener_arn            = local.p.listener_arn
  tasks_security_group_id = local.p.tasks_security_group_id

  datadog_api_key_ssm_arn = var.datadog_api_key_ssm_name != null ? data.aws_ssm_parameter.datadog_api_key[0].arn : null
  datadog_site            = var.datadog_site

  depends_on = [terraform_data.validate]
}

module "dns" {
  source  = "../../modules/dns"
  count   = var.cloudflare_zone_id != null && var.base_domain != null ? 1 : 0
  zone_id = var.cloudflare_zone_id
  records = { for k, e in local.envs : "${e.name}.${var.base_domain}" => local.p.alb_dns_name }
}

output "environments" {
  value = { for k, m in module.env : k => {
    url = (m.hostname != null ? "https://${m.hostname}"
      : local.envs[k].primary ? "http://${local.p.alb_dns_name}"
    : "http://${local.p.alb_dns_name}  (send header X-Launchpad-Env: ${k})")
    services = m.service_names
    logs     = m.log_group
    owner    = local.envs[k].owner
    expires  = local.envs[k].expires
  } }
}

output "target_groups" {
  description = "Consumed by observability/datadog"
  value       = { for k, m in module.env : k => m.target_group_arn_suffix }
}
