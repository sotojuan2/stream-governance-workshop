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

locals {
  environment_id     = data.terraform_remote_state.platform.outputs.environment_id
  kafka_cluster_id   = data.terraform_remote_state.platform.outputs.kafka_cluster_id
  service_account_id = data.terraform_remote_state.platform.outputs.service_account_id

  flink_cloud  = "AWS"
  flink_region = "eu-central-1"

  topic_source = "crm.user.noschema"
  topic_adults = "crm.user.noschema.adults"
  topic_dlq    = "crm.user.noschema.dlq"

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

data "confluent_flink_region" "main" {
  cloud  = local.flink_cloud
  region = local.flink_region
}

resource "confluent_flink_compute_pool" "unified_demo" {
  display_name = "unified-demo-pool"
  cloud        = local.flink_cloud
  region       = local.flink_region
  max_cfu      = var.flink_max_cfu

  environment {
    id = local.environment_id
  }

}

# RBAC for Flink SQL
# Required to create/execute Flink statements.
resource "confluent_role_binding" "flink_developer" {
  principal   = "User:${local.service_account_id}"
  role_name   = "FlinkDeveloper"
  crn_pattern = data.confluent_environment.demo.resource_name
}

# Flink API key for statements
resource "confluent_api_key" "flink_api_key" {
  display_name = "unified-demo-flink-api-key"
  description  = "Flink API Key for the unified demo"

  owner {
    id          = local.service_account_id
    api_version = "iam/v2"
    kind        = "ServiceAccount"
  }

  managed_resource {
    id          = data.confluent_flink_region.main.id
    api_version = data.confluent_flink_region.main.api_version
    kind        = data.confluent_flink_region.main.kind

    environment {
      id = local.environment_id
    }
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
# Drop + create tables
# Some early failed attempts may have created tables with incompatible schemas (e.g., [key BYTES, val BYTES]).
# We drop them once to ensure the demo is reproducible.
resource "confluent_flink_statement" "drop_adults_table" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = local.environment_id
  }
  compute_pool {
    id = confluent_flink_compute_pool.unified_demo.id
  }
  principal {
    id = local.service_account_id
  }

  statement = "DROP TABLE IF EXISTS ${local.table_adults};"

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.flink_api_key.id
    secret = confluent_api_key.flink_api_key.secret
  }
}

resource "confluent_flink_statement" "drop_dlq_table" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = local.environment_id
  }
  compute_pool {
    id = confluent_flink_compute_pool.unified_demo.id
  }
  principal {
    id = local.service_account_id
  }

  statement = "DROP TABLE IF EXISTS ${local.table_dlq};"

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.flink_api_key.id
    secret = confluent_api_key.flink_api_key.secret
  }
}

resource "confluent_flink_statement" "drop_source_table" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = local.environment_id
  }
  compute_pool {
    id = confluent_flink_compute_pool.unified_demo.id
  }
  principal {
    id = local.service_account_id
  }

  statement = "DROP TABLE IF EXISTS ${local.table_source};"

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.flink_api_key.id
    secret = confluent_api_key.flink_api_key.secret
  }
}

# Source table (JSON via Schema Registry)
resource "confluent_flink_statement" "create_source_table" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = local.environment_id
  }
  compute_pool {
    id = confluent_flink_compute_pool.unified_demo.id
  }
  principal {
    id = local.service_account_id
  }

  depends_on = [
    confluent_flink_statement.drop_adults_table,
    confluent_flink_statement.drop_dlq_table,
    confluent_flink_statement.drop_source_table,
  ]

  statement = <<SQL
CREATE TABLE ${local.table_source} (
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
  'value.format' = 'json-registry',
  'scan.startup.mode' = 'earliest-offset'
);
SQL

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.flink_api_key.id
    secret = confluent_api_key.flink_api_key.secret
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
    id = confluent_flink_compute_pool.unified_demo.id
  }
  principal {
    id = local.service_account_id
  }

  depends_on = [confluent_flink_statement.drop_adults_table]

  statement = <<SQL
CREATE TABLE ${local.table_adults} (
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

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.flink_api_key.id
    secret = confluent_api_key.flink_api_key.secret
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
    id = confluent_flink_compute_pool.unified_demo.id
  }
  principal {
    id = local.service_account_id
  }

  depends_on = [confluent_flink_statement.drop_dlq_table]

  statement = <<SQL
CREATE TABLE ${local.table_dlq} (
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

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.flink_api_key.id
    secret = confluent_api_key.flink_api_key.secret
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
    id = confluent_flink_compute_pool.unified_demo.id
  }
  principal {
    id = local.service_account_id
  }

  statement = "INSERT INTO ${local.table_adults} SELECT `key`, `firstName`, `lastName`, `fullName`, `age`, `id`, `nombre`, `email`, `edad` FROM ${local.table_source} WHERE `age` >= 18;"

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.flink_api_key.id
    secret = confluent_api_key.flink_api_key.secret
  }

  depends_on = [
    confluent_flink_statement.create_source_table,
    confluent_flink_statement.create_adults_table,
    confluent_flink_statement.create_dlq_table
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
    id = confluent_flink_compute_pool.unified_demo.id
  }
  principal {
    id = local.service_account_id
  }

  statement = "INSERT INTO ${local.table_dlq} SELECT `key`, `firstName`, `lastName`, `fullName`, `age`, `id`, `nombre`, `email`, `edad` FROM ${local.table_source} WHERE `age` < 18;"

  properties = {
    "sql.current-catalog"  = data.confluent_environment.demo.display_name
    "sql.current-database" = data.confluent_kafka_cluster.basic.display_name
  }

  rest_endpoint = data.confluent_flink_region.main.rest_endpoint
  credentials {
    key    = confluent_api_key.flink_api_key.id
    secret = confluent_api_key.flink_api_key.secret
  }

  depends_on = [
    confluent_flink_statement.create_source_table,
    confluent_flink_statement.create_adults_table,
    confluent_flink_statement.create_dlq_table
  ]
}
