# Shared platform layer that every environment plugs into:
# ECS cluster (Fargate / Fargate Spot), one shared ALB with host-based routing,
# ECR repositories, and the security group that app tasks attach to.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

variable "name" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }

variable "apps" {
  description = "Applications that get an ECR repository"
  type        = set(string)
  default     = []
}

variable "certificate_arn" {
  description = "Optional ACM certificate. When set, the ALB serves HTTPS and redirects HTTP."
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "Who can reach the ALB. Default is the internet; restrict to Cloudflare IP ranges when proxied."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------- ECS ----------------
resource "aws_ecs_cluster" "this" {
  name = var.name
  setting {
    name  = "containerInsights"
    value = "disabled" # enable in real prod; costs extra CloudWatch metrics
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ---------------- ECR ----------------
resource "aws_ecr_repository" "app" {
  for_each             = var.apps
  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------- Security groups ----------------
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ALB"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each          = { for pair in setproduct(var.allowed_ingress_cidrs, [80, 443]) : "${pair[0]}-${pair[1]}" => pair }
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value[0]
  from_port         = each.value[1]
  to_port           = each.value[1]
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks"
  description = "App tasks: only the ALB may connect in"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------- ALB ----------------
resource "aws_lb" "this" {
  name                       = var.name
  load_balancer_type         = "application"
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  idle_timeout               = 60
}

locals {
  https = var.certificate_arn != null
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = local.https ? "redirect" : "fixed-response"

    dynamic "redirect" {
      for_each = local.https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = local.https ? [] : [1]
      content {
        content_type = "text/plain"
        message_body = "launchpad: no environment matches this host"
        status_code  = "404"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.https ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "launchpad: no environment matches this host"
      status_code  = "404"
    }
  }
}

output "cluster_name" { value = aws_ecs_cluster.this.name }
output "cluster_arn" { value = aws_ecs_cluster.this.arn }
output "alb_arn" { value = aws_lb.this.arn }
output "alb_arn_suffix" { value = aws_lb.this.arn_suffix }
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_zone_id" { value = aws_lb.this.zone_id }
output "listener_arn" { value = local.https ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn }
output "tasks_security_group_id" { value = aws_security_group.tasks.id }
output "ecr_repository_urls" { value = { for k, r in aws_ecr_repository.app : k => r.repository_url } }
