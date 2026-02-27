output "compute_pool_id" {
  description = "Flink compute pool ID"
  value       = confluent_flink_compute_pool.unified_demo.id
}

output "flink_rest_endpoint" {
  description = "Flink REST endpoint for the selected region"
  value       = data.confluent_flink_region.main.rest_endpoint
}

output "flink_api_key_id" {
  description = "Flink API key ID used to execute statements"
  value       = confluent_api_key.flink_api_key.id
  sensitive   = true
}

output "flink_api_key_secret" {
  description = "Flink API key secret used to execute statements"
  value       = confluent_api_key.flink_api_key.secret
  sensitive   = true
}
