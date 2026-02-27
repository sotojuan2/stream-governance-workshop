#!/bin/bash

# Confluent Cloud Demo - Environment Setup Script
# This script extracts credentials from Terraform state and sets environment variables

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "🔧 Setting up Confluent Cloud environment variables..."
echo ""

# Check prerequisites
command -v jq >/dev/null 2>&1 || { echo "❌ Error: jq is required but not installed. Install with: brew install jq"; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "❌ Error: terraform is required but not installed."; exit 1; }

# Extract Kafka bootstrap server (from 01-platform state)
echo "📡 Extracting Kafka configuration..."
cd 01-platform
export BOOTSTRAP_SERVER=$(terraform state show confluent_kafka_cluster.basic | grep bootstrap_endpoint | awk '{print $3}' | sed 's/"SASL_SSL:\/\///' | sed 's/"//')
echo "   ✓ BOOTSTRAP_SERVER: $BOOTSTRAP_SERVER"

# Extract Kafka API credentials (from 01-platform state)
export KAFKA_API_KEY=$(terraform state pull | jq -r '.resources[] | select(.name=="sa_gestionado_kafka_api") | .instances[0].attributes.id')
export KAFKA_API_SECRET=$(terraform state pull | jq -r '.resources[] | select(.name=="sa_gestionado_kafka_api") | .instances[0].attributes.secret')
echo "   ✓ KAFKA_API_KEY: $KAFKA_API_KEY"
cd ..

# Extract Schema Registry URL and credentials (from 03-SR outputs)
echo "📋 Extracting Schema Registry configuration..."
cd 03-SR

# Use outputs instead of reading a data source from state.
# This makes the script resilient when the SR cluster lookup is disabled (e.g. during destroy).
export SCHEMA_REGISTRY_URL=$(terraform output -raw schema_registry_rest_endpoint)
echo "   ✓ SCHEMA_REGISTRY_URL: $SCHEMA_REGISTRY_URL"

export SR_API_KEY=$(terraform output -raw sr_api_key)
export SR_API_SECRET=$(terraform output -raw sr_api_secret)
echo "   ✓ SR_API_KEY: $SR_API_KEY"
cd ..

# Set Java 17 (required for Kafka CLI)
echo "☕ Configuring Java..."
export JAVA_HOME=$(/usr/libexec/java_home -v 17 2>/dev/null || echo "")
if [ -z "$JAVA_HOME" ]; then
    echo "   ⚠️  Warning: Java 17 not found. Kafka CLI may not work."
    echo "   Install with: brew install openjdk@17"
else
    echo "   ✓ JAVA_HOME: $JAVA_HOME"
    java -version 2>&1 | head -1
fi

# Increase heap memory for Kafka CLI tools
export KAFKA_HEAP_OPTS="-Xmx512M"
echo "   ✓ KAFKA_HEAP_OPTS: $KAFKA_HEAP_OPTS"
echo ""

# Create client.properties file
echo "📝 Creating client.properties..."
cat > client.properties <<EOF
bootstrap.servers=$BOOTSTRAP_SERVER
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$KAFKA_API_KEY" password="$KAFKA_API_SECRET";
EOF
echo "   ✓ client.properties created at $SCRIPT_DIR/client.properties"
echo ""

# Export variables to a file that can be sourced
cat > .env <<EOF
# Confluent Cloud Environment Variables
# Source this file with: source .env

export BOOTSTRAP_SERVER="$BOOTSTRAP_SERVER"
export KAFKA_API_KEY="$KAFKA_API_KEY"
export KAFKA_API_SECRET="$KAFKA_API_SECRET"
export SCHEMA_REGISTRY_URL="$SCHEMA_REGISTRY_URL"
export SR_API_KEY="$SR_API_KEY"
export SR_API_SECRET="$SR_API_SECRET"
export JAVA_HOME="$JAVA_HOME"
export KAFKA_HEAP_OPTS="$KAFKA_HEAP_OPTS"
EOF

echo "✅ Setup complete!"
echo ""
echo "To use these variables in your current shell, run:"
echo "   source $SCRIPT_DIR/.env"
echo ""
#echo "Or to test the producer immediately:"
#echo "   source .env && kafka-avro-console-producer \\"
#echo "     --bootstrap-server \$BOOTSTRAP_SERVER \\"
#echo "     --producer.config client.properties \\"
#echo "     --property schema.registry.url=\"\$SCHEMA_REGISTRY_URL\" \\"
#echo "     --property basic.auth.credentials.source=USER_INFO \\"
#echo "     --property basic.auth.user.info=\"\$SR_API_KEY:\$SR_API_SECRET\" \\"
#echo "     --property value.schema=\"\$(< 03-SR/schemas/gestionado_v1.avsc)\" \\"
#echo "     --topic gestionado"
