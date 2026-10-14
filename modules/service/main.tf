# One self-service environment = one ECS service (+ optional queue worker,
# MySQL database, Cloudflare DNS record, Datadog agent sidecar).
# Callers never write this by hand: live/environments feeds it from YAML.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.7" }
  }
}

# ---------------- Inputs ----------------
variable "name" { type = string }
variable "app" { type = string }
variable "team" { type = string }
variable "image" { type = string }

variable "size" {
  type = string
  validation {
    condition     = contains(["small", "medium", "large"], var.size)
    error_message = "size must be small, medium or large."
  }
}

variable "replicas" { type = number }
variable "worker" { type = bool }
variable "spot" { type = bool }

variable "database" {
  type = string
  validation {
    condition     = contains(["sqlite", "mysql"], var.database)
    error_message = "database must be sqlite or mysql."
  }
}

variable "env" {
  type    = map(string)
  default = {}
}

variable "hostname" {
  description = "FQDN routed to this env. null = route by the X-Launchpad-Env header instead."
  type        = string
  default     = null
}

variable "primary" {
  description = "Catch-all route on the ALB (useful before you own a domain)."
  type        = bool
  default     = false
}

variable "listener_priority" { type = number }
variable "health_path" {
  type    = string
  default = "/up"
}

variable "region" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "db_subnet_ids" { type = list(string) }
variable "cluster_arn" { type = string }
variable "listener_arn" { type = string }
variable "tasks_security_group_id" { type = string }

variable "datadog_api_key_ssm_arn" {
  description = "When set, a Datadog agent sidecar is added and APM/log tags are wired."
  type        = string
  default     = null
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.eu"
}

locals {
  sizes = {
    small  = { cpu = 256, memory = 512 }
    medium = { cpu = 512, memory = 1024 }
    large  = { cpu = 1024, memory = 2048 }
  }
  cpu    = local.sizes[var.size].cpu
  memory = local.sizes[var.size].memory

  prefix   = "lp-${var.name}"
  datadog  = var.datadog_api_key_ssm_arn != null
  ssm_root = "/launchpad/${var.name}"

  # Unified service tagging (Datadog) + Laravel config.
  base_env = merge({
    APP_NAME                  = var.app
    APP_ENV                   = "production"
    APP_DEBUG                 = "false"
    APP_URL                   = var.hostname != null ? "https://${var.hostname}" : "http://localhost"
    LOG_CHANNEL               = "stderr"
    LOG_LEVEL                 = "info"
    DD_ENV                    = var.name
    DD_SERVICE                = var.app
    DD_VERSION                = element(split(":", var.image), length(split(":", var.image)) - 1)
    SESSION_DRIVER            = "database"
    CACHE_STORE               = "database"
    QUEUE_CONNECTION          = var.database == "mysql" ? "database" : "sync"
    DB_CONNECTION             = var.database
    AUTORUN_ENABLED           = "true"
    AUTORUN_LARAVEL_MIGRATION = "true"
    }, var.database == "mysql" ? {
    # Several web tasks may start at once: only one runs migrations (needs the cache lock table).
    AUTORUN_LARAVEL_MIGRATION_ISOLATION = "true"
    DB_HOST                             = module.db[0].host
    DB_PORT                             = tostring(module.db[0].port)
    DB_DATABASE                         = module.db[0].database
    DB_USERNAME                         = module.db[0].username
    } : {
    DB_DATABASE = "/var/www/html/database/database.sqlite"
  }, var.env)

  secrets = concat(
    [{ name = "APP_KEY", valueFrom = aws_ssm_parameter.app_key.arn }],
    var.database == "mysql" ? [{ name = "DB_PASSWORD", valueFrom = "${module.db[0].password_secret_arn}:password::" }] : [],
  )

  log_config = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.this.name
      awslogs-region        = var.region
      awslogs-stream-prefix = "app"
    }
  }

  datadog_container = local.datadog ? [{
    name      = "datadog-agent"
    image     = "public.ecr.aws/datadog/agent:7"
    essential = false
    cpu       = 0
    environment = [
      { name = "ECS_FARGATE", value = "true" },
      { name = "DD_SITE", value = var.datadog_site },
      { name = "DD_APM_ENABLED", value = "true" },
      { name = "DD_ENV", value = var.name },
      { name = "DD_TAGS", value = "team:${var.team} app:${var.app} platform:launchpad" },
    ]
    secrets          = [{ name = "DD_API_KEY", valueFrom = var.datadog_api_key_ssm_arn }]
    logConfiguration = local.log_config
  }] : []

  labels = {
    "com.datadoghq.tags.env"     = var.name
    "com.datadoghq.tags.service" = var.app
    "com.datadoghq.tags.version" = local.base_env.DD_VERSION
  }

  containers = {
    web = concat([{
      name         = "web"
      image        = var.image
      essential    = true
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]
      environment  = [for k, v in local.base_env : { name = k, value = v }]
      secrets      = local.secrets
      dockerLabels = local.labels
      healthCheck = {
        command     = ["CMD-SHELL", "curl -fsS http://localhost:8080${var.health_path} || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
      logConfiguration       = local.log_config
      readonlyRootFilesystem = false
    }], local.datadog_container)

    worker = concat([{
      name         = "worker"
      image        = var.image
      essential    = true
      command      = ["php", "/var/www/html/artisan", "queue:work", "--tries=3", "--max-time=3600"]
      environment  = [for k, v in merge(local.base_env, { AUTORUN_ENABLED = "false" }) : { name = k, value = v }]
      secrets      = local.secrets
      dockerLabels = local.labels
      logConfiguration = merge(local.log_config, {
        options = merge(local.log_config.options, { awslogs-stream-prefix = "worker" })
      })
    }], local.datadog_container)
  }
}

