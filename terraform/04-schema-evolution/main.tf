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

# Read platform + SR state
data "terraform_remote_state" "platform" {
  backend = "local"
  config = {
    path = "../01-platform/terraform.tfstate"
  }
}

data "terraform_remote_state" "sr" {
  backend = "local"
  config = {
    path = "../03-SR/terraform.tfstate"
  }
}

locals {
  environment_id                = data.terraform_remote_state.platform.outputs.environment_id
  schema_registry_id            = data.terraform_remote_state.sr.outputs.schema_registry_id
  schema_registry_rest_endpoint = data.terraform_remote_state.sr.outputs.schema_registry_rest_endpoint
  sr_api_key                    = data.terraform_remote_state.sr.outputs.sr_api_key
  sr_api_secret                 = data.terraform_remote_state.sr.outputs.sr_api_secret

  managed_subject_name   = "crm.user.managed-value"
  unmanaged_subject_name = "crm.user.unmanaged-value"

  managed_schema_file   = var.managed_schema_variant == "bad" ? "${path.module}/schemas/user_v2_bad_no_default.avsc" : "${path.module}/schemas/user_v2_good_with_default.avsc"
  unmanaged_schema_file = "${path.module}/schemas/user_unmanaged_v2_breaking.avsc"
}


# Managed evolution v2
# - 'bad' variant should FAIL because compatibility is BACKWARD and the new field has no default
# - 'good' variant should SUCCEED because the new field has a default
resource "confluent_schema" "crm_user_managed_v2" {
  schema_registry_cluster {
    id = local.schema_registry_id
  }

  rest_endpoint = local.schema_registry_rest_endpoint
  subject_name  = local.managed_subject_name
  format        = "AVRO"
  schema        = file(local.managed_schema_file)

  credentials {
    key    = local.sr_api_key
    secret = local.sr_api_secret
  }

}

# Unmanaged evolution v2 (breaking change)
# This is allowed because compatibility is NONE, but it will break specific Avro consumers.
resource "confluent_schema" "crm_user_unmanaged_v2_breaking" {
  count = var.enable_unmanaged_breaking ? 1 : 0

  schema_registry_cluster {
    id = local.schema_registry_id
  }

  rest_endpoint = local.schema_registry_rest_endpoint
  subject_name  = local.unmanaged_subject_name
  format        = "AVRO"
  schema        = file(local.unmanaged_schema_file)

  credentials {
    key    = local.sr_api_key
    secret = local.sr_api_secret
  }

  lifecycle {
    prevent_destroy = false
  }
}
