# ==============================================================================
# Outputs
# ==============================================================================
# The batch settings are echoed so the deploy log records what the timings in
# the browser console were actually measured against.
# ==============================================================================

output "connector_id" {
  description = "OCID of the Queue-to-Functions connector"
  value       = oci_sch_service_connector.keygen.id
}

output "connector_state" {
  description = "Lifecycle state of the connector (must be ACTIVE to deliver)"
  value       = oci_sch_service_connector.keygen.state
}

output "worker_function_id" {
  description = "OCID of the worker function invoked by the connector"
  value       = oci_functions_function.worker.id
}

output "batch_settings" {
  description = "Batch thresholds this deployment was measured with"
  value       = "batch_time_in_sec=${var.batch_time_in_sec} batch_size_in_num=${var.batch_size_in_num}"
}
