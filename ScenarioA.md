# Scenario A: Managed (Data Contracts)

This scenario demonstrates how **Confluent Schema Registry** with `BACKWARD` compatibility and **Data Quality Rules** (ruleset) protects your ecosystem from invalid data and breaking changes.

## Overview

In this setup, we enforce a strict contract on the `crm.user.managed` topic. The producer must adhere to:

* **Schema Evolution**: `BACKWARD` compatibility.
* **Business Rules**: Logic defined in `user-ruleset.json` (e.g., age and name length validation).

## 1. Verify Configuration

Ensure the managed contract layer is already applied:

```bash
terraform -chdir=terraform/05-managed-contract apply
```

## 2. Produce sample data (CLI)

Important: we set `auto.register.schemas=false` so producers do **not** write schemas to Schema Registry (Terraform remains the source of truth).

If you applied `terraform/05-managed-contract`, the managed subject has **metadata + rules** (data contract). For the CLI producer to execute Schema Registry rules (CEL + DLQ), enable the rule service loader and the built-in executors/actions.

Note: the DLQ action creates its own Kafka producer (rules run client-side), so it needs Kafka connection/auth configs (`bootstrap.servers`, `sasl.*`).

```bash
USER_SCHEMA_V1="$(jq -c . "$SCHEMA_DIR/user.avsc")"

printf '%s\n' \
  '{"firstName":"Ana2","lastName":"Lopez","fullName":"","age":28,"id":null,"nombre":null,"email":null,"edad":null}' \
  '{"firstName":"Bob2","lastName":"Smith","fullName":"","age":25,"id":null,"nombre":null,"email":null,"edad":null}' \
  '{"firstName":"All2","lastName":"Lis","fullName":"","age":16,"id":null,"nombre":null,"email":null,"edad":null}' | \
  docker run --rm -i \
    -v "$TERRAFORM_CLIENT_PROPERTIES:/work/client.properties:ro" \
    "$DEMO_KAFKA_TOOLS_IMAGE" \
    kafka-avro-console-producer \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --producer.config /work/client.properties \
      --property schema.registry.url="$SCHEMA_REGISTRY_URL" \
      --property basic.auth.credentials.source=USER_INFO \
      --property basic.auth.user.info="$SR_API_KEY:$SR_API_SECRET" \
      --property auto.register.schemas=false \
      --property value.schema="$USER_SCHEMA_V1" \
      --property use.latest.version=true \
      --property latest.compatibility.strict=false \
      --property rule.service.loader.enable=true \
      --property rule.executors=CEL,CEL_FIELD \
      --property rule.actions=NONE,DLQ \
      --property dlq.auto.flush=true \
      --property bootstrap.servers="$BOOTSTRAP_SERVER" \
      --property security.protocol=SASL_SSL \
      --property sasl.mechanism=PLAIN \
      --property sasl.jaas.config="org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$KAFKA_API_KEY\" password=\"$KAFKA_API_SECRET\";" \
      --topic crm.user.managed
```

If you applied `terraform/05-managed-contract`, the last record is useful to show data contract behavior (rules are configured with `onFailure=DLQ`).

## 3. Run the Java consumer

Run it in a separate terminal (or as a background container) so you can keep producing from the CLI.

```bash
docker rm -f unified-consumer-managed >/dev/null 2>&1 || true

docker run --rm -d \
  --name unified-consumer-managed \
  -e DEMO_TOPIC="crm.user.managed" \
  -e DEMO_FORMAT=avro \
  -v "$APP_DIR:/workspace" \
  -w /workspace \
  "$DEMO1_JAVA_IMAGE" \
  java -classpath target/readwrite-rules-app-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    com.tomasalmeida.data.contract.readwrite.UnifiedTopicConsumerRunner

docker logs -f unified-consumer-managed
```

## 4. Inspect the Dead Letter Queue (DLQ)
Check the contents of the DLQ to see the rejected record and its error metadata.

```bash
docker run --rm -i \
  -v "$TERRAFORM_CLIENT_PROPERTIES:/work/client.properties:ro" \
  "$DEMO_KAFKA_TOOLS_IMAGE" \
  kafka-avro-console-consumer \
    --bootstrap-server "$BOOTSTRAP_SERVER" \
    --consumer.config /work/client.properties \
    --property schema.registry.url="$SCHEMA_REGISTRY_URL" \
    --property basic.auth.credentials.source=USER_INFO \
    --property basic.auth.user.info="$SR_API_KEY:$SR_API_SECRET" \
    --topic crm.generic-dlq \
    --from-beginning \
    --max-messages 10
```

