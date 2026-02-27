# Scenario B: Unmanaged (Breaking Changes)

This scenario demonstrates the risks of setting Schema Registry compatibility to `NONE`. You will see how a breaking schema evolution can successfully register but subsequently crash active consumers.

## Overview
In this setup, the `crm.user.unmanaged` subject has no safety net. We will:
1. Produce legacy (**v1**) data.
2. Register a breaking (**v2**) schema (adding a required field without a default).
3. Observe how a consumer configured to track the latest schema fails to process the older data.

## 1. Precondition: Produce Legacy Data
Ensure there is at least one **v1** record in the unmanaged topic. You can use the producer from the previous steps to populate `crm.user.unmanaged`.

## 2. Produce Avro to `crm.user.unmanaged`
```bash
USER_SCHEMA_V1="$(jq -c . "$SCHEMA_DIR/user.avsc")"

printf '%s\n' \
  '{"firstName":"John","lastName":"Doe","fullName":"","age":30,"id":null,"nombre":null,"email":null,"edad":null}' | \
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
```bash
docker rm -f unified-consumer-unmanaged >/dev/null 2>&1 || true
docker run --rm \
  --name unified-consumer-unmanaged \
  -e DEMO_TOPIC="crm.user.unmanaged" \
  -e DEMO_FORMAT=avro \
  -v "$APP_DIR:/workspace" \
  -w /workspace \
  "$DEMO1_JAVA_IMAGE" \
  java -classpath target/readwrite-rules-app-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    com.tomasalmeida.data.contract.readwrite.UnifiedTopicConsumerRunner
```


## 4. Apply Breaking Schema Evolution
Force the registration of an incompatible schema. Since compatibility is set to `NONE`, Schema Registry will accept the change without validation.

```bash
terraform -chdir=terraform/04-schema-evolution apply -var enable_unmanaged_breaking=true
```

Expected Result: The Terraform apply succeeds. The subject `crm.user.unmanaged-value` now has a new version that is not backward compatible with the data already sitting in the topic.

## 5. Produce a v2 (breaking) message to `crm.user.unmanaged`
Now that the new schema version is registered, produce a new message that includes the required `country` field.

```bash
UNMANAGED_SCHEMA_V2_BREAKING="$(jq -c . terraform/04-schema-evolution/schemas/user_unmanaged_v2_breaking.avsc)"

printf '%s\n' \
  '{"firstName":"Jane","lastName":"Doe","fullName":"","age":31,"id":null,"nombre":null,"email":null,"edad":null,"country":"ES"}' | \
  docker run --rm -i \
    -v "$PWD/terraform/client.properties:/work/client.properties:ro" \
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

## 6. Simulate Consumer Crash
We will now configure the consumer to strictly use the latest schema version available in the registry as its reader schema. This simulates a common (but risky) pattern in dynamic environments.

```bash
# Append the two settings if they are not present already.
# (Keep the rest of the file as-is.)
if ! grep -q '^use.latest.version=' "$APP_DIR/src/main/resources/client.properties"; then
  printf '\nuse.latest.version=true\nlatest.compatibility.strict=false\n' >> \
    "$APP_DIR/src/main/resources/client.properties"
fi
```

## 7. Restart the unmanaged Java consumer and observe the crash
Because the consumer is configured with `use.latest.version=true`, it will try to use the latest schema as it reads old v1 messages.

```bash
docker rm -f unified-consumer-unmanaged >/dev/null 2>&1 || true

docker run --rm \
  --name unified-consumer-unmanaged \
  -e DEMO_TOPIC="crm.user.unmanaged" \
  -e DEMO_FORMAT=avro \
  -v "$APP_DIR:/workspace" \
  -w /workspace \
  "$DEMO1_JAVA_IMAGE" \
  java -classpath target/readwrite-rules-app-1.0.0-SNAPSHOT-jar-with-dependencies.jar \
    com.tomasalmeida.data.contract.readwrite.UnifiedTopicConsumerRunner
```

Expected: you should see an exception related to Avro schema resolution (missing required field `country`).
