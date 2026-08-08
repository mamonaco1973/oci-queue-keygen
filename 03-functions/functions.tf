# ==============================================================================
# OCI Functions Application and Functions
# ==============================================================================
# One Functions Application and two Function resources, both sharing the same
# OCIR image (var.image_path).  FUNCTION_TYPE selects the handler at runtime:
#   post → API Gateway POST /keygen                       → publishes to Queue
#   get  → API Gateway GET /result/{id} and GET /heartbeat → reads NoSQL
#
# Key generation itself runs on the 04-worker VM consumer, not here.
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
# post — POST /keygen (publishes to the Queue)
# ------------------------------------------------------------------------------
# Needs the queue OCID + endpoint to publish; does not touch NoSQL.
# ------------------------------------------------------------------------------
resource "oci_functions_function" "post" {
  application_id     = oci_functions_application.keygen.id
  display_name       = "keygen-post"
  image              = var.image_path
  memory_in_mbs      = "256"
  timeout_in_seconds = 60

  config = {
    FUNCTION_TYPE  = "post"
    QUEUE_ID       = var.queue_id
    QUEUE_ENDPOINT = var.queue_endpoint
  }
}

# ------------------------------------------------------------------------------
# get — GET /result/{id} and GET /heartbeat (reads NoSQL)
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
