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
  service_account_id = data.terraform_remote_state.platform.outputs.service_account_id

  flink_cloud  = "AWS"
  flink_region = "eu-central-1"
}

data "confluent_environment" "demo" {
  id = local.environment_id
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
