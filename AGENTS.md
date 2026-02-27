# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Where the code lives
Most actionable code in this repo is under:
- `terraform/` (Terraform configs + Confluent Cloud setup/docs)
- `demo1/` (Demo 1 Java app and schemas for data contracts)
- `scripts/demo1.sh` (Cloud runner for Demo 1)

The rest of the repo is primarily documentation.

## What `terraform/` is
`terraform/` is a Terraform-based demo for Confluent Cloud schema management / schema evolution using Schema Registry.

The intended workflow is the **layered** setup:
- `terraform/01-platform/`: environment + Kafka cluster + service accounts + access (role bindings / ACLs) + outputs
- `terraform/02-application/`: Kafka topics
- `terraform/03-SR/`: Schema Registry API key + base schema subjects + subject compatibility config
- `terraform/04-schema-evolution/`: optional schema evolution examples (managed vs unmanaged)
- `terraform/05-managed-contract/`: optional metadata + ruleset (data contract) applied to the managed subject

There is also a `terraform/main.tf` that looks like an earlier “all-in-one” configuration (different provider constraints). The docs under `terraform/` describe and assume the layered directories.

## What `demo1/` is
`demo1/` contains an adapted version of Demo 1 (Read/Write rules) from `confluent-data-contract`, adjusted for this lab:
- Producer: Kafka CLI (not Java `ProducerRunner` in the main flow)
- Consumer: existing `ConsumerRunner` from `readwrite-rules-app` (no new consumer)
- Build/run: Dockerized (no local Java required for running the demo script)
- Runtime target: Confluent Cloud (not a local Kafka cluster)

Important files:
- `demo1/readwrite-rules-app/src/main/resources/schema/user.avsc` (merged User schema)
- `demo1/readwrite-rules-app/src/main/resources/schema/*-metadata.json`
- `demo1/readwrite-rules-app/src/main/resources/schema/*-ruleset.json`
- `README-DEMO1.md`
- `scripts/demo1.sh`

## Common commands

### Terraform formatting (lint-style)
Run from repo root:
- `terraform -chdir=terraform fmt -recursive`

### Validate
Terraform has no unit tests here; the closest “test” loop is validate + plan.

Validate a single layer:
- `terraform -chdir=terraform/01-platform init`
- `terraform -chdir=terraform/01-platform validate`

Repeat for `terraform/02-application`, `terraform/03-SR`, `terraform/04-schema-evolution`, and `terraform/05-managed-contract`.

### Plan / apply
Apply in the documented order:
- `terraform -chdir=terraform/01-platform init`
- `terraform -chdir=terraform/01-platform plan`
- `terraform -chdir=terraform/01-platform apply`

Then:
- `terraform -chdir=terraform/02-application init`
- `terraform -chdir=terraform/02-application apply`

Then:
- `terraform -chdir=terraform/03-SR init`
- `terraform -chdir=terraform/03-SR apply`

Optionally:
- `terraform -chdir=terraform/04-schema-evolution init`
- `terraform -chdir=terraform/04-schema-evolution apply`
- `terraform -chdir=terraform/05-managed-contract init`
- `terraform -chdir=terraform/05-managed-contract apply`

Notes:
- `terraform/02-application/` and `terraform/03-SR/` read outputs from `terraform/01-platform/` via `data.terraform_remote_state` with a **local state path** (`../01-platform/terraform.tfstate`). If you don’t apply `01-platform/` first (or you delete/move the state file), the other layers will fail.

### Destroy
Destroy in reverse order:
- `terraform -chdir=terraform/05-managed-contract destroy`
- `terraform -chdir=terraform/04-schema-evolution destroy`
- `terraform -chdir=terraform/03-SR destroy`
- `terraform -chdir=terraform/02-application destroy`
- `terraform -chdir=terraform/01-platform destroy`

