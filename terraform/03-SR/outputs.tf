# Schema Registry outputs
output "schema_registry_id" {
  description = "Schema Registry cluster ID"
  value       = local.schema_registry_id
}

output "schema_registry_rest_endpoint" {
  description = "Schema Registry REST endpoint"
  value       = local.schema_registry_rest_endpoint
}

output "sr_api_key" {
  description = "Schema Registry API key"
  value       = confluent_api_key.sa_gestionado_sr_api.id
}

output "sr_api_secret" {
  description = "Schema Registry API secret"
  value       = confluent_api_key.sa_gestionado_sr_api.secret
  sensitive   = true
}

# Instructions for getting the secret value
output "sr_credentials_command" {
  description = "Command to view sensitive SR API secret"
  value       = "terraform output -raw sr_api_secret"
}
