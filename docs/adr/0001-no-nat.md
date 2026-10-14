# ADR-0001: No NAT gateway

**Status:** accepted

## Context
Fargate tasks need outbound internet access to pull images, reach the Anthropic API and send telemetry. The usual setup is private subnets behind a NAT gateway. A NAT gateway costs about $32/month per AZ plus data processing, which is more than the rest of this platform put together.

## Decision
Tasks run in public subnets with `assign_public_ip = true`. Their security group accepts traffic **only from the ALB's security group**, on port 8080. RDS stays in isolated private subnets that have no route to the internet.

## Consequences
- The attack surface stays effectively the same: nothing can reach a task directly, because security groups are stateful and deny by default.
- Each task uses a public IPv4 address ($0.005/h).
- To move to production: change one variable in the network module to add private app subnets, a NAT gateway (or VPC endpoints for ECR, S3, Logs and SSM) and `assign_public_ip = false`.
