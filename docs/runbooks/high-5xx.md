# Runbook: high 5xx on an environment

Triggered by the Datadog monitor `[launchpad] <env>: 5xx error rate high`.

1. **Recent deploy?** Run `git log -5 -- environments/<env>.yaml`. If the image tag just changed, revert that commit and the Apply workflow rolls back. The ECS circuit breaker also rolls back on its own if new tasks fail health checks.
2. **Logs:** CloudWatch log group `/launchpad/<env>`. Look for `SQLSTATE` (database problem) or `Allowed memory size` (task too small).
3. **Database:** check RDS CPU and connections. With `database: sqlite`, remember that every task restart starts from an empty database.
4. **Capacity:** if CPU is above 80%, raise `size` or `replicas` in the YAML file and open a PR.
5. **Spot interruptions:** look for `SpotInterruption` in ECS service events. For critical environments, set `spot: false`.
