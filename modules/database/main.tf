# Per-environment MySQL on RDS, in isolated private subnets.
# The master password is generated and rotated by RDS in Secrets Manager
# (manage_master_user_password) — it never appears in Terraform state or code.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "client_security_group_id" { type = string }

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "deletion_protection" {
  type    = bool
  default = false
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "MySQL: only app tasks may connect"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "mysql" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = var.client_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_db_instance" "this" {
  identifier                  = var.name
  engine                      = "mysql"
  engine_version              = "8.4"
  instance_class              = var.instance_class
  allocated_storage           = var.allocated_storage
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = replace(var.name, "-", "_")
  username                    = "app"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.db.id]
  publicly_accessible         = false
  multi_az                    = false
  backup_retention_period     = 1
  deletion_protection         = var.deletion_protection
  skip_final_snapshot         = !var.deletion_protection
  final_snapshot_identifier   = var.deletion_protection ? "${var.name}-final" : null
  apply_immediately           = true
  auto_minor_version_upgrade  = true
}

output "host" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "database" { value = aws_db_instance.this.db_name }
output "username" { value = aws_db_instance.this.username }
output "password_secret_arn" { value = aws_db_instance.this.master_user_secret[0].secret_arn }
