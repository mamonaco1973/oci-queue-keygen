# ==============================================================================
# Service Connector Hub — Streaming source → worker Function target
# ==============================================================================
# This is the async trigger: the connector reads messages off the keygen stream
# and invokes the worker function with each batch.  It replaces AWS's SQS→Lambda
# event-source mapping.  OCI Queue cannot be a Service Connector source — only
# Streaming can target Functions — which is why the bus is Streaming (Phase 1).
#
# The IAM grants that let the connector read the stream and invoke the function
# live in iam.tf; depends_on ensures they exist before the connector validates.
# ==============================================================================

resource "oci_sch_service_connector" "keygen" {
  compartment_id = var.compartment_id
  display_name   = "keygen-stream-to-worker"

  # --- Source: the keygen requests stream --------------------------------------
  source {
    kind      = "streaming"
    stream_id = var.stream_id

    # LATEST: process only messages published after the connector is live, so a
    # redeploy does not reprocess historical requests (results are idempotent by
    # correlation_id anyway, but this avoids needless work).
    cursor {
      kind = "LATEST"
    }
  }

  # --- Target: the worker function ---------------------------------------------
  target {
    kind        = "functions"
    function_id = oci_functions_function.worker.id

    # Responsiveness knobs: a small size floor + the minimum time window so a
    # single ~200-byte request is delivered promptly rather than waiting to
    # accumulate a large batch.  Worst-case dispatch latency ≈ batch_time_in_sec.
    batch_size_in_kbs = 1
    batch_time_in_sec = 60
  }

  # IAM policies must be in place before the connector can validate its access
  # to the stream (read) and the function (invoke).
  depends_on = [
    oci_identity_policy.sch_stream_read,
    oci_identity_policy.sch_functions_invoke,
  ]
}
