# ==============================================================================
# IAM — Worker instance principal
# ==============================================================================
# The consumer authenticates as the VM itself (instance principals).  A dynamic
# group matches this specific instance, and a policy grants it the queue-consume
# and NoSQL-write rights the daemon needs.  No credentials live on the box.
#
# Dynamic groups and tenancy-scoped policies must be created in the root
# compartment (var.tenancy_ocid).
# ==============================================================================

# ------------------------------------------------------------------------------
# Dynamic Group — matches only the worker instance (by OCID)
# ------------------------------------------------------------------------------
resource "oci_identity_dynamic_group" "worker" {
  compartment_id = var.tenancy_ocid
  name           = "keygen-workers-dg"
  description    = "KeyGen worker VM (instance principal auth)"

  # Match by compartment, not instance OCID: in this tenancy an `instance.id`
  # match does not resolve for the instance principal (the functions' compartment-
  # based DG works, a single-instance-id DG does not). This mirrors the working
  # functions DG pattern. `depends_on` keeps the instance created first.
  matching_rule = "ALL {instance.compartment.id = '${var.compartment_id}'}"
  depends_on    = [oci_core_instance.worker]
}

# ------------------------------------------------------------------------------
# Policy — worker can consume the Queue and write NoSQL results
# ------------------------------------------------------------------------------
# OCI Queue's `use queues` covers produce (QUEUE_PUT) but NOT QUEUE_CONSUME, so
# the consumer needs `manage queues` (get + delete messages). manage nosql-rows
# lets it write completed keypairs.
# ------------------------------------------------------------------------------
resource "oci_identity_policy" "worker" {
  compartment_id = var.tenancy_ocid
  name           = "keygen-worker-data"
  description    = "Allow the keygen worker VM to consume the Queue and write NoSQL"

  statements = [
    "Allow dynamic-group keygen-workers-dg to manage queues in compartment id ${var.compartment_id}",
    "Allow dynamic-group keygen-workers-dg to manage nosql-rows in compartment id ${var.compartment_id}",
    "Allow dynamic-group keygen-workers-dg to use nosql-tables in compartment id ${var.compartment_id}",
  ]
}
