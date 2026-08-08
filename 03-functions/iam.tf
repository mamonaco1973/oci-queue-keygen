# ==============================================================================
# IAM — Dynamic Group and Policies
# ==============================================================================
# Grants required by this deployment:
#
# 1. faas service → OCIR + VCN
#    The Functions runtime must pull images from OCIR and attach containers to
#    the VCN subnet, or functions fail to cold-start (502).
#
# 2. Functions → NoSQL + Streaming
#    A Dynamic Group matches all Functions in the compartment.  Policies let
#    them manage NoSQL rows (get/worker) and publish to Streaming (post).
#    The Resource Principal signer in func.py relies on these.
#
# 3. API Gateway → Functions
#    Service-principal policy allowing API Gateway to invoke the functions.
#
# 4. Service Connector Hub → Streaming + Functions
#    Service-principal policies allowing the connector to read the stream and
#    invoke the worker function (the async trigger).
#
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
# Policy — Functions can manage NoSQL rows and publish to Streaming
# ------------------------------------------------------------------------------
# manage streams covers STREAM_PUSH used by the post function's put_messages.
# ------------------------------------------------------------------------------
resource "oci_identity_policy" "functions_data" {
  compartment_id = var.tenancy_ocid
  name           = "keygen-functions-data"
  description    = "Allow keygen functions to use NoSQL and Streaming"

  statements = [
    "Allow dynamic-group keygen-functions-dg to manage nosql-rows in compartment id ${var.compartment_id}",
    "Allow dynamic-group keygen-functions-dg to use nosql-tables in compartment id ${var.compartment_id}",
    "Allow dynamic-group keygen-functions-dg to manage streams in compartment id ${var.compartment_id}",
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

# ------------------------------------------------------------------------------
# Policy — Service Connector Hub can read the stream
# ------------------------------------------------------------------------------
# Scoped to the serviceconnector principal type; the connector consumes stream
# messages to forward to the worker function.
# ------------------------------------------------------------------------------
resource "oci_identity_policy" "sch_stream_read" {
  compartment_id = var.tenancy_ocid
  name           = "keygen-sch-stream-read"
  description    = "Allow Service Connector Hub to read the keygen stream"

  statements = [
    join(" ", [
      "Allow any-user to {STREAM_READ, STREAM_CONSUME} in compartment id ${var.compartment_id}",
      "where ALL {",
      "  request.principal.type = 'serviceconnector',",
      "  request.principal.compartment.id = '${var.compartment_id}'",
      "}",
    ]),
  ]
}

# ------------------------------------------------------------------------------
# Policy — Service Connector Hub can invoke the worker function
# ------------------------------------------------------------------------------
resource "oci_identity_policy" "sch_functions_invoke" {
  compartment_id = var.tenancy_ocid
  name           = "keygen-sch-functions-invoke"
  description    = "Allow Service Connector Hub to invoke the keygen worker"

  statements = [
    join(" ", [
      "Allow any-user to use fn-function in compartment id ${var.compartment_id}",
      "where ALL {",
      "  request.principal.type = 'serviceconnector',",
      "  request.principal.compartment.id = '${var.compartment_id}'",
      "}",
    ]),
    join(" ", [
      "Allow any-user to use fn-invocation in compartment id ${var.compartment_id}",
      "where ALL {",
      "  request.principal.type = 'serviceconnector',",
      "  request.principal.compartment.id = '${var.compartment_id}'",
      "}",
    ]),
  ]
}
