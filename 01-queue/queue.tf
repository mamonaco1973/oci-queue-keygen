# ==============================================================================
# OCI Queue — async message bus (SQS analog)
# ==============================================================================
# The post function publishes keygen requests here; an always-on consumer on a
# micro-VM (04-worker) long-polls the queue and generates the keys.
#
# Why a VM consumer instead of a serverless trigger: OCI has no native
# "message → invoke Function" trigger. OCI Queue cannot source Service Connector
# Hub, and SCH (the only thing that can invoke Functions) batches on a 60s-minimum
# window — far too slow. A consumer that long-polls the queue receives messages
# within milliseconds, so the worker runs on a cheap always-free instance.
# ==============================================================================

resource "oci_queue_queue" "keygen" {
  compartment_id = var.compartment_id
  display_name   = "keygen-requests"

  # Visibility timeout: how long a consumed message is hidden while the worker
  # processes it before it becomes redeliverable. 60s comfortably covers even
  # RSA-4096 generation.
  visibility_in_seconds = 60

  # Retention: drop unprocessed messages after a day (matches the AWS design).
  retention_in_seconds = 86400

  # Default long-poll wait applied to GetMessages calls that don't specify one.
  timeout_in_seconds = 30

  # Redeliver a poison message a few times, then drop it (no DLQ for the demo).
  dead_letter_queue_delivery_count = 5
}