## 5. Managed schema evolution demo (BACKWARD: upgrade consumers first)

The managed topic is `BACKWARD`, so there is no assurance that consumers using an older schema can read data produced with a newer schema. Best practice is to upgrade consumers first, then producers.

### 5.1 Upgrade the managed Java consumer to v2 (reader schema)

This topic is configured as `BACKWARD`. That means **Schema Registry guarantees that the new schema (v2) can read data written with the previous schema (v1)**.

It does **not** guarantee that a consumer still running the old schema (v1) can read data produced with the new schema (v2). For that reason, the safe rollout order is:

1. Upgrade consumers (reader schema) first.
2. Upgrade producers / register the new writer schema afterwards.

In this demo, the Avro consumer runs with `specific.avro.reader=true` and uses the generated `User` class. So “upgrading the consumer” means updating the local `user.avsc` used by the Java build, regenerating the Avro classes, and rebuilding the jar.

#### Step 1: Stop the managed consumer

```bash
docker rm -f unified-consumer-managed >/dev/null 2>&1 || true
```

#### Step 2: Backup the current (v1) schema once

Keeping a stable backup makes it safer to run Scenario B afterwards.

```bash
if [[ ! -f "$SCHEMA_DIR/user.avsc.unified-demo.v1.bak" ]]; then
  cp "$SCHEMA_DIR/user.avsc" "$SCHEMA_DIR/user.avsc.unified-demo.v1.bak"
fi
```

#### Step 3: Switch the app schema to the v2 *compatible* variant

Here we use the v2 schema that **adds a new field with a default** (`country`).

- Old records (written with v1) do not contain `country`.
- When the v2 consumer reads them, Avro will use the **default** value.

```bash
cp "$ROOT_DIR/terraform/04-schema-evolution/schemas/user_v2_good_with_default.avsc" \
  "$SCHEMA_DIR/user.avsc"
```

#### Step 4: Rebuild the Java demo app (regenerate SpecificRecord classes)

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$ROOT_DIR/demo1:/workspace" \
  -v "$ROOT_DIR/demo1/.m2:/var/maven/.m2" \
  -e MAVEN_CONFIG=/var/maven/.m2 \
  -w /workspace \
  "$DEMO1_MAVEN_IMAGE" \
  mvn -q -DskipTests package
```

#### Step 5: Restart the managed consumer

```bash
docker rm -f unified-consumer-managed >/dev/null 2>&1 || true

docker run --rm -d \
  --name unified-consumer-managed \
  -e DEMO_TOPIC="crm.user.managed" \
  -e DEMO_FORMAT=avro \
  -v "$APP_DIR:/workspace" \
  -w /workspace \
  "$DEMO1_JAVA_IMAGE" \
  java -classpath target/readwrite-rules-app-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    com.tomasalmeida.data.contract.readwrite.UnifiedTopicConsumerRunner
