# ==============================================================================
# IAM — Connector Hub service principal
# ==============================================================================
# A connector authenticates as the serviceconnector principal, not as a dynamic
# group: there is no resource to match on, so grants are expressed as any-user
# rules narrowed by request.principal.type.  This is the mirror image of
# 04-worker/iam.tf, where the VM's grants hang off an instance-matching DG.
#
# Tenancy-scoped policies must be created in the root compartment.
# ==============================================================================

resource "oci_identity_policy" "connector" {
  compartment_id = var.tenancy_ocid
  name           = "keygen-connector-hub"
  description    = "Allow Connector Hub to read the Queue and invoke the worker"

  statements = [
    # Reading a queue source consumes and deletes messages, which `use queues`
    # does not cover (it grants QUEUE_PUT only) — the same distinction that
    # forces `manage queues` for the VM consumer.
    join(" ", [
      "Allow any-user to manage queues in compartment id ${var.compartment_id}",
      "where ALL {",
      "  request.principal.type = 'serviceconnector',",
      "  request.principal.compartment.id = '${var.compartment_id}'",
      "}",
    ]),
    join(" ", [
      "Allow any-user to use functions-family in compartment id ${var.compartment_id}",
      "where ALL {",
      "  request.principal.type = 'serviceconnector',",
      "  request.principal.compartment.id = '${var.compartment_id}'",
      "}",
    ]),
  ]
}