Notes:
- `terraform/03-SR` includes logic to avoid failing destroys when Schema Registry cluster lookup is not available (it prefers values saved in the local state file when present).
- If Confluent IAM permissions are insufficient, `01-platform destroy` can fail with `403 Forbidden` while deleting service accounts. In that case you must use a Cloud API key with org-level admin privileges, or delete the accounts manually.

## Environment setup for Confluent Cloud demo
The lab includes a helper script that extracts connection details/credentials from Terraform outputs/state and writes local config files under `terraform/`:
- `./terraform/setup-env.sh`
- `source terraform/.env`

Note: `terraform/.env` and `terraform/client.properties` contain credentials and must not be committed.

The Confluent Cloud **environment** and **Kafka cluster** display names created by `terraform/01-platform/` can be overridden via:
- `TF_VAR_environment_display_name` (default: `jsoto_demo_esquemas`)
- `TF_VAR_kafka_cluster_display_name` (default: `kafka_demo`)

What it generates (in `terraform/`):
- `terraform/.env`: exports `BOOTSTRAP_SERVER`, `SCHEMA_REGISTRY_URL`, `KAFKA_API_KEY/SECRET`, `SR_API_KEY/SECRET`, plus Java/Kafka CLI settings
- `terraform/client.properties`: Kafka client config used for authenticated CLI access

(See `terraform/setup-env.sh` and `terraform/QUICKSTART.md` for expected variables and examples.)

## Demo 1 runner workflow (Cloud-first)
Run from repo root:
1. `cd terraform && ./setup-env.sh && source .env && cd ..`
2. `./scripts/demo1.sh`

What `scripts/demo1.sh` does:
- Reads credentials from `terraform/.env` and `terraform/client.properties`
- Creates topics `crm.users`, `crm.contracts`, `crm.generic-dlq` in Confluent Cloud
- Builds `demo1/` with Dockerized Maven (`mvn -q -DskipTests package`)
- Registers schemas (`user`, `contract`) and applies metadata/rules in Schema Registry
- Runs `ConsumerRunner` from jar-with-dependencies in a Java container
- Produces events with dockerized `kafka-avro-console-producer`

## High-level architecture (Terraform layering)

### Layer boundaries and dependencies
- `terraform/01-platform/` is the source of truth for shared IDs/endpoints (environment id, Kafka cluster id/rest endpoint, service account id, Kafka API key).
- `terraform/02-application/` creates topics using the Kafka cluster info + Kafka API credentials exported by `01-platform/`.
- `terraform/03-SR/` manages Schema Registry resources (`confluent_api_key`, `confluent_schema`, `confluent_subject_config`) and reads the Confluent environment/service account from `01-platform/`.
- `terraform/04-schema-evolution/` and `terraform/05-managed-contract/` both read Schema Registry connection details and credentials from `terraform/03-SR` outputs.

### Cross-layer data flow
- Cross-layer wiring is done via `data.terraform_remote_state` using the **local** backend.
- Outputs live in `terraform/01-platform/outputs.tf` and are consumed via `locals { ... }` blocks in `terraform/02-application/main.tf` and `terraform/03-SR/main.tf`.

### Schema sources
- Terraform demo schemas are under `terraform/03-SR/schemas/*.avsc`.
- Demo 1 schemas are under `demo1/readwrite-rules-app/src/main/resources/schema/*.avsc` and related metadata/ruleset JSON files.
- `terraform/03-SR/main.tf` contains commented sections for optional evolution scenarios (e.g., v2 schema, incompatible changes, and Advanced data-contract examples). Ensure blocks are fully uncommented and syntactically complete before `terraform apply`.

## Docs to read first
- `terraform/README.md`: overview of 3-layer structure and apply/destroy order
- `terraform/QUICKSTART.md`: condensed setup and test flow
- `terraform/DEMO_README.md`: full Terraform demo narrative
- `README-DEMO1.md`: Demo 1 cloud runner guide
- `Demo Schema Evolution.md`: additional narrative/background (Spanish)
