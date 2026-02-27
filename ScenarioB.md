# Scenario B: Unmanaged (Breaking Changes)

This scenario demonstrates the risks of setting Schema Registry compatibility to `NONE`. You will see how a breaking schema evolution can successfully register but subsequently crash active consumers.

## Overview
In this setup, the `crm.user.unmanaged` subject has no safety net because compatibility is set to `NONE`. We will:
1. Produce legacy (**v1**) data.
2. Start a consumer (configured to resolve the latest schema).
3. Register a breaking (**v2**) schema (adds a required field without a default).
4. Produce **v2** data.
5. Observe how the consumer fails with a deserialization error.

## 1. Precondition: Produce Legacy Data
Ensure there is at least one **v1** record in the unmanaged topic. You can use the producer from the previous steps to populate `crm.user.unmanaged`.

## 2. Produce Avro to `crm.user.unmanaged`

Produce a few **v1** records so we have legacy data in the topic before we introduce the breaking change.

```bash
USER_SCHEMA_V1="$(jq -c . "$SCHEMA_DIR/user.avsc")"

printf '%s\n' \
  '{"firstName":"John","lastName":"Doe","fullName":"","age":30,"id":null,"nombre":null,"email":null,"edad":null}' \
  '{"firstName":"Alice","lastName":"Miller","fullName":"","age":27,"id":null,"nombre":null,"email":null,"edad":null}' \
  '{"firstName":"Bob","lastName":"Smith","fullName":"","age":41,"id":null,"nombre":null,"email":null,"edad":null}' | \
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
      --topic crm.user.unmanaged
```

## 3. Consume Avro from `crm.user.unmanaged`

Start the consumer and keep it running so you can observe the failure when the schema changes.

Run this in a separate terminal: `docker logs -f` will follow the consumer logs.

Note: in this lab the consumer is configured with `use.latest.version=true`, so it will resolve the **latest** schema version from Schema Registry as its reader schema.

```bash
docker rm -f unified-consumer-unmanaged >/dev/null 2>&1 || true

docker run --rm -d \
  --name unified-consumer-unmanaged \
  -e DEMO_TOPIC="crm.user.unmanaged" \
  -e DEMO_FORMAT=avro \
  -v "$APP_DIR:/workspace" \
  -w /workspace \
  "$DEMO1_JAVA_IMAGE" \
  java -classpath target/readwrite-rules-app-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    com.tomasalmeida.data.contract.readwrite.UnifiedTopicConsumerRunner

docker logs -f unified-consumer-unmanaged
```

## 4. Apply Breaking Schema Evolution

Force the registration of an incompatible schema.

Because compatibility is set to `NONE`, Schema Registry does **no compatibility checking** and will accept the new version even if it is not backward/forward compatible.

```bash
terraform -chdir=terraform/04-schema-evolution apply -var enable_unmanaged_breaking=true
```

Expected Result:

- `terraform apply` succeeds.
- The subject `crm.user.unmanaged-value` now has a new version that is incompatible with the existing data already sitting in the topic.

Important: Schema Registry only validates (or skips validation) at schema registration time. It does not change the bytes already stored in Kafka, so after a breaking change the topic can contain data that some consumers can no longer deserialize.

## 5. Produce v2 (breaking) messages to `crm.user.unmanaged`

Now that the new schema version is registered, produce a few **v2** messages that include the new required `country` field.

```bash
UNMANAGED_SCHEMA_V2_BREAKING="$(jq -c . terraform/04-schema-evolution/schemas/user_unmanaged_v2_breaking.avsc)"

printf '%s\n' \
  '{"firstName":"Jane","lastName":"Doe","fullName":"","age":31,"id":null,"nombre":null,"email":null,"edad":null,"country":"ES"}' \
  '{"firstName":"Carlos","lastName":"Diaz","fullName":"","age":33,"id":null,"nombre":null,"email":null,"edad":null,"country":"ES"}' \
  '{"firstName":"Emma","lastName":"Jones","fullName":"","age":22,"id":null,"nombre":null,"email":null,"edad":null,"country":"US"}' | \
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
      --property value.schema="$UNMANAGED_SCHEMA_V2_BREAKING" \
      --topic crm.user.unmanaged
```

Expected Result (consumer failure):

Because compatibility is `NONE`, Schema Registry allowed a breaking schema change, so **the topic now contains a mix of v1 and v2 records that are not safely readable with a single reader schema**.

Kafka clients surface this as a deserialization problem: the consumer cannot deserialize the record bytes into an Avro object using its configured deserializer/reader schema. In this demo you will see an error like:

```text
2026-02-27 14:18:14 ERROR [UnifiedTopicConsumerRunner:130] - Error in consumer for topic='crm.user.unmanaged'
org.apache.kafka.common.errors.RecordDeserializationException: Error deserializing key/value for partition crm.user.unmanaged-2 at offset 0. If needed, please seek past the record to continue consumption.
```

What this means:

- `RecordDeserializationException` is thrown when the consumer cannot deserialize a record (for example due to malformed data, wrong deserializer, or incompatible schema evolution).
- The "at offset 0" detail often means the consumer hit an unreadable record early (for example because it is starting from the beginning of the topic).
- The "seek past the record" hint is Kafka telling you that *this specific record at that offset cannot be read with your current configuration*, so the consumer cannot make progress unless you skip it.
- Root cause in this scenario: with compatibility `NONE` we registered a schema that adds a required field without a default. As a result, old v1 records (no `country`) and new v2 records are not safely readable using a single fixed configuration.

Optional recovery ideas (not part of the demo flow):

- Roll back the incompatible schema evolution (or avoid `NONE` and use a real compatibility mode).
- Upgrade consumers before producers, or use a new subject/topic when doing breaking changes.
- If you just want the consumer to make progress, change the consumer group id / reset offsets, or implement a strategy to skip/DLQ unreadable records.
