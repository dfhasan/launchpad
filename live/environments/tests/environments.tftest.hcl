# Offline tests (no AWS account needed):  tofu init -backend=false && tofu test
# Providers are mocked; the platform layer's outputs are faked.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/lp-mock" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-central-1:111111111111:targetgroup/lp-mock/abc"
      arn_suffix = "targetgroup/lp-mock/abc"
    }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:eu-central-1:111111111111:task-definition/lp-mock:1" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-central-1:111111111111:log-group:/launchpad/mock" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address            = "db.internal"
      port               = 3306
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:eu-central-1:111111111111:secret:db", kms_key_id = "", secret_status = "active" }]
    }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:eu-central-1:111111111111:parameter/launchpad/x/APP_KEY" }
  }
}
mock_provider "random" {}
mock_provider "cloudflare" {}

override_data {
  target = data.terraform_remote_state.platform
  values = {
    outputs = {
      region                  = "eu-central-1"
      vpc_id                  = "vpc-123"
      public_subnet_ids       = ["subnet-a", "subnet-b"]
      private_subnet_ids      = ["subnet-c", "subnet-d"]
      cluster_name            = "launchpad"
      cluster_arn             = "arn:aws:ecs:eu-central-1:111111111111:cluster/launchpad"
      alb_dns_name            = "launchpad-123.eu-central-1.elb.amazonaws.com"
      alb_arn_suffix          = "app/launchpad/abc"
      listener_arn            = "arn:aws:elasticloadbalancing:eu-central-1:111111111111:listener/app/launchpad/abc/def"
      tasks_security_group_id = "sg-123"
      ecr_repository_urls     = { safebrief = "111111111111.dkr.ecr.eu-central-1.amazonaws.com/safebrief" }
    }
  }
}

variables {
  state_bucket = "test-bucket"
}

run "golden_path_defaults" {
  command = plan
  variables { environments_dir = "./tests/fixtures/good" }

  assert {
    condition     = length(module.env) == 2
    error_message = "Each YAML file should become one environment"
  }
  assert {
    condition     = module.env["web-dev"].service_names == ["web-dev-web"]
    error_message = "A default env runs only the web service (no worker)"
  }
  assert {
    condition     = length(module.env["web-dev"].service_names) == 1 && length(module.env["web-prod"].service_names) == 2
    error_message = "worker: true should add a queue worker service"
  }
}

run "primary_route_is_evaluated_last" {
  command = plan
  variables { environments_dir = "./tests/fixtures/good" }

  assert {
    condition     = strcontains(output.environments["web-dev"].url, "launchpad-123") && !strcontains(output.environments["web-dev"].url, "X-Launchpad-Env")
    error_message = "Primary env should be reachable on the bare ALB address"
  }
  assert {
    condition     = strcontains(output.environments["web-prod"].url, "X-Launchpad-Env: web-prod")
    error_message = "Non-primary envs without a domain are routed by header"
  }
}

run "domain_gives_hostnames" {
  command = plan
  variables {
    environments_dir = "./tests/fixtures/good"
    base_domain      = "dev.example.com"
  }
  assert {
    condition     = output.environments["web-prod"].url == "https://web-prod.dev.example.com"
    error_message = "With a base domain every env gets <name>.<domain>"
  }
}

run "sqlite_with_worker_is_rejected" {
  command = plan
  variables { environments_dir = "./tests/fixtures/sqlite-worker" }
  expect_failures = [terraform_data.validate]
}

run "unknown_app_is_rejected" {
  command = plan
  variables { environments_dir = "./tests/fixtures/unknown-app" }
  expect_failures = [terraform_data.validate]
}
