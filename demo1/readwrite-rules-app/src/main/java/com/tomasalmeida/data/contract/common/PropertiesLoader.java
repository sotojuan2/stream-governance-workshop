package com.tomasalmeida.data.contract.common;

import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Properties;

public class PropertiesLoader {

    public static final String TOPIC_USERS = "crm.users";
    public static final String TOPIC_CONTRACTS = "crm.contracts";

    private static final String CONFIG_PATH = "src/main/resources/%s";
    private static final String ENV_BOOTSTRAP_SERVERS = "DEMO1_BOOTSTRAP_SERVERS";
    private static final String ENV_SCHEMA_REGISTRY_URL = "DEMO1_SCHEMA_REGISTRY_URL";

    public static Properties load(final String fileName) throws IOException {

        final String configFile = String.format(CONFIG_PATH, fileName);

        if (!Files.exists(Paths.get(configFile))) {
            throw new IOException(configFile + " not found.");
        }
        final Properties cfg = new Properties();
        try (final InputStream inputStream = new FileInputStream(configFile)) {
            cfg.load(inputStream);
        }
        overrideFromEnv(cfg, "bootstrap.servers", ENV_BOOTSTRAP_SERVERS);
        overrideFromEnv(cfg, "schema.registry.url", ENV_SCHEMA_REGISTRY_URL);
        return cfg;
    }

    private static void overrideFromEnv(final Properties cfg, final String property, final String envVar) {
        final String value = System.getenv(envVar);
        if (value != null && !value.isBlank()) {
            cfg.setProperty(property, value);
        }
    }
}
