terraform {
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "~> 1.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key    # API Key de Confluent Cloud
  cloud_api_secret = var.confluent_cloud_api_secret # API Secret de Confluent Cloud
}

# 1. Entorno
resource "confluent_environment" "demo" {
  display_name = "jsoto_demo_esquemas"

  stream_governance {
    package = "ESSENTIALS"
  }
}


resource "confluent_kafka_cluster" "basic" {
  display_name = "kafka_demo"
  availability = "SINGLE_ZONE" # Basic sólo admite una zona
  cloud        = "AWS"
  region       = "eu-central-1" # Región europea (Fráncfort)
  basic {}                      # Tipo de clúster Basic

  environment {
    id = confluent_environment.demo.id
  }

}


resource "confluent_service_account" "sa_gestionado" {
  display_name = "sa_gestionado"
  description  = "Cuenta para topic gestionado"
}

resource "confluent_service_account" "sa_mal_gestionado" {
  display_name = "sa_mal_gestionado"
  description  = "Cuenta para topic con esquemas mal evolucionados"
}

resource "confluent_service_account" "sa_sin_schema" {
  display_name = "sa_sin_schema"
  description  = "Cuenta para topic sin schema registry"
}


resource "confluent_api_key" "sa_gestionado_kafka_api" {
  display_name = "sa_gestionado_kafka_api"
  description  = "API Key para Kafka"
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
    confluent_role_binding.sa_gestionado_write,
    confluent_role_binding.sa_gestionado_read
  ]
}


# Rol de administrador para gestionar el clúster (opcional)
resource "confluent_role_binding" "cluster_admin" {
  principal   = "User:${confluent_service_account.sa_gestionado.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.basic.rbac_crn
}

# Permisos de escritura para sa_gestionado
resource "confluent_role_binding" "sa_gestionado_write" {
  principal   = "User:${confluent_service_account.sa_gestionado.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.basic.rbac_crn}/kafka=${confluent_kafka_cluster.basic.id}/topic=gestionado"
}

# Permisos de lectura para sa_gestionado
resource "confluent_role_binding" "sa_gestionado_read" {
  principal   = "User:${confluent_service_account.sa_gestionado.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.basic.rbac_crn}/kafka=${confluent_kafka_cluster.basic.id}/topic=gestionado"
}

resource "confluent_kafka_topic" "gestionado" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  topic_name    = "gestionado"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.sa_gestionado_kafka_api.id
    secret = confluent_api_key.sa_gestionado_kafka_api.secret
  }
}

# Schema Registry - Se crea automáticamente con stream_governance pero necesitamos esperar
# Usar sleep para dar tiempo a que se provisione
resource "time_sleep" "wait_for_schema_registry" {
  depends_on      = [confluent_environment.demo]
  create_duration = "60s"
}

data "confluent_schema_registry_cluster" "essentials" {
  environment {
    id = confluent_environment.demo.id
  }

  depends_on = [time_sleep.wait_for_schema_registry]
}

# API Key para Schema Registry
resource "confluent_api_key" "sa_gestionado_sr_api" {
  display_name = "sa_gestionado_sr_api"
  description  = "API Key para Schema Registry"
  owner {
    id          = confluent_service_account.sa_gestionado.id
    api_version = confluent_service_account.sa_gestionado.api_version
    kind        = confluent_service_account.sa_gestionado.kind
  }
  managed_resource {
    id          = data.confluent_schema_registry_cluster.essentials.id
    api_version = data.confluent_schema_registry_cluster.essentials.api_version
    kind        = data.confluent_schema_registry_cluster.essentials.kind
    environment { id = confluent_environment.demo.id }
  }
}

resource "confluent_schema" "gestionado_schema_v1" {
  schema_registry_cluster {
    id = data.confluent_schema_registry_cluster.essentials.id
  }
  rest_endpoint = data.confluent_schema_registry_cluster.essentials.rest_endpoint
  subject_name  = "gestionado-value" # nombre de la subject en Schema Registry
  format        = "AVRO"
  schema        = file("./schemas/gestionado_v1.avsc")
  credentials {
    key    = confluent_api_key.sa_gestionado_sr_api.id
    secret = confluent_api_key.sa_gestionado_sr_api.secret
  }
}


resource "confluent_subject_config" "gestionado_config" {
  schema_registry_cluster {
    id = data.confluent_schema_registry_cluster.essentials.id
  }
  rest_endpoint       = data.confluent_schema_registry_cluster.essentials.rest_endpoint
  subject_name        = "gestionado-value"
  compatibility_level = "BACKWARD" # admite cambios compatibles hacia atrás
  credentials {
    key    = confluent_api_key.sa_gestionado_sr_api.id
    secret = confluent_api_key.sa_gestionado_sr_api.secret
  }
}

resource "confluent_subject_config" "mal_gestionado_config" {
  schema_registry_cluster {
    id = data.confluent_schema_registry_cluster.essentials.id
  }
  rest_endpoint       = data.confluent_schema_registry_cluster.essentials.rest_endpoint
  subject_name        = "mal_gestionado-value"
  compatibility_level = "BACKWARD" # se mantendrá aunque luego hagamos cambios incompatibles
  credentials {
    key    = confluent_api_key.sa_gestionado_sr_api.id
    secret = confluent_api_key.sa_gestionado_sr_api.secret
  }
}
