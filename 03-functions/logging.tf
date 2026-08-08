# ==============================================================================
# OCI Logging — Functions Application Resource Logs
# ==============================================================================
# Enables invoke logs on the Functions Application so function output
# (stdout/stderr, Python exceptions) is visible in the OCI Logging console.
# Especially useful for the worker, which runs off the API path and can only
# be observed through logs.
# ==============================================================================

resource "oci_logging_log_group" "keygen" {
  compartment_id = var.compartment_id
  display_name   = "keygen-log-group"
}

resource "oci_logging_log" "functions" {
  display_name = "keygen-functions-log"
  log_group_id = oci_logging_log_group.keygen.id
  log_type     = "SERVICE"

  configuration {
    source {
      category    = "invoke"
      resource    = oci_functions_application.keygen.id
      service     = "functions"
      source_type = "OCISERVICE"
    }
    compartment_id = var.compartment_id
  }

  is_enabled         = true
  retention_duration = 30
}