```

#### Step 6: Follow the logs

```bash
docker logs -f unified-consumer-managed
```

Note: if your consumer configuration is set to resolve the latest schema version (for example via `use.latest.version=true`), upgrading the consumer first is required.

### 5.2 Demonstrate failure (incompatible schema rejected by Schema Registry)

Now that the consumer has been upgraded, we try to evolve the **managed subject** via Terraform.

`terraform/04-schema-evolution` selects the schema file based on `managed_schema_variant`:

- `bad` → `terraform/04-schema-evolution/schemas/user_v2_bad_no_default.avsc`
- `good` → `terraform/04-schema-evolution/schemas/user_v2_good_with_default.avsc`

The `bad` variant adds a new field **without a default**, which breaks `BACKWARD` compatibility (v2 cannot read old v1 data). Schema Registry rejects this update server-side, so `terraform apply` fails.

```bash
terraform -chdir=terraform/04-schema-evolution init
terraform -chdir=terraform/04-schema-evolution apply -var managed_schema_variant=bad
```

Expected:

- `terraform apply` fails during schema validation (the provider always validates during `apply`, even if `skip_validation_during_plan=true`).
- The error originates from Schema Registry compatibility checks, but what you will see is a **Terraform error** similar to:

```text
Error: error validating Schema: error validating a schema: [
  {errorType:'READER_FIELD_MISSING_DEFAULT_VALUE', description:'...missing default value...', additionalInfo:'country'}
  {compatibility: 'BACKWARD'}
]
```

What to look for:

- `READER_FIELD_MISSING_DEFAULT_VALUE` means the new schema adds a field (here: `country`) that is **missing in the old schema and has no default**.
- With `BACKWARD` compatibility this is rejected, because the new schema (reader) would not be able to read old data safely.

In the full Terraform output you will also typically see:

- The resource that failed (for example `confluent_schema.crm_user_managed_v2`).
- The file and line number in Terraform where the resource is declared (for example `terraform/04-schema-evolution/main.tf:54`).
- Extra fields such as `oldSchemaVersion` / `oldSchema`, which help you confirm what Schema Registry is comparing against.

### 5.3 Demonstrate success (compatible schema accepted)

The `good` variant adds the same field **with a default**, so v2 remains `BACKWARD` compatible with v1.

```bash
terraform -chdir=terraform/04-schema-evolution apply -var managed_schema_variant=good
```

Expected:

- `terraform apply` succeeds.
- The consumer (already upgraded in step 5.1) can read both old (v1) and new (v2) records.

### 5.4 Schema compatibility checks (Schema Registry)

When Terraform applies a `confluent_schema` update under the same `subject_name`, Schema Registry enforces the subject’s compatibility rules server-side.
No extra Terraform flag is required: incompatible schema changes make `terraform apply` fail.

In this repo, compatibility is managed via `confluent_subject_config` (see `terraform/03-SR`):

- `crm.user.managed-value`: `BACKWARD` (compatibility checks enabled)
- `crm.user.unmanaged-value`: `NONE` (compatibility checks disabled)

There is no provider option to “skip compatibility checks” during `terraform apply`.
To effectively bypass compatibility checks you must set the subject compatibility to `NONE` (or register the schema under a new subject).

Note: the Confluent Terraform provider supports `skip_validation_during_plan` on `confluent_schema`, but validation is still performed during `terraform apply (see [documentation](https://registry.terraform.io/providers/confluentinc/confluent/latest/docs/resources/confluent_schema)).

### 5.5 (Optional) Produce a v2 message to the managed topic
After `managed_schema_variant=good`, the v2 schema adds `country` (with a default).

```bash
MANAGED_SCHEMA_V2_GOOD="$(jq -c . terraform/04-schema-evolution/schemas/user_v2_good_with_default.avsc)"

printf '%s\n' \
  '{"firstName":"Carlos","lastName":"Diaz","fullName":"","age":33,"id":null,"nombre":null,"email":null,"edad":null,"country":"ES"}' | \
  docker run --rm -i \
    -v "$TERRAFORM_CLIENT_PROPERTIES:/work/client.properties:ro" \
    "$DEMO_KAFKA_TOOLS_IMAGE" \
    kafka-avro-console-producer \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --producer.config /work/client.properties \
      --property schema.registry.url="$SCHEMA_REGISTRY_URL" \
      --property basic.auth.credentials.source=USER_INFO \
      --property basic.auth.user.info="$SR_API_KEY:$SR_API_SECRET" \
      --property auto.register.schemas=false \
      --property value.schema="$MANAGED_SCHEMA_V2_GOOD" \
      --property use.latest.version=true \
      --property latest.compatibility.strict=false \
      --topic crm.user.managed
```

## Cleanup (restore v1 schema + rebuild the consumer jar)

Scenario B expects the app schema (`user.avsc`) to be the original **v1** variant (without `country`).

If you ran step **5.1** above, restore the backed up schema and rebuild the jar so the generated `User` class matches v1 again:

```bash
# Stop the managed consumer (optional, but avoids noisy logs)
docker rm -f unified-consumer-managed >/dev/null 2>&1 || true

# Restore original v1 user.avsc
if [[ -f "$SCHEMA_DIR/user.avsc.unified-demo.v1.bak" ]]; then
  mv "$SCHEMA_DIR/user.avsc.unified-demo.v1.bak" "$SCHEMA_DIR/user.avsc"
else
  # Fallback: restore the tracked version from git (run from repo root)
  git checkout -- demo1/readwrite-rules-app/src/main/resources/schema/user.avsc
fi

# Rebuild so the generated SpecificRecord matches v1 again
# (Use 'clean' to avoid stale generated sources/classes.)
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$ROOT_DIR/demo1:/workspace" \
  -v "$ROOT_DIR/demo1/.m2:/var/maven/.m2" \
  -e MAVEN_CONFIG=/var/maven/.m2 \
  -w /workspace \
  "$DEMO1_MAVEN_IMAGE" \
  mvn -q -DskipTests clean package
```
