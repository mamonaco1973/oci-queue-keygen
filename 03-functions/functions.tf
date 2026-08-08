# ==============================================================================
# OCI Functions Application and Functions
# ==============================================================================
# One Functions Application and three Function resources, all sharing the same
# OCIR image (var.image_path).  FUNCTION_TYPE selects the handler at runtime:
#   post   → API Gateway POST /keygen        → publishes to Streaming
#   get    → API Gateway GET  /result/{id}   → reads NoSQL
#   worker → Service Connector Hub target    → generates keys, writes NoSQL
#
# The image is built and pushed by 02-docker/build.sh before terraform apply.
# ==============================================================================

# ------------------------------------------------------------------------------
# Functions Application — groups the functions under the shared VCN subnet
# ------------------------------------------------------------------------------
resource "oci_functions_application" "keygen" {
  compartment_id = var.compartment_id
  display_name   = "keygen-app"
  subnet_ids     = [oci_core_subnet.public.id]
}

# ------------------------------------------------------------------------------
# post — POST /keygen (publishes to Streaming)
# ------------------------------------------------------------------------------
# Needs the stream OCID + endpoint to publish; does not touch NoSQL.
# ------------------------------------------------------------------------------
resource "oci_functions_function" "post" {
  application_id     = oci_functions_application.keygen.id
  display_name       = "keygen-post"
  image              = var.image_path
  memory_in_mbs      = "256"
  timeout_in_seconds = 60

  config = {
    FUNCTION_TYPE   = "post"
    STREAM_ID       = var.stream_id
    STREAM_ENDPOINT = var.stream_endpoint
  }
}

# ------------------------------------------------------------------------------
# get — GET /result/{id} (reads NoSQL)
# ------------------------------------------------------------------------------
resource "oci_functions_function" "get" {
  application_id     = oci_functions_application.keygen.id
  display_name       = "keygen-get"
  image              = var.image_path
  memory_in_mbs      = "256"
  timeout_in_seconds = 60

  config = {
    FUNCTION_TYPE    = "get"
    NOSQL_TABLE_NAME = oci_nosql_table.keygen_results.name
    COMPARTMENT_ID   = var.compartment_id
  }
}

# ------------------------------------------------------------------------------
# worker — Service Connector Hub target (CPU-bound key generation)
# ------------------------------------------------------------------------------
# More memory + a longer timeout than the API functions: RSA-4096 generation is
# CPU-heavy and must finish inside the invocation window.
# ------------------------------------------------------------------------------
resource "oci_functions_function" "worker" {
  application_id     = oci_functions_application.keygen.id
  display_name       = "keygen-worker"
  image              = var.image_path
  memory_in_mbs      = "1024"
  timeout_in_seconds = 120

  config = {
    FUNCTION_TYPE    = "worker"
    NOSQL_TABLE_NAME = oci_nosql_table.keygen_results.name
    COMPARTMENT_ID   = var.compartment_id
  }
}
