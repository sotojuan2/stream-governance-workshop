# Outputs to pass to 02-application

output "environment_id" {
  description = "Confluent Environment ID"
  value       = confluent_environment.demo.id
}

output "kafka_cluster_id" {
  description = "Kafka Cluster ID"
  value       = confluent_kafka_cluster.basic.id
}

output "kafka_rest_endpoint" {
  description = "Kafka REST Endpoint"
  value       = confluent_kafka_cluster.basic.rest_endpoint
}

# Schema Registry outputs (enabled after SR provisioning)
output "schema_registry_id" {
  description = "Schema Registry Cluster ID"
  value       = data.confluent_schema_registry_cluster.essentials.id
}

output "schema_registry_rest_endpoint" {
  description = "Schema Registry REST Endpoint"
  value       = data.confluent_schema_registry_cluster.essentials.rest_endpoint
}

output "service_account_id" {
  description = "Service Account ID for managed application"
  value       = confluent_service_account.sa_gestionado.id
}

output "kafka_api_key" {
  description = "Kafka API Key"
  value       = confluent_api_key.sa_gestionado_kafka_api.id
}

output "kafka_api_secret" {
  description = "Kafka API Secret"
  value       = confluent_api_key.sa_gestionado_kafka_api.secret
  sensitive   = true
}

# output "sr_api_key" {
#   description = "Schema Registry API Key"
#   value       = confluent_api_key.sa_gestionado_sr_api.id
# }

# output "sr_api_secret" {
#   description = "Schema Registry API Secret"
#   value       = confluent_api_key.sa_gestionado_sr_api.secret
#   sensitive   = true
# }
