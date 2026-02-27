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

  managed_subject_name = "crm.user.managed-value"

  user_schema_file   = "${path.module}/../../demo1/readwrite-rules-app/src/main/resources/schema/user.avsc"
  user_metadata_file = "${path.module}/../../demo1/readwrite-rules-app/src/main/resources/schema/user-metadata.json"
  user_ruleset_file  = "${path.module}/../../demo1/readwrite-rules-app/src/main/resources/schema/user-ruleset.json"

  user_metadata = jsondecode(file(local.user_metadata_file))
  user_ruleset  = jsondecode(file(local.user_ruleset_file))

  domain_rules = local.user_ruleset.ruleSet.domainRules
}

# Apply metadata + ruleset by registering a new schema version that includes them.
# Note: the Avro schema itself does not need to change for metadata/ruleset updates.
resource "confluent_schema" "crm_user_managed_with_contract" {
  schema_registry_cluster {
    id = local.schema_registry_id
  }

  rest_endpoint = local.schema_registry_rest_endpoint
  subject_name  = local.managed_subject_name
  format        = "AVRO"
  schema        = file(local.user_schema_file)

  metadata {
    properties = local.user_metadata.metadata.properties
  }

  ruleset {
    dynamic "domain_rules" {
      for_each = local.domain_rules
      content {
        name     = domain_rules.value.name
        kind     = domain_rules.value.kind
        type     = domain_rules.value.type
        mode     = domain_rules.value.mode
        expr     = try(domain_rules.value.expr, "")
        disabled = try(domain_rules.value.disabled, false)

        on_failure = try(domain_rules.value.onFailure, "ERROR")
        on_success = try(domain_rules.value.onSuccess, "NONE")

        params = try(domain_rules.value.params, {})
      }
    }
  }

  credentials {
    key    = local.sr_api_key
    secret = local.sr_api_secret
  }

  lifecycle {
    prevent_destroy = false
  }
}
