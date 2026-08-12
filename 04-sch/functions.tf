# ==============================================================================
# Worker Function — Connector Hub's invocation target
# ==============================================================================
# Reuses the same OCIR image as post/get (FUNCTION_TYPE selects the handler),
# so switching modes needs no rebuild.  Hosted in the Functions Application
# created by 03-functions so it shares that VCN subnet and log configuration.
#
# NoSQL access needs no policy here: this function matches the
# keygen-functions-dg dynamic group from 03-functions, which already grants
# manage nosql-rows across the compartment.
# ==============================================================================

resource "oci_functions_function" "worker" {
  application_id = var.functions_application_id
  display_name   = "keygen-worker-fn"
  image          = var.image_path

  # RSA-4096 generation is CPU-bound and a batch can carry several requests;
  # OCI Functions scales CPU with memory, so this is sized for the worst case
  # rather than the median.  Undersizing here would penalise SCH mode for a
  # reason unrelated to Connector Hub.
  memory_in_mbs      = "1024"
  timeout_in_seconds = 300

  config = {
    FUNCTION_TYPE    = "worker"
    NOSQL_TABLE_NAME = var.nosql_table_name
    COMPARTMENT_ID   = var.compartment_id
  }
}
