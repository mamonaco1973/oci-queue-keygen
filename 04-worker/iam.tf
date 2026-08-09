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

  # Match compute instances with the `instance.*` variables — NOT `resource.type`.
  # `resource.type = 'instance'` is NOT a valid match for a compute instance
  # (that form works for service principals like functions, where the type is
  # 'fnfunc'); with it the VM's instance principal gets 404 NotAuthorizedOrNotFound
  # on every authorized call. `instance.compartment.id` is the canonical form and
  # was verified to resolve for this VM (direct NoSQL get_table succeeded once the
  # DG used it, with no temporary any-user policy in play).
  # Deliberately NO depends_on the instance: the rule matches by compartment, so
  # the DG doesn't need the VM to exist. Creating the DG + policy FIRST lets the
  # grant propagate during instance provisioning + cloud-init (minutes of head
  # start), so NoSQL authz is usually live before the daemon's first run — which
  # avoids the instance-principal token booting before the grant is recognized.
  matching_rule = "ALL {instance.compartment.id = '${var.compartment_id}'}"
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
