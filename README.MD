# Demo

## Prerequisites

- Terraform installed
- `jq`
- Docker

## What you will see

You will compare three topics that carry the *same logical* `User` payload:

- **Managed**: Schema Registry + `BACKWARD` compatibility + metadata + rules (WRITE mode). Demonstrates safe evolution and DLQ routing.
- **Unmanaged**: Schema Registry + `NONE` compatibility. Demonstrates how breaking evolution can crash specific Avro consumers.
- **Schemaless**: raw JSON strings (no Schema Registry at production time). Demonstrates schema inference + Flink filtering.

## Topic and subject naming

Topics (Kafka):

- Managed: `crm.user.managed`
- Unmanaged: `crm.user.unmanaged`
- Schemaless: `crm.user.noschema`
- Shared DLQ (Schema Registry rules): `crm.generic-dlq`

Flink pipeline sinks:

- Adults: `crm.user.noschema.adults`
- Minors/DLQ: `crm.user.noschema.dlq`

Schema Registry subjects (TopicNameStrategy):

- Managed subject: `crm.user.managed-value`
- Unmanaged subject: `crm.user.unmanaged-value`

# Deploy Infra

## 1-Create a Cloud API Key

- Create a service account called `tf_runnerin` Confluent Cloud
- Assign the `OrganizationAdmin` role to the `tf_runnerin` service account
- Create a [Cloud API Key](https://docs.confluent.io/cloud/current/security/authenticate/workload-identities/service-accounts/api-keys/manage-api-keys.html) for the `tf_runner` service account

## 1. Set Environment Variables

```bash
export TF_VAR_confluent_cloud_api_key="xxxxxx"
export TF_VAR_confluent_cloud_api_secret="xxxxxxx"

# Optional: override the display names of the Confluent Cloud resources created by Terraform.
# Defaults (if unset):
# - environment_display_name: jsoto_demo_esquemas
# - kafka_cluster_display_name: kafka_demo
export TF_VAR_environment_display_name="my-demo-env"
export TF_VAR_kafka_cluster_display_name="my-demo-kafka"
```

## 2. Deploy platform and topics

Apply layers in order:

```bash
terraform -chdir=terraform/01-platform init
terraform -chdir=terraform/01-platform apply
```

If 01-platform fails because Schema Registry is still provisioning:
wait ~2 minutes and re-run apply.

## 3. Deploy topics

```bash
terraform -chdir=terraform/02-application init
terraform -chdir=terraform/02-application apply
```

## 3. Register base schemas and configure compatibility

Apply Schema Registry layer:

```bash
terraform -chdir=terraform/03-SR init
terraform -chdir=terraform/03-SR apply
```

Expected behavior:

- Managed subject compatibility is `BACKWARD`.
- Unmanaged subject compatibility is `NONE`.

## 4. Managed data contract: metadata + rules (WRITE mode)

This layer applies:

- Metadata from `demo1/readwrite-rules-app/src/main/resources/schema/user-metadata.json`
- Ruleset from `demo1/readwrite-rules-app/src/main/resources/schema/user-ruleset.json`

Apply:

```bash
terraform -chdir=terraform/05-managed-contract init
terraform -chdir=terraform/05-managed-contract apply
```

Expected behavior:

- Rules enforce:
  - `size(message.firstName) > 2`
  - `size(message.lastName) > 2`
  - `message.age > 17`
- Invalid records should be routed to `crm.generic-dlq`.

## 5. Demo: produce data (CLI) and consume it (Java in Docker)
This section avoids scripts and uses manual steps.

### 5.1 Load runtime credentials from Terraform state
```bash
cd terraform
./setup-env.sh
source .env
cd ..
```

### 5.2 Define working variables
```bash
export ROOT_DIR="$(pwd)"
export APP_DIR="$ROOT_DIR/demo1/readwrite-rules-app"
export SCHEMA_DIR="$APP_DIR/src/main/resources/schema"
export TERRAFORM_CLIENT_PROPERTIES="$ROOT_DIR/terraform/client.properties"

# Docker images used by the demo
export DEMO1_MAVEN_IMAGE="maven:3.9.9-eclipse-temurin-17"
export DEMO1_JAVA_IMAGE="eclipse-temurin:17-jre"
export DEMO_KAFKA_TOOLS_IMAGE="confluentinc/cp-schema-registry:8.1.1"
export DEMO_KAFKA_SERVER_IMAGE="confluentinc/cp-server:8.1.1"
```

### 5.3 Build the Java demo app (Dockerized Maven)
```bash
mkdir -p "$ROOT_DIR/demo1/.m2"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$ROOT_DIR/demo1:/workspace" \
  -v "$ROOT_DIR/demo1/.m2:/var/maven/.m2" \
  -e MAVEN_CONFIG=/var/maven/.m2 \
  -w /workspace \
  "$DEMO1_MAVEN_IMAGE" \
  mvn -q -DskipTests package
```

### 5.4 Prepare `client.properties` for the Java consumer (backup + restore)
For the **managed** evolution story, set the consumer to use the latest schema as its reader schema (`use.latest.version=true`).

Because managed compatibility is `BACKWARD`, upgrade the consumer first (see section 5.1) before producing messages with the newer schema.

```bash
cp "$APP_DIR/src/main/resources/client.properties" "$APP_DIR/src/main/resources/client.properties.unified-demo.bak"

cat > "$APP_DIR/src/main/resources/client.properties" <<CFG
bootstrap.servers=$BOOTSTRAP_SERVER
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$KAFKA_API_KEY" password="$KAFKA_API_SECRET";

schema.registry.url=$SCHEMA_REGISTRY_URL
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=$SR_API_KEY:$SR_API_SECRET

# Keep Terraform as the source of truth for schemas.
auto.register.schemas=false

key.serializer=org.apache.kafka.common.serialization.StringSerializer
value.serializer=io.confluent.kafka.serializers.KafkaAvroSerializer
use.latest.version=true
latest.compatibility.strict=false

auto.offset.reset=earliest
key.deserializer=org.apache.kafka.common.serialization.StringDeserializer
value.deserializer=io.confluent.kafka.serializers.KafkaAvroDeserializer
enable.auto.commit=false
CFG
```

## 6. Execute different scenarios

We will now explore three different architectural patterns for handling the `User` payload. Each scenario demonstrates a specific interaction between Kafka, Schema Registry, and downstream consumers.

### [Scenario A: Managed (Data Contracts)](./ScenarioA.md)

* **Configuration**: Schema Registry + `BACKWARD` compatibility + metadata + rules (WRITE mode).
* **Focus**: Demonstrates **safe evolution** and **Data Quality (DQ)** routing.
* **Expected Behavior**: Rules enforce that `firstName` and `lastName` are longer than 2 characters and `age > 17`. Invalid records are automatically routed to `crm.generic-dlq`.

### [Scenario B: Unmanaged (Breaking Changes)](./ScenarioB.md)

* **Configuration**: Schema Registry + `NONE` compatibility.
* **Focus**: Demonstrates how **breaking evolution** can crash specific Avro consumers.
* **Expected Behavior**: Since compatibility is not enforced, a producer can register a schema that breaks the contract, leading to deserialization failures for existing consumers.

### [Scenario C: Schemaless (Raw JSON)](./ScenarioC.md)

* **Configuration**: Raw JSON strings without Schema Registry at production time.
* **Focus**: Demonstrates **schema inference** and **Flink filtering**.
* **Expected Behavior**: Data is processed as raw strings. The Flink pipeline performs runtime inference to filter records into the `adults` or `dlq` topics based on the payload content.

## Cleanup
Destroy in reverse order:
```bash
terraform -chdir=terraform/06-flink/02-application destroy
terraform -chdir=terraform/06-flink/01-infra destroy
terraform -chdir=terraform/05-managed-contract destroy
terraform -chdir=terraform/04-schema-evolution destroy
terraform -chdir=terraform/03-SR destroy
terraform -chdir=terraform/02-application destroy
terraform -chdir=terraform/01-platform destroy
```
