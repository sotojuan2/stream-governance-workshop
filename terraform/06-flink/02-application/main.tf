terraform {
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = ">= 2.0.0"
    }
  }
}

provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret

  # Dummy Kafka credentials to satisfy provider validation
  kafka_api_key       = try(var.kafka_api_key, "")
  kafka_api_secret    = try(var.kafka_api_secret, "")
  kafka_rest_endpoint = try(var.kafka_rest_endpoint, "")
  kafka_id            = try(var.kafka_id, "")
}

# Read platform state
data "terraform_remote_state" "platform" {
  backend = "local"
  config = {
    path = "../../01-platform/terraform.tfstate"
  }
}

# Read Flink infrastructure state
data "terraform_remote_state" "flink_infra" {
  backend = "local"
  config = {
    path = "../01-infra/terraform.tfstate"
  }
}

locals {
  environment_id     = data.terraform_remote_state.platform.outputs.environment_id
  kafka_cluster_id   = data.terraform_remote_state.platform.outputs.kafka_cluster_id
  service_account_id = data.terraform_remote_state.platform.outputs.service_account_id

  flink_compute_pool_id = data.terraform_remote_state.flink_infra.outputs.compute_pool_id
  flink_rest_endpoint   = data.terraform_remote_state.flink_infra.outputs.flink_rest_endpoint
  flink_api_key_id      = data.terraform_remote_state.flink_infra.outputs.flink_api_key_id
  flink_api_key_secret  = data.terraform_remote_state.flink_infra.outputs.flink_api_key_secret

  # Flink uses table names; we keep them aligned with topic names and quote with backticks.
  table_source = "`crm.user.noschema`"
  table_adults = "`crm.user.noschema.adults`"
  table_dlq    = "`crm.user.noschema.dlq`"
}

data "confluent_organization" "main" {}

data "confluent_environment" "demo" {
  id = local.environment_id
}

data "confluent_kafka_cluster" "basic" {
  id = local.kafka_cluster_id
  environment {
    id = local.environment_id
  }
}

# ------------------------------------------------------------------------------
# Flink SQL
# ------------------------------------------------------------------------------
# Notes:
# - This layer assumes you have already used Confluent Cloud UI to "Infer schema from messages" for crm.user.noschema
#   so that the JSON structure is available via Schema Registry.
# - The 'confluent' connector maps Flink tables to Kafka topics in the selected Kafka cluster.
#
# IMPORTANT: Do NOT use DROP TABLE in Confluent Cloud Flink SQL.
# In CC, DROP TABLE deletes both the Flink catalog entry AND the underlying Kafka topic + data.
# Source table (JSON via Schema Registry)
resource "confluent_flink_statement" "create_source_table" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = local.environment_id
  }
  compute_pool {
    id = local.flink_compute_pool_id
  }
  principal {
    id = local.service_account_id
  }


  # Column types MUST match the JSON Schema registered in SR for crm.user.noschema-value.
  # Non-nullable strings match JSON Schema "type": "string" (required).
  # Nullable fields match JSON Schema "type": ["null", ...].
  statement = <<SQL
CREATE TABLE IF NOT EXISTS ${local.table_source} (
  `key` VARBINARY(2147483647),
  `firstName` STRING NOT NULL,
  `lastName` STRING NOT NULL,
  `fullName` STRING NOT NULL,
  `age` DOUBLE,
  `id` DOUBLE,
  `nombre` STRING,
  `email` STRING,
  `edad` BIGINT
)
DISTRIBUTED BY HASH(`key`) INTO 2 BUCKETS
WITH (
  'connector' = 'confluent',
  'key.format' = 'raw',
  'value.format' = 'json-registry',
  'scan.startup.mode' = 'earliest-offset'
);
SQL

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = local.flink_rest_endpoint
  credentials {
    key    = local.flink_api_key_id
    secret = local.flink_api_key_secret
  }
}

# Sink tables
resource "confluent_flink_statement" "create_adults_table" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = local.environment_id
  }
  compute_pool {
    id = local.flink_compute_pool_id
  }
  principal {
    id = local.service_account_id
  }

  depends_on = [confluent_flink_statement.create_source_table]

  statement = <<SQL
CREATE TABLE IF NOT EXISTS ${local.table_adults} (
  `key` VARBINARY(2147483647),
  `firstName` STRING,
  `lastName` STRING,
  `fullName` STRING,
  `age` DOUBLE,
  `id` DOUBLE,
  `nombre` STRING,
  `email` STRING,
  `edad` BIGINT
)
DISTRIBUTED BY HASH(`key`) INTO 2 BUCKETS
WITH (
  'connector' = 'confluent',
  'key.format' = 'raw',
  'value.format' = 'json-registry'
);
SQL

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = local.flink_rest_endpoint
  credentials {
    key    = local.flink_api_key_id
    secret = local.flink_api_key_secret
  }
}

resource "confluent_flink_statement" "create_dlq_table" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = local.environment_id
  }
  compute_pool {
    id = local.flink_compute_pool_id
  }
  principal {
    id = local.service_account_id
  }

  depends_on = [confluent_flink_statement.create_source_table]

  statement = <<SQL
CREATE TABLE IF NOT EXISTS ${local.table_dlq} (
  `key` VARBINARY(2147483647),
  `firstName` STRING,
  `lastName` STRING,
  `fullName` STRING,
  `age` DOUBLE,
  `id` DOUBLE,
  `nombre` STRING,
  `email` STRING,
  `edad` BIGINT
)
DISTRIBUTED BY HASH(`key`) INTO 2 BUCKETS
WITH (
  'connector' = 'confluent',
  'key.format' = 'raw',
  'value.format' = 'json-registry'
);
SQL

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = local.flink_rest_endpoint
  credentials {
    key    = local.flink_api_key_id
    secret = local.flink_api_key_secret
  }
}

# Routing logic
resource "confluent_flink_statement" "route_adults" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = local.environment_id
  }
  compute_pool {
    id = local.flink_compute_pool_id
  }
  principal {
    id = local.service_account_id
  }

  statement = "INSERT INTO ${local.table_adults} SELECT `key`, `firstName`, `lastName`, `fullName`, `age`, `id`, `nombre`, `email`, `edad` FROM ${local.table_source} WHERE `age` >= 18;"

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = local.flink_rest_endpoint
  credentials {
    key    = local.flink_api_key_id
    secret = local.flink_api_key_secret
  }

  depends_on = [
    confluent_flink_statement.create_source_table,
    confluent_flink_statement.create_adults_table,
    confluent_flink_statement.create_dlq_table,
  ]
}

resource "confluent_flink_statement" "route_minors_to_dlq" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = local.environment_id
  }
  compute_pool {
    id = local.flink_compute_pool_id
  }
  principal {
    id = local.service_account_id
  }

  statement = "INSERT INTO ${local.table_dlq} SELECT `key`, `firstName`, `lastName`, `fullName`, `age`, `id`, `nombre`, `email`, `edad` FROM ${local.table_source} WHERE `age` < 18;"

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = local.flink_rest_endpoint
  credentials {
    key    = local.flink_api_key_id
    secret = local.flink_api_key_secret
  }

  depends_on = [
    confluent_flink_statement.create_source_table,
    confluent_flink_statement.create_adults_table,
    confluent_flink_statement.create_dlq_table,
  ]
}
