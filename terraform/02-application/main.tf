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
  # Topics use inline credentials in each resource
  kafka_api_key       = try(var.kafka_api_key, "")
  kafka_api_secret    = try(var.kafka_api_secret, "")
  kafka_rest_endpoint = try(var.kafka_rest_endpoint, "")
  kafka_id            = try(var.kafka_id, "")
}

# Read platform state using remote state
data "terraform_remote_state" "platform" {
  backend = "local"

  config = {
    path = "../01-platform/terraform.tfstate"
  }
}

# Locals to simplify access to platform outputs
locals {
  environment_id      = data.terraform_remote_state.platform.outputs.environment_id
  kafka_cluster_id    = data.terraform_remote_state.platform.outputs.kafka_cluster_id
  kafka_rest_endpoint = data.terraform_remote_state.platform.outputs.kafka_rest_endpoint
  # Schema Registry outputs - uncomment after platform phase 2
  # schema_registry_id = data.terraform_remote_state.platform.outputs.schema_registry_id
  # schema_registry_rest_endpoint = data.terraform_remote_state.platform.outputs.schema_registry_rest_endpoint
  kafka_api_key    = data.terraform_remote_state.platform.outputs.kafka_api_key
  kafka_api_secret = data.terraform_remote_state.platform.outputs.kafka_api_secret
  # sr_api_key = data.terraform_remote_state.platform.outputs.sr_api_key
  # sr_api_secret = data.terraform_remote_state.platform.outputs.sr_api_secret
}

# 1. Kafka Topics
# Unified demo naming convention (entity-focused)
# - Managed (Schema Registry + compatibility + rules): crm.user.managed
# - Unmanaged (Schema Registry + NONE compatibility): crm.user.unmanaged
# - No schema (raw JSON strings): crm.user.noschema
# - Shared DLQ: crm.generic-dlq
resource "confluent_kafka_topic" "crm_user_managed" {
  kafka_cluster {
    id = local.kafka_cluster_id
  }
  topic_name    = "crm.user.managed"
  rest_endpoint = local.kafka_rest_endpoint
  credentials {
    key    = local.kafka_api_key
    secret = local.kafka_api_secret
  }
}

resource "confluent_kafka_topic" "crm_user_unmanaged" {
  kafka_cluster {
    id = local.kafka_cluster_id
  }
  topic_name    = "crm.user.unmanaged"
  rest_endpoint = local.kafka_rest_endpoint
  credentials {
    key    = local.kafka_api_key
    secret = local.kafka_api_secret
  }
}

resource "confluent_kafka_topic" "crm_user_noschema" {
  kafka_cluster {
    id = local.kafka_cluster_id
  }
  topic_name    = "crm.user.noschema"
  rest_endpoint = local.kafka_rest_endpoint
  credentials {
    key    = local.kafka_api_key
    secret = local.kafka_api_secret
  }
}

# Flink pipeline sinks for the schemaless topic
resource "confluent_kafka_topic" "crm_user_noschema_adults" {
  kafka_cluster {
    id = local.kafka_cluster_id
  }
  topic_name    = "crm.user.noschema.adults"
  rest_endpoint = local.kafka_rest_endpoint
  credentials {
    key    = local.kafka_api_key
    secret = local.kafka_api_secret
  }
}

resource "confluent_kafka_topic" "crm_user_noschema_dlq" {
  kafka_cluster {
    id = local.kafka_cluster_id
  }
  topic_name    = "crm.user.noschema.dlq"
  rest_endpoint = local.kafka_rest_endpoint
  credentials {
    key    = local.kafka_api_key
    secret = local.kafka_api_secret
  }
}

resource "confluent_kafka_topic" "crm_generic_dlq" {
  kafka_cluster {
    id = local.kafka_cluster_id
  }
  topic_name    = "crm.generic-dlq"
  rest_endpoint = local.kafka_rest_endpoint
  credentials {
    key    = local.kafka_api_key
    secret = local.kafka_api_secret
  }
}

# ==============================================================================
# SCHEMA REGISTRY RESOURCES - Uncomment after platform Schema Registry is ready
# ==============================================================================
# 2. Schema
# resource "confluent_schema" "gestionado_schema_v1" {
#   schema_registry_cluster {
#     id = local.schema_registry_id
#   }
#   rest_endpoint = local.schema_registry_rest_endpoint
#   subject_name  = "gestionado-value"
#   format        = "AVRO"
#   schema        = file("./schemas/gestionado_v1.avsc")
#   credentials {
#     key    = local.sr_api_key
#     secret = local.sr_api_secret
#   }
# }

# 3. Subject Configs
# resource "confluent_subject_config" "gestionado_config" {
#   schema_registry_cluster {
#     id = local.schema_registry_id
#   }
#   rest_endpoint       = local.schema_registry_rest_endpoint
#   subject_name        = "gestionado-value"
#   compatibility_level = "BACKWARD"
#   credentials {
#     key    = local.sr_api_key
#     secret = local.sr_api_secret
#   }
# }

# resource "confluent_subject_config" "mal_gestionado_config" {
#   schema_registry_cluster {
#     id = local.schema_registry_id
#   }
#   rest_endpoint       = local.schema_registry_rest_endpoint
#   subject_name        = "mal_gestionado-value"
#   compatibility_level = "BACKWARD"
#   credentials {
#     key    = local.sr_api_key
#     secret = local.sr_api_secret
#   }
# }
