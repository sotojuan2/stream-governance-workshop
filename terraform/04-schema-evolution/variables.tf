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

variable "managed_schema_variant" {
  description = "Which managed schema v2 to apply: 'bad' (no default) or 'good' (with default)."
  type        = string
  default     = "good"

  validation {
    condition     = contains(["bad", "good"], var.managed_schema_variant)
    error_message = "managed_schema_variant must be 'bad' or 'good'."
  }
}

variable "enable_unmanaged_breaking" {
  description = "When true, apply a breaking schema evolution to the unmanaged subject (compatibility NONE)."
  type        = bool
  default     = false
}

