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
  '{"firstName":"All2","lastName":"Li","fullName":"","age":16,"id":null,"nombre":null,"email":null,"edad":null}' | \
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

In this demo the Avro consumer runs with `specific.avro.reader=true` and uses the generated `User` class, so “upgrading the consumer” means updating `user.avsc` and rebuilding the jar.

```bash
# Stop the managed consumer (if it is running)
docker rm -f unified-consumer-managed >/dev/null 2>&1 || true

# Backup v1 once, then switch the app schema to the v2-compatible variant (adds 'country' with a default)
# (Keeping a stable backup makes it safer to run Scenario B afterwards.)
if [[ ! -f "$SCHEMA_DIR/user.avsc.unified-demo.v1.bak" ]]; then
  cp "$SCHEMA_DIR/user.avsc" "$SCHEMA_DIR/user.avsc.unified-demo.v1.bak"
fi

cp "$ROOT_DIR/terraform/04-schema-evolution/schemas/user_v2_good_with_default.avsc" \
  "$SCHEMA_DIR/user.avsc"

# Rebuild the Java demo app 
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$ROOT_DIR/demo1:/workspace" \
  -v "$ROOT_DIR/demo1/.m2:/var/maven/.m2" \
  -e MAVEN_CONFIG=/var/maven/.m2 \
  -w /workspace \
  "$DEMO1_MAVEN_IMAGE" \
  mvn -q -DskipTests package

  # Restart the managed consumer 
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

Note: this walkthrough sets `use.latest.version=true` in the consumer `client.properties` (see section 4.4), so upgrading the consumer first is required.

### 5.2 Demonstrate failure

The managed topic is `BACKWARD`, so adding a *new required field without a default* is incompatible.

```bash
terraform -chdir=terraform/04-schema-evolution init
terraform -chdir=terraform/04-schema-evolution apply -var managed_schema_variant=bad
```

Expected: Terraform fails because SR rejects the incompatible schema.

### 5.3 Demonstrate success

```bash
terraform -chdir=terraform/04-schema-evolution apply -var managed_schema_variant=good
```

Expected: succeeds because the new field has a default.

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
