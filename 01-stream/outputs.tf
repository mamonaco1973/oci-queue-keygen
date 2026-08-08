# ==============================================================================
# Outputs
# ==============================================================================
# Consumed by apply.sh, which re-exports them as TF_VAR_* for 03-functions
# (the post function needs the OCID + endpoint to publish; the Service Connector
# needs the OCID to source from).
# ==============================================================================

output "repository_name" {
  description = "OCIR repository display name"
  value       = oci_artifacts_container_repository.keygen.display_name
}

output "stream_id" {
  description = "OCID of the keygen requests stream"
  value       = oci_streaming_stream.keygen.id
}

output "stream_endpoint" {
  description = "Messages endpoint the Streaming SDK client posts to"
  value       = oci_streaming_stream.keygen.messages_endpoint
}