# ---------------- Guard rails ----------------
resource "terraform_data" "guards" {
  lifecycle {
    precondition {
      condition     = var.database == "mysql" || (var.replicas <= 1 && !var.worker)
      error_message = "${var.name}: sqlite lives inside one container — use replicas: 1 and worker: false, or database: mysql."
    }
    precondition {
      condition     = var.replicas >= 0 && var.replicas <= 6
      error_message = "${var.name}: replicas must be between 0 and 6."
    }
  }
}

# ---------------- Secrets ----------------
resource "random_bytes" "app_key" {
  length = 32
}

resource "aws_ssm_parameter" "app_key" {
  name  = "${local.ssm_root}/APP_KEY"
  type  = "SecureString"
  value = "base64:${random_bytes.app_key.base64}"
}

# ---------------- Database ----------------
module "db" {
  source                   = "../database"
  count                    = var.database == "mysql" ? 1 : 0
  name                     = local.prefix
  vpc_id                   = var.vpc_id
  subnet_ids               = var.db_subnet_ids
  client_security_group_id = var.tasks_security_group_id
}

# ---------------- IAM ----------------
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.prefix}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions = ["ssm:GetParameters"]
    resources = compact([
      aws_ssm_parameter.app_key.arn,
      var.datadog_api_key_ssm_arn,
    ])
  }
  dynamic "statement" {
    for_each = var.database == "mysql" ? [1] : []
    content {
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [module.db[0].password_secret_arn]
    }
  }
}

resource "aws_iam_role_policy" "read_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

# Runtime role for the app itself — empty on purpose (least privilege).
resource "aws_iam_role" "task" {
  name               = "${local.prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

# ---------------- Logs ----------------
resource "aws_cloudwatch_log_group" "this" {
  name              = "/launchpad/${var.name}"
  retention_in_days = 7
}

# ---------------- Task definitions ----------------
resource "aws_ecs_task_definition" "this" {
  for_each                 = var.worker ? toset(["web", "worker"]) : toset(["web"])
  family                   = "${local.prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.cpu
  memory                   = local.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode(local.containers[each.key])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

# ---------------- Routing ----------------
resource "aws_lb_target_group" "web" {
  name                 = trimsuffix(substr(local.prefix, 0, 32), "-")
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 15

  health_check {
    path                = var.health_path
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "web" {
  listener_arn = var.listener_arn
  priority     = var.listener_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  dynamic "condition" {
    for_each = var.hostname != null ? [1] : []
    content {
      host_header { values = [var.hostname] }
    }
  }

  dynamic "condition" {
    for_each = var.hostname == null && !var.primary ? [1] : []
    content {
      http_header {
        http_header_name = "X-Launchpad-Env"
        values           = [var.name]
      }
    }
  }

  dynamic "condition" {
    for_each = var.hostname == null && var.primary ? [1] : []
    content {
      path_pattern { values = ["/*"] }
    }
  }
}

# ---------------- Services ----------------
resource "aws_ecs_service" "this" {
  for_each               = aws_ecs_task_definition.this
  name                   = "${var.name}-${each.key}"
  cluster                = var.cluster_arn
  task_definition        = each.value.arn
  desired_count          = var.replicas
  enable_execute_command = false
  propagate_tags         = "SERVICE"

  capacity_provider_strategy {
    capacity_provider = var.spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.tasks_security_group_id]
    assign_public_ip = true # no NAT gateway; SG still only allows the ALB in
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = var.database == "sqlite" ? 0 : 100
  deployment_maximum_percent         = var.database == "sqlite" ? 100 : 200

  dynamic "load_balancer" {
    for_each = each.key == "web" ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.web.arn
      container_name   = "web"
      container_port   = 8080
    }
  }

  health_check_grace_period_seconds = each.key == "web" ? 90 : null

  lifecycle {
    ignore_changes = [desired_count] # owned by autoscaling after creation
  }

  depends_on = [aws_lb_listener_rule.web, terraform_data.guards]
}

# ---------------- Autoscaling (web) ----------------
resource "aws_appautoscaling_target" "web" {
  count              = var.database == "mysql" && var.replicas > 0 ? 1 : 0
  service_namespace  = "ecs"
  resource_id        = "service/${split("/", var.cluster_arn)[1]}/${aws_ecs_service.this["web"].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.replicas
  max_capacity       = var.replicas * 3
}

resource "aws_appautoscaling_policy" "cpu" {
  count              = length(aws_appautoscaling_target.web)
  name               = "${local.prefix}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.web[0].service_namespace
  resource_id        = aws_appautoscaling_target.web[0].resource_id
  scalable_dimension = aws_appautoscaling_target.web[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# ---------------- Outputs ----------------
output "service_names" { value = [for s in aws_ecs_service.this : s.name] }
output "target_group_arn_suffix" { value = aws_lb_target_group.web.arn_suffix }
output "log_group" { value = aws_cloudwatch_log_group.this.name }
output "hostname" { value = var.hostname }
