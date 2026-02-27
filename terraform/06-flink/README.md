# 06-flink (two-step Terraform)
This directory is split into two Terraform layers:
- `01-infra/`: Flink infrastructure prerequisites (compute pool, RBAC, Flink API key)
- `02-application/`: Flink SQL statements (tables + routing logic)

## Apply
Run in order:
```bash
terraform -chdir=terraform/06-flink/01-infra init
terraform -chdir=terraform/06-flink/01-infra apply

terraform -chdir=terraform/06-flink/02-application init
terraform -chdir=terraform/06-flink/02-application apply
```

## Destroy
Destroy in reverse order:
```bash
terraform -chdir=terraform/06-flink/02-application destroy
terraform -chdir=terraform/06-flink/01-infra destroy
```

## Legacy (single-step)
If you previously applied the old single-directory version, it was moved to `00-monolith/` together with the existing local state, so you can still run:
```bash
terraform -chdir=terraform/06-flink/00-monolith destroy
```
