package com.tomasalmeida.data.contract.readwrite;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.tomasalmeida.data.contract.User;
import com.tomasalmeida.data.contract.common.PropertiesLoader;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.errors.WakeupException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.time.Duration;
import java.util.Collections;
import java.util.Locale;
import java.util.Properties;

public class UnifiedTopicConsumerRunner {
    private static final Logger LOGGER = LoggerFactory.getLogger(UnifiedTopicConsumerRunner.class);

    private static final String ENV_TOPIC = "DEMO_TOPIC";
    private static final String ENV_FORMAT = "DEMO_FORMAT";

    private static final String FORMAT_AVRO = "avro";
    private static final String FORMAT_JSON = "json";

    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static void main(final String[] args) throws IOException {
        final String topic = getenvRequired(ENV_TOPIC);
        final String format = getenvOrDefault(ENV_FORMAT, FORMAT_AVRO).toLowerCase(Locale.ROOT);

        if (FORMAT_AVRO.equals(format)) {
            runAvroUserConsumer(topic);
            return;
        }

        if (FORMAT_JSON.equals(format)) {
            runStrictJsonConsumer(topic);
            return;
        }

        throw new IllegalArgumentException("Unsupported DEMO_FORMAT='" + format + "'. Use 'avro' or 'json'.");
    }

    private static void runAvroUserConsumer(final String topic) throws IOException {
        final Properties properties = PropertiesLoader.load("client.properties");

        // Ensure we use the SpecificRecord reader schema generated from user.avsc.
        // This makes breaking writer-schema changes (like removing a required field) fail at runtime.
        properties.put("specific.avro.reader", "true");
        properties.put("group.id", "unified-avro-" + sanitizeGroupId(topic) + "-" + System.currentTimeMillis());

        final KafkaConsumer<String, User> consumer = new KafkaConsumer<>(properties);
        runConsumerLoop(consumer, topic, (record) -> LOGGER.info("AVRO User: {}", record.value()));
    }

    private static void runStrictJsonConsumer(final String topic) throws IOException {
        final Properties properties = PropertiesLoader.load("client.properties");

        // Force raw string consumption.
        properties.put("key.deserializer", "org.apache.kafka.common.serialization.StringDeserializer");
        properties.put("value.deserializer", "org.apache.kafka.common.serialization.StringDeserializer");
        properties.put("group.id", "unified-json-" + sanitizeGroupId(topic) + "-" + System.currentTimeMillis());

        final KafkaConsumer<String, String> consumer = new KafkaConsumer<>(properties);
        runConsumerLoop(consumer, topic, (record) -> {
            validateUserJsonStrict(record.value());
            LOGGER.info("JSON User: {}", record.value());
        });
    }

    private static void validateUserJsonStrict(final String value) {
        try {
            final JsonNode node = MAPPER.readTree(value);

            requireText(node, "firstName");
            requireText(node, "lastName");
            requireText(node, "fullName");
            requireInt(node, "age");

            // Optional fields (must be present, but may be null to keep the JSON shape aligned with user.avsc)
            requireNullable(node, "id");
            requireNullable(node, "nombre");
            requireNullable(node, "email");
            requireNullable(node, "edad");
        } catch (Exception e) {
            throw new IllegalArgumentException("Strict JSON validation failed for message: " + value, e);
        }
    }

    private static void requireText(final JsonNode node, final String field) {
        if (!node.has(field) || node.get(field).isNull() || !node.get(field).isTextual()) {
            throw new IllegalArgumentException("Missing or non-string field '" + field + "'");
        }
    }

    private static void requireInt(final JsonNode node, final String field) {
        if (!node.has(field) || node.get(field).isNull() || !node.get(field).canConvertToInt()) {
            throw new IllegalArgumentException("Missing or non-int field '" + field + "'");
        }
    }

    private static void requireNullable(final JsonNode node, final String field) {
        if (!node.has(field)) {
            throw new IllegalArgumentException("Missing field '" + field + "' (use null if unknown)");
        }
    }

    private static <T> void runConsumerLoop(
            final KafkaConsumer<String, T> consumer,
            final String topic,
            final RecordHandler<T> handler
    ) {
        try {
            consumer.subscribe(Collections.singletonList(topic));
            LOGGER.info("Starting consumer for topic='{}'...", topic);

            while (true) {
                final ConsumerRecords<String, T> records = consumer.poll(Duration.ofMillis(1000));
                for (ConsumerRecord<String, T> record : records) {
                    handler.handle(record);
                }
            }
        } catch (WakeupException e) {
            LOGGER.info("Wake up consumer for topic='{}'...", topic);
        } catch (Exception e) {
            LOGGER.error("Error in consumer for topic='{}'", topic, e);
            throw e;
        } finally {
            LOGGER.info("Closing consumer for topic='{}'...", topic);
            consumer.close(Duration.ofSeconds(3));
            LOGGER.info("Closed consumer for topic='{}'...", topic);
        }
    }

    private static String getenvRequired(final String name) {
        final String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException("Missing required environment variable: " + name);
        }
        return value;
    }

    private static String getenvOrDefault(final String name, final String defaultValue) {
        final String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            return defaultValue;
        }
        return value;
    }

    private static String sanitizeGroupId(final String topic) {
        // Consumer group ids have limited characters; normalize topic names.
        return topic.replaceAll("[^a-zA-Z0-9._-]", "-");
    }

    @FunctionalInterface
    private interface RecordHandler<T> {
        void handle(ConsumerRecord<String, T> record);
    }
}
