variable "confluent_cloud_api_key" {
  description = "Confluent Cloud API Key"
  type        = string
  sensitive   = true
}

variable "confluent_cloud_api_secret" {
  description = "Confluent Cloud API Secret"
  type        = string
  sensitive   = true
}

variable "environment_display_name" {
  description = "Confluent Cloud environment display name created by 01-platform."
  type        = string
  default     = "jsoto_demo_esquemas"
}

variable "kafka_cluster_display_name" {
  description = "Confluent Cloud Kafka cluster display name created by 01-platform."
  type        = string
  default     = "kafka_demo"
}

# Optional Kafka credentials for provider validation (not actually used)
variable "kafka_api_key" {
  description = "Kafka API Key (optional, for provider validation)"
  type        = string
  default     = ""
}

variable "kafka_api_secret" {
  description = "Kafka API Secret (optional, for provider validation)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "kafka_rest_endpoint" {
  description = "Kafka REST endpoint (optional, for provider validation)"
  type        = string
  default     = ""
}

variable "kafka_id" {
  description = "Kafka cluster ID (optional, for provider validation)"
  type        = string
  default     = ""
}
