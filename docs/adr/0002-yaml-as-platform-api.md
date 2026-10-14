# ADR-0002: YAML files + Terraform `for_each` as the platform API

**Status:** accepted

## Context
Developers should be able to get environments without learning Terraform or AWS. The options were a portal (Backstage or Port), a CLI, or plain files in Git.

## Decision
The interface is a small YAML file per environment, checked against a JSON Schema (`schemas/environment.schema.json`). `live/environments` reads every file and creates one `modules/service` instance for each. Every field except identity and image tag has a golden-path default.

## Why
- **Reviewable:** every change is a PR with a plan attached, so there's an audit trail for free, which matters in a regulated trading company.
- **Simple:** no extra service to run. A portal can come later and simply write these same files.
- **Guard rails in three places:** the schema checks in the editor and CI, Terraform `precondition`s check at plan time, and `terraform test` makes sure the guard rails themselves keep working.

## Trade-offs
- All environments share one state file. That's fine for tens of environments. At hundreds, split the state per team (a Spacelift stack per team, or Terragrunt).
- Listener rule priorities come from sort order, so adding an environment can renumber the rules. That's an in-place update with no downtime.
