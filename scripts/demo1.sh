#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="${ROOT_DIR}/demo1"
TERRAFORM_DIR="${ROOT_DIR}/terraform"
APP_DIR="${DEMO_DIR}/readwrite-rules-app"
SCHEMA_DIR="${APP_DIR}/src/main/resources/schema"
APP_CLIENT_PROPERTIES="${APP_DIR}/src/main/resources/client.properties"
TERRAFORM_ENV_FILE="${TERRAFORM_DIR}/.env"
TERRAFORM_CLIENT_PROPERTIES="${TERRAFORM_DIR}/client.properties"
JAR_PATH="${APP_DIR}/target/readwrite-rules-app-1.0.0-SNAPSHOT-jar-with-dependencies.jar"

DEMO1_MAVEN_IMAGE="${DEMO1_MAVEN_IMAGE:-maven:3.9.9-eclipse-temurin-17}"
DEMO1_JAVA_IMAGE="${DEMO1_JAVA_IMAGE:-eclipse-temurin:17-jre}"
DEMO1_KAFKA_TOOLS_IMAGE="${DEMO1_KAFKA_TOOLS_IMAGE:-confluentinc/cp-server:7.5.4}"
DEMO1_CONSUMER_TIMEOUT_SEC="${DEMO1_CONSUMER_TIMEOUT_SEC:-20}"
DEMO1_M2_DIR="${DEMO1_M2_DIR:-${DEMO_DIR}/.m2}"
DEMO1_CONSUMER_CONTAINER="${DEMO1_CONSUMER_CONTAINER:-demo1-cloud-consumer}"

RESTORE_CLIENT_PROPERTIES=0
APP_CLIENT_PROPERTIES_BACKUP="${APP_CLIENT_PROPERTIES}.demo1.bak"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

cleanup() {
  docker rm -f "${DEMO1_CONSUMER_CONTAINER}" >/dev/null 2>&1 || true
  if [[ "${RESTORE_CLIENT_PROPERTIES}" == "1" && -f "${APP_CLIENT_PROPERTIES_BACKUP}" ]]; then
    mv "${APP_CLIENT_PROPERTIES_BACKUP}" "${APP_CLIENT_PROPERTIES}"
  fi
}

wait_for_schema_registry() {
  local retries=60
  local attempt=1
  while (( attempt <= retries )); do
    if curl -fsS -u "${SR_API_KEY}:${SR_API_SECRET}" "${SCHEMA_REGISTRY_URL}/subjects" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "Schema Registry is not reachable at ${SCHEMA_REGISTRY_URL}" >&2
  exit 1
}

register_plain_schema() {
  local subject="$1"
  local schema_file="$2"
  jq -n --rawfile schema "${schema_file}" '{schema: $schema}' | \
    curl --silent --show-error --fail -u "${SR_API_KEY}:${SR_API_SECRET}" \
      "${SCHEMA_REGISTRY_URL}/subjects/${subject}/versions" --json @- | jq
}

apply_subject_payload() {
  local subject="$1"
  local json_file="$2"
  curl --silent --show-error --fail -u "${SR_API_KEY}:${SR_API_SECRET}" \
    "${SCHEMA_REGISTRY_URL}/subjects/${subject}/versions" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --data "@${json_file}" | jq
}

write_cloud_client_properties() {
  if [[ -f "${APP_CLIENT_PROPERTIES}" ]]; then
    cp "${APP_CLIENT_PROPERTIES}" "${APP_CLIENT_PROPERTIES_BACKUP}"
    RESTORE_CLIENT_PROPERTIES=1
  fi

  cat > "${APP_CLIENT_PROPERTIES}" <<CFG
bootstrap.servers=${BOOTSTRAP_SERVER}
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${KAFKA_API_KEY}" password="${KAFKA_API_SECRET}";
schema.registry.url=${SCHEMA_REGISTRY_URL}
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=${SR_API_KEY}:${SR_API_SECRET}
auto.register.schemas=false

key.serializer=org.apache.kafka.common.serialization.StringSerializer
value.serializer=io.confluent.kafka.serializers.KafkaAvroSerializer
use.latest.version=true
latest.compatibility.strict=false

auto.offset.reset=earliest
key.deserializer=org.apache.kafka.common.serialization.StringDeserializer
value.deserializer=io.confluent.kafka.serializers.KafkaAvroDeserializer
enable.auto.commit=false
auto.commit.interval.ms.config=1000
CFG
}

trap cleanup EXIT

require_cmd docker
require_cmd curl
require_cmd jq

require_file "${TERRAFORM_ENV_FILE}"
require_file "${TERRAFORM_CLIENT_PROPERTIES}"

# shellcheck disable=SC1090
source "${TERRAFORM_ENV_FILE}"

require_env BOOTSTRAP_SERVER
require_env SCHEMA_REGISTRY_URL
require_env KAFKA_API_KEY
require_env KAFKA_API_SECRET
require_env SR_API_KEY
require_env SR_API_SECRET

echo "==> Using Confluent Cloud from ${TERRAFORM_ENV_FILE}"
echo "==> BOOTSTRAP_SERVER=${BOOTSTRAP_SERVER}"
echo "==> SCHEMA_REGISTRY_URL=${SCHEMA_REGISTRY_URL}"

echo "==> Waiting for Schema Registry"
wait_for_schema_registry

