# ==============================================================================
# Outputs
# ==============================================================================
# Consumed by apply.sh, which re-exports them as TF_VAR_* for 03-functions (the
# post function needs the OCID + endpoint to publish) and 04-worker (the consumer
# needs them to drain the queue).
# ==============================================================================

output "repository_name" {
  description = "OCIR repository display name"
  value       = oci_artifacts_container_repository.keygen.display_name
}

output "queue_id" {
  description = "OCID of the keygen requests queue"
  value       = oci_queue_queue.keygen.id
}

output "queue_endpoint" {
  description = "Messages endpoint the Queue SDK client uses (put/get/delete)"
  value       = oci_queue_queue.keygen.messages_endpoint
}
