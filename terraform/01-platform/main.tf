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
  # Resources use inline credentials when needed
  kafka_api_key       = try(var.kafka_api_key, "")
  kafka_api_secret    = try(var.kafka_api_secret, "")
  kafka_rest_endpoint = try(var.kafka_rest_endpoint, "")
  kafka_id            = try(var.kafka_id, "")
}

# 1. Environment with Stream Governance
resource "confluent_environment" "demo" {
  display_name = var.environment_display_name

  stream_governance {
    package = "ADVANCED"
  }
}

# 2. Kafka Cluster
resource "confluent_kafka_cluster" "basic" {
  display_name = var.kafka_cluster_display_name
  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = "eu-central-1"
  basic {}

  environment {
    id = confluent_environment.demo.id
  }
}

# 3. Service Accounts
resource "confluent_service_account" "sa_gestionado" {
  display_name = "sa_gestionado"
  description  = "Account for managed topic"
}

resource "confluent_service_account" "sa_mal_gestionado" {
  display_name = "sa_mal_gestionado"
  description  = "Account for topic with poorly evolved schemas"
}

resource "confluent_service_account" "sa_sin_schema" {
  display_name = "sa_sin_schema"
  description  = "Account for topic without schema registry"
}

# 4. Role Bindings (for cluster-level admin access)
# Note: Basic clusters only support cluster-level roles, not resource-level roles
resource "confluent_role_binding" "cluster_admin" {
  principal   = "User:${confluent_service_account.sa_gestionado.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.basic.rbac_crn
}

# ==============================================================================
# SCHEMA REGISTRY ROLE BINDING
# ==============================================================================
# NOTE: Schema Registry takes 1-2 minutes to provision after environment creation
# These resources are now enabled after waiting period
# ==============================================================================

data "confluent_schema_registry_cluster" "essentials" {
  environment {
    id = confluent_environment.demo.id
  }
}

resource "confluent_role_binding" "sr_resource_owner" {
  principal   = "User:${confluent_service_account.sa_gestionado.id}"
  role_name   = "ResourceOwner"
  crn_pattern = "${data.confluent_schema_registry_cluster.essentials.resource_name}/subject=*"
}

# 5. Kafka API Key
resource "confluent_api_key" "sa_gestionado_kafka_api" {
  display_name = "sa_gestionado_kafka_api"
  description  = "API Key for Kafka"
  owner {
    id          = confluent_service_account.sa_gestionado.id
    api_version = confluent_service_account.sa_gestionado.api_version
    kind        = confluent_service_account.sa_gestionado.kind
  }
  managed_resource {
    id          = confluent_kafka_cluster.basic.id
    api_version = confluent_kafka_cluster.basic.api_version
    kind        = confluent_kafka_cluster.basic.kind
    environment { id = confluent_environment.demo.id }
  }
  depends_on = [
    confluent_role_binding.cluster_admin
  ]
}

# 6. Kafka ACLs (for Basic cluster - RBAC not fully supported)
# These ACLs grant broad permissions. Specific topic ACLs should be in 02-application

# Allow service account to describe the cluster
resource "confluent_kafka_acl" "sa_describe_cluster" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "CLUSTER"
  resource_name = "kafka-cluster"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.sa_gestionado.id}"
  host          = "*"
  operation     = "DESCRIBE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.sa_gestionado_kafka_api.id
    secret = confluent_api_key.sa_gestionado_kafka_api.secret
  }
}

# Allow service account to create topics
resource "confluent_kafka_acl" "sa_create_topics" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "CLUSTER"
  resource_name = "kafka-cluster"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.sa_gestionado.id}"
  host          = "*"
  operation     = "CREATE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.sa_gestionado_kafka_api.id
    secret = confluent_api_key.sa_gestionado_kafka_api.secret
  }
}

# Allow service account to read/write all topics (wildcard)
resource "confluent_kafka_acl" "sa_read_topics" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "TOPIC"
  resource_name = "*"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.sa_gestionado.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.sa_gestionado_kafka_api.id
    secret = confluent_api_key.sa_gestionado_kafka_api.secret
  }
}

resource "confluent_kafka_acl" "sa_write_topics" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "TOPIC"
  resource_name = "*"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.sa_gestionado.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.sa_gestionado_kafka_api.id
    secret = confluent_api_key.sa_gestionado_kafka_api.secret
  }
}

# Allow service account to read consumer groups
resource "confluent_kafka_acl" "sa_read_groups" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "GROUP"
  resource_name = "*"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.sa_gestionado.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.sa_gestionado_kafka_api.id
    secret = confluent_api_key.sa_gestionado_kafka_api.secret
  }
}


