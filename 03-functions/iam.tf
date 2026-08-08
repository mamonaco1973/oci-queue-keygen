# ==============================================================================
# IAM — Dynamic Group and Policies (API surface)
# ==============================================================================
# Grants required by the Functions/API tier:
#
# 1. faas service → OCIR + VCN
#    The Functions runtime must pull images from OCIR and attach containers to
#    the VCN subnet, or functions fail to cold-start (502).
#
# 2. Functions → NoSQL + Queue
#    A Dynamic Group matches all Functions in the compartment.  Policies let the
#    get function read NoSQL and the post function publish to the Queue.
#    The Resource Principal signer in func.py relies on these.
#
# 3. API Gateway → Functions
#    Service-principal policy allowing API Gateway to invoke the functions.
#
# The worker VM's own dynamic group + policies live in 04-worker/iam.tf.
# Dynamic groups and tenancy-scoped policies are created in the root
# compartment (var.tenancy_ocid), not a child compartment.
# ==============================================================================

# ------------------------------------------------------------------------------
# Policy — faas service can pull OCIR images and attach to the VCN
# ------------------------------------------------------------------------------
resource "oci_identity_policy" "faas_infra" {
  compartment_id = var.tenancy_ocid
  name           = "keygen-faas-infra"
  description    = "Allow OCI Functions runtime to pull OCIR images and use VCN"

  statements = [
    "Allow service faas to read repos in tenancy",
    "Allow service faas to use virtual-network-family in compartment id ${var.compartment_id}",
  ]
}

# ------------------------------------------------------------------------------
# Dynamic Group — matches all Functions in the compartment
# ------------------------------------------------------------------------------
resource "oci_identity_dynamic_group" "keygen_functions" {
  compartment_id = var.tenancy_ocid # Dynamic groups live at the tenancy root
  name           = "keygen-functions-dg"
  description    = "OCI Functions in the keygen compartment (Resource Principal auth)"

  # ALL{} syntax required for Identity Domain-enabled tenancies (IDCS backend).
  matching_rule = "ALL {resource.type = 'fnfunc', resource.compartment.id = '${var.compartment_id}'}"
}

# ------------------------------------------------------------------------------
# Policy — Functions can read NoSQL and publish to the Queue
# ------------------------------------------------------------------------------
# get reads NoSQL rows; post puts messages on the queue.  `use queues` covers
# QUEUE_PUT; the consume/delete side is the VM consumer's grant (see 04-worker).
# ------------------------------------------------------------------------------
resource "oci_identity_policy" "functions_data" {
  compartment_id = var.tenancy_ocid
  name           = "keygen-functions-data"
  description    = "Allow keygen functions to read NoSQL and publish to the Queue"

  statements = [
    "Allow dynamic-group keygen-functions-dg to manage nosql-rows in compartment id ${var.compartment_id}",
    "Allow dynamic-group keygen-functions-dg to use nosql-tables in compartment id ${var.compartment_id}",
    "Allow dynamic-group keygen-functions-dg to use queues in compartment id ${var.compartment_id}",
  ]
}

# ------------------------------------------------------------------------------
# Policy — API Gateway can invoke Functions
# ------------------------------------------------------------------------------
resource "oci_identity_policy" "apigateway_functions" {
  compartment_id = var.tenancy_ocid
  name           = "keygen-apigateway-invoke"
  description    = "Allow API Gateway to invoke keygen functions"

  statements = [
    join(" ", [
      "Allow any-user to use functions-family in compartment id ${var.compartment_id}",
      "where ALL {",
      "  request.principal.type = 'ApiGateway',",
      "  request.resource.compartment.id = '${var.compartment_id}'",
      "}",
    ]),
  ]
}
