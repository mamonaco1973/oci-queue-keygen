# ==============================================================================
# OCI Queue — async message bus
# ==============================================================================
# The post function publishes keygen requests here.  What drains the queue
# depends on PROCESSING_MODE:
#
#   sch (default) — Connector Hub reads this queue, invoking a worker Function.
#   vm            — a long-polling consumer daemon on a micro-VM (04-worker).
#
# NOTE: an earlier version of this comment claimed Queue could not source
# Connector Hub and that SCH was pinned to a 60s window.  Both are wrong: Queue
# is a valid source, and Connector Hub flushes on whichever threshold is hit
# first — with batch_size_in_num = 1 it delivers in 1-2s.  See 04-sch/main.tf.
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

  # After this many delivery attempts a message moves to the queue's companion
  # dead letter queue, which OCI creates automatically — it is not discarded.
  dead_letter_queue_delivery_count = 5
}
