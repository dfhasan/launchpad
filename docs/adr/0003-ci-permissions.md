# ADR-0003: CI permissions with GitHub OIDC

**Status:** accepted

| Role | Who can assume it (OIDC `sub`) | Permissions |
|---|---|---|
| `launchpad-plan` | any ref of the repo, including PRs | `ReadOnlyAccess` + state bucket |
| `launchpad-apply` | only jobs in the protected `production` environment | PowerUser + IAM limited to `lp-*` roles |
| `launchpad-build` | only `refs/heads/main` | ECR push |

No long-lived AWS keys exist anywhere. A PR from a branch can see a plan but can't change anything.

**Next step for production:** replace PowerUser with a per-service policy built from CloudTrail usage, and add a permissions boundary on the `lp-*` roles that Terraform creates.