echo "==> Creating topics in Confluent Cloud"
for topic in crm.users crm.contracts crm.generic-dlq; do
  docker run --rm \
    -v "${TERRAFORM_CLIENT_PROPERTIES}:/work/client.properties:ro" \
    "${DEMO1_KAFKA_TOOLS_IMAGE}" \
    kafka-topics --bootstrap-server "${BOOTSTRAP_SERVER}" \
      --command-config /work/client.properties \
      --create --if-not-exists --topic "${topic}"
done

echo "==> Compiling demo with Dockerized Maven"
mkdir -p "${DEMO1_M2_DIR}"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${DEMO_DIR}:/workspace" \
  -v "${DEMO1_M2_DIR}:/var/maven/.m2" \
  -e MAVEN_CONFIG=/var/maven/.m2 \
  -w /workspace \
  "${DEMO1_MAVEN_IMAGE}" \
  mvn -q -DskipTests package

if [[ ! -f "${JAR_PATH}" ]]; then
  echo "Expected artifact not found: ${JAR_PATH}" >&2
  exit 1
fi

echo "==> Registering plain schemas"
register_plain_schema "crm.users-value" "${SCHEMA_DIR}/user.avsc"
register_plain_schema "crm.contracts-value" "${SCHEMA_DIR}/contract.avsc"

echo "==> Applying metadata"
apply_subject_payload "crm.users-value" "${SCHEMA_DIR}/user-metadata.json"
apply_subject_payload "crm.contracts-value" "${SCHEMA_DIR}/contract-metadata.json"

echo "==> Applying ruleset"
apply_subject_payload "crm.users-value" "${SCHEMA_DIR}/user-ruleset.json"
apply_subject_payload "crm.contracts-value" "${SCHEMA_DIR}/contract-ruleset.json"

echo "==> Preparing ConsumerRunner cloud config"
write_cloud_client_properties

echo "==> Starting ConsumerRunner in Docker (${DEMO1_CONSUMER_CONTAINER})"
docker rm -f "${DEMO1_CONSUMER_CONTAINER}" >/dev/null 2>&1 || true
docker run --rm -d \
  --name "${DEMO1_CONSUMER_CONTAINER}" \
  -v "${APP_DIR}:/workspace" \
  -w /workspace \
  "${DEMO1_JAVA_IMAGE}" \
  java -classpath target/readwrite-rules-app-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    com.tomasalmeida.data.contract.readwrite.ConsumerRunner >/dev/null

sleep 3

USER_SCHEMA="$(jq -c . "${SCHEMA_DIR}/user.avsc")"
CONTRACT_SCHEMA="$(jq -c . "${SCHEMA_DIR}/contract.avsc")"

echo "==> Producing demo user events with kafka-avro-console-producer"
printf '%s\n' \
  '{"firstName":"Tomas","lastName":"Dias Almeida","fullName":"","age":39}' \
  '{"firstName":"La","lastName":"Fontaine","fullName":"","age":49}' \
  '{"firstName":"Amon","lastName":"Ra","fullName":"","age":52}' \
  '{"firstName":"Young","lastName":"Sheldon Cooper","fullName":"","age":7}' | \
  docker run --rm -i \
    -v "${TERRAFORM_CLIENT_PROPERTIES}:/work/client.properties:ro" \
    "${DEMO1_KAFKA_TOOLS_IMAGE}" \
    kafka-avro-console-producer \
      --bootstrap-server "${BOOTSTRAP_SERVER}" \
      --producer.config /work/client.properties \
      --property schema.registry.url="${SCHEMA_REGISTRY_URL}" \
      --property basic.auth.credentials.source=USER_INFO \
      --property basic.auth.user.info="${SR_API_KEY}:${SR_API_SECRET}" \
      --property value.schema="${USER_SCHEMA}" \
      --topic crm.users

echo "==> Producing demo contract events with kafka-avro-console-producer"
printf '%s\n' \
  '{"id":1,"name":"valid contract","expiration":"2030-12-31"}' \
  '{"id":2,"name":"expired contract","expiration":"2021-12-31"}' \
  '{"id":3,"name":"a","expiration":"2122-12-31"}' | \
  docker run --rm -i \
    -v "${TERRAFORM_CLIENT_PROPERTIES}:/work/client.properties:ro" \
    "${DEMO1_KAFKA_TOOLS_IMAGE}" \
    kafka-avro-console-producer \
      --bootstrap-server "${BOOTSTRAP_SERVER}" \
      --producer.config /work/client.properties \
      --property schema.registry.url="${SCHEMA_REGISTRY_URL}" \
      --property basic.auth.credentials.source=USER_INFO \
      --property basic.auth.user.info="${SR_API_KEY}:${SR_API_SECRET}" \
      --property value.schema="${CONTRACT_SCHEMA}" \
      --topic crm.contracts

echo "==> Waiting ${DEMO1_CONSUMER_TIMEOUT_SEC}s for ConsumerRunner logs"
sleep "${DEMO1_CONSUMER_TIMEOUT_SEC}"

echo "==> ConsumerRunner logs"
docker logs "${DEMO1_CONSUMER_CONTAINER}" || true

echo "==> Stopping ConsumerRunner"
docker rm -f "${DEMO1_CONSUMER_CONTAINER}" >/dev/null 2>&1 || true

echo "==> Demo 1 completed"
