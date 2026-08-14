# ==============================================================================
# IAM — Dynamic Group and Policies (API surface)
# ==============================================================================
# Grants required by the Functions/API tier:
#
# 1. faas service → OCIR + VCN
#    The Functions runtime must pull images from OCIR and attach containers to
#    the VCN subnet, or functions fail to cold-start (502).
#
# 2. API Gateway → Functions
#    Service-principal policy allowing API Gateway to invoke the functions.
#
# Both are SERVICE principals, so neither depends on dynamic-group membership
# and neither is subject to the token-caching race that moved the Functions
# dynamic group into 01-queue/iam.tf (see the note below).
#
# The worker VM's own dynamic group + policies live in 04-worker/iam.tf.
# Tenancy-scoped policies are created in the root compartment
# (var.tenancy_ocid), not a child compartment.
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
# Moved out: Dynamic Group + Functions data policy
# ------------------------------------------------------------------------------
# `keygen-functions-dg` and `keygen-functions-data` now live in 01-queue/iam.tf.
# A Resource Principal token caches its dynamic-group membership when the
# container starts, so a DG created here — in the same phase as the Functions —
# could lose the race and strand the first container with a groupless token.
# Creating it a phase earlier gives it the rest of the build to propagate.
# ------------------------------------------------------------------------------

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
