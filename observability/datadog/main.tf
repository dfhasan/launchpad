# Layer 3 — observability as code.
# Golden signals for every environment, generated from the same env list:
# a shared dashboard + per-env monitors (5xx rate, latency, running tasks).
# Datadog's free plan is enough for this (AWS integration, monitors, 1-day retention).

terraform {
  required_version = ">= 1.10"
  required_providers {
    datadog = { source = "datadog/datadog", version = "~> 3.75" }
  }
  backend "s3" {
    key          = "observability/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

variable "state_bucket" { type = string }
variable "region" {
  type    = string
  default = "eu-central-1"
}
variable "datadog_api_url" {
  type    = string
  default = "https://api.datadoghq.eu/"
}
variable "notify" {
  description = "Datadog notification handle, e.g. @slack-platform-alerts or @you@example.com"
  type        = string
  default     = ""
}

provider "datadog" {
  api_url = var.datadog_api_url
  # api_key / app_key from DD_API_KEY / DD_APP_KEY environment variables
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "platform/terraform.tfstate", region = var.region }
}

data "terraform_remote_state" "envs" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "environments/terraform.tfstate", region = var.region }
}

locals {
  alb     = data.terraform_remote_state.platform.outputs.alb_arn_suffix
  cluster = data.terraform_remote_state.platform.outputs.cluster_name
  tgs     = data.terraform_remote_state.envs.outputs.target_groups # env => targetgroup/xxx/yyy
  envs    = keys(local.tgs)
  lb_tag  = "loadbalancer:${lower(local.alb)}"
}

resource "datadog_monitor" "http_5xx" {
  for_each = local.tgs
  name     = "[launchpad] ${each.key}: 5xx error rate high"
  type     = "query alert"
  query    = "sum(last_10m):sum:aws.applicationelb.httpcode_target_5xx{${local.lb_tag},targetgroup:${lower(each.value)}}.as_count() / clamp_min(sum:aws.applicationelb.request_count{${local.lb_tag},targetgroup:${lower(each.value)}}.as_count(), 1) > 0.05"
  message  = <<-EOT
    More than 5% of requests to **${each.key}** return 5xx.
    Logs: CloudWatch group `/launchpad/${each.key}`. Runbook: docs/runbooks/high-5xx.md
    ${var.notify}
  EOT
  monitor_thresholds {
    critical = 0.05
    warning  = 0.02
  }
  notify_no_data = false
  tags           = ["platform:launchpad", "env:${each.key}"]
}

resource "datadog_monitor" "latency" {
  for_each = local.tgs
  name     = "[launchpad] ${each.key}: p95 latency above 1s"
  type     = "query alert"
  query    = "avg(last_10m):p95:aws.applicationelb.target_response_time.p95{${local.lb_tag},targetgroup:${lower(each.value)}} > 1"
  message  = "p95 latency for **${each.key}** is above 1s. ${var.notify}"
  monitor_thresholds {
    critical = 1
    warning  = 0.6
  }
  tags = ["platform:launchpad", "env:${each.key}"]
}

resource "datadog_monitor" "unhealthy_hosts" {
  for_each = local.tgs
  name     = "[launchpad] ${each.key}: no healthy targets"
  type     = "query alert"
  query    = "max(last_5m):max:aws.applicationelb.healthy_host_count{${local.lb_tag},targetgroup:${lower(each.value)}} < 1"
  message  = "**${each.key}** has no healthy tasks behind the ALB. Check ECS deployment events. ${var.notify}"
  monitor_thresholds {
    critical = 1
  }
  notify_no_data    = true
  no_data_timeframe = 20
  tags              = ["platform:launchpad", "env:${each.key}"]
}

resource "datadog_dashboard" "platform" {
  title       = "Launchpad — platform overview"
  layout_type = "ordered"
  description = "Golden signals for every self-service environment. Managed by Terraform — edit in Git, not in the UI."

  template_variable {
    name     = "env"
    prefix   = "targetgroup"
    defaults = ["*"]
  }

  widget {
    timeseries_definition {
      title = "Requests / min by environment"
      request {
        q            = "sum:aws.applicationelb.request_count{${local.lb_tag},$env} by {targetgroup}.as_count()"
        display_type = "bars"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Target 5xx by environment"
      request {
        q            = "sum:aws.applicationelb.httpcode_target_5xx{${local.lb_tag},$env} by {targetgroup}.as_count()"
        display_type = "bars"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "p95 latency (s)"
      request {
        q            = "avg:aws.applicationelb.target_response_time.p95{${local.lb_tag},$env} by {targetgroup}"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "ECS CPU % by service"
      request {
        q            = "avg:aws.ecs.service.cpuutilization{clustername:${local.cluster}} by {servicename}"
        display_type = "line"
      }
    }
  }

  widget {
    manage_status_definition {
      title        = "Monitors"
      query        = "tag:platform:launchpad"
      summary_type = "monitors"
      sort         = "status,asc"
    }
  }
}

output "dashboard_url" { value = datadog_dashboard.platform.url }
output "monitored_environments" { value = local.envs }
