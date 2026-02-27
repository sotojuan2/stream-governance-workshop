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
  # Schema Registry resources use inline credentials in each resource
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
  # During a brand-new apply, the state file may not exist yet (or has no outputs).
  # During destroy, it usually exists and contains the SR cluster outputs, so we can
  # skip querying Confluent Cloud for the SR cluster (which can fail due to permissions).
  self_state_path = "${path.module}/terraform.tfstate"

  self_schema_registry_id            = try(jsondecode(file(local.self_state_path)).outputs.schema_registry_id.value, null)
  self_schema_registry_rest_endpoint = try(jsondecode(file(local.self_state_path)).outputs.schema_registry_rest_endpoint.value, null)

  have_self_sr = local.self_schema_registry_id != null && local.self_schema_registry_rest_endpoint != null

  environment_id     = data.terraform_remote_state.platform.outputs.environment_id
  service_account_id = data.terraform_remote_state.platform.outputs.service_account_id

  schema_registry_id            = local.have_self_sr ? local.self_schema_registry_id : data.confluent_schema_registry_cluster.essentials[0].id
  schema_registry_rest_endpoint = local.have_self_sr ? local.self_schema_registry_rest_endpoint : data.confluent_schema_registry_cluster.essentials[0].rest_endpoint

  # Needed by confluent_api_key.managed_resource. Use the live data source when available;
  # otherwise fall back to the known stable values from the stored state.
  schema_registry_api_version = local.have_self_sr ? "srcm/v3" : data.confluent_schema_registry_cluster.essentials[0].api_version
  schema_registry_kind        = local.have_self_sr ? "Cluster" : data.confluent_schema_registry_cluster.essentials[0].kind
}

# 1. Schema Registry (automatically created by stream_governance)
data "confluent_schema_registry_cluster" "essentials" {
  count = local.have_self_sr ? 0 : 1

  environment {
    id = local.environment_id
  }
}

# 2. Schema Registry API Key
resource "confluent_api_key" "sa_gestionado_sr_api" {
  display_name = "sa_gestionado_sr_api"
  description  = "API Key for Schema Registry"
  owner {
    id          = local.service_account_id
    api_version = "iam/v2"
    kind        = "ServiceAccount"
  }
  managed_resource {
    id          = local.schema_registry_id
    api_version = local.schema_registry_api_version
    kind        = local.schema_registry_kind
    environment { id = local.environment_id }
  }
}

# 3. Unified demo subjects
locals {
  managed_topic_name   = "crm.user.managed"
  unmanaged_topic_name = "crm.user.unmanaged"

  managed_subject_name   = "${local.managed_topic_name}-value"
  unmanaged_subject_name = "${local.unmanaged_topic_name}-value"

  # Single source of truth schema (shared by all user topics)
  user_schema_file = "${path.module}/../../demo1/readwrite-rules-app/src/main/resources/schema/user.avsc"
}

# 4. Base schemas (v1)
resource "confluent_schema" "crm_user_managed_v1" {
  schema_registry_cluster {
    id = local.schema_registry_id
  }

  rest_endpoint = local.schema_registry_rest_endpoint
  subject_name  = local.managed_subject_name
  format        = "AVRO"
  schema        = file(local.user_schema_file)

  credentials {
    key    = confluent_api_key.sa_gestionado_sr_api.id
    secret = confluent_api_key.sa_gestionado_sr_api.secret
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_schema" "crm_user_unmanaged_v1" {
  schema_registry_cluster {
    id = local.schema_registry_id
  }

  rest_endpoint = local.schema_registry_rest_endpoint
  subject_name  = local.unmanaged_subject_name
  format        = "AVRO"
  schema        = file(local.user_schema_file)

  credentials {
    key    = confluent_api_key.sa_gestionado_sr_api.id
    secret = confluent_api_key.sa_gestionado_sr_api.secret
  }

  lifecycle {
    prevent_destroy = false
  }
}

# 5. Subject configs
resource "confluent_subject_config" "crm_user_managed_config" {
  schema_registry_cluster {
    id = local.schema_registry_id
  }

  rest_endpoint       = local.schema_registry_rest_endpoint
  subject_name        = local.managed_subject_name
  compatibility_level = "BACKWARD"

  credentials {
    key    = confluent_api_key.sa_gestionado_sr_api.id
    secret = confluent_api_key.sa_gestionado_sr_api.secret
  }

  depends_on = [confluent_schema.crm_user_managed_v1]
}

resource "confluent_subject_config" "crm_user_unmanaged_config" {
  schema_registry_cluster {
    id = local.schema_registry_id
  }

  rest_endpoint       = local.schema_registry_rest_endpoint
  subject_name        = local.unmanaged_subject_name
  compatibility_level = "NONE"

  credentials {
    key    = confluent_api_key.sa_gestionado_sr_api.id
    secret = confluent_api_key.sa_gestionado_sr_api.secret
  }

  depends_on = [confluent_schema.crm_user_unmanaged_v1]
}
