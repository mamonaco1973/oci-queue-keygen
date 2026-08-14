# ==============================================================================
# IAM — Dynamic Group and data policy for the Functions tier
# ==============================================================================
# These live in Phase 1, several minutes before the Functions they apply to are
# created in Phase 3, and that placement is the whole point.
#
# A Function's Resource Principal token caches its dynamic-group membership at
# the moment its container starts.  When the DG was created alongside the
# Functions, the first container could boot before the DG had propagated; it
# then held a token belonging to no group, and every authorized call returned
# 404 NotAuthorizedOrNotFound for as long as that container stayed warm.
# Widening the policy does not help — the token is not in the group at all —
# and neither does waiting, because the container never re-reads it.  Only a
# new container gets a new token.
#
# Creating the DG here buys the rest of the build (image push, Functions, NoSQL,
# gateway, web app) as propagation time, so the first container to start is
# already a member.  validate.sh still recycles the function if it sees the
# signature, but that is now a backstop rather than the normal path.
#
# The faas service policy and the API Gateway invoke policy stay in
# 03-functions: both are service principals, not dynamic groups, so neither is
# subject to this race.
# ==============================================================================

# ------------------------------------------------------------------------------
# Dynamic Group — matches all Functions in the compartment
# ------------------------------------------------------------------------------
resource "oci_identity_dynamic_group" "keygen_functions" {
  compartment_id = var.tenancy_ocid # Dynamic groups live at the tenancy root
  name           = "keygen-functions-dg"
  description    = "OCI Functions in the keygen compartment (Resource Principal auth)"

  # ALL{} syntax required for Identity Domain-enabled tenancies (IDCS backend).
  # Functions match on resource.type = 'fnfunc'; compute instances would need
  # the instance.* form instead, which is a separate trap.
  matching_rule = "ALL {resource.type = 'fnfunc', resource.compartment.id = '${var.compartment_id}'}"
}

# ------------------------------------------------------------------------------
# Policy — Functions can read/write NoSQL and publish to the Queue
# ------------------------------------------------------------------------------
# get reads NoSQL rows, the worker writes them, and post puts messages on the
# queue.  The dynamic group is referenced by name rather than by attribute, so
# Terraform cannot infer the ordering — hence the explicit depends_on.
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

  depends_on = [oci_identity_dynamic_group.keygen_functions]
}
