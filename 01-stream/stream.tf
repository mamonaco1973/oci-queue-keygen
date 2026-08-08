# ==============================================================================
# OCI Streaming — async message bus (SQS analog)
# ==============================================================================
# The post function publishes keygen requests here; a Service Connector Hub
# (defined in 03-functions) drains the stream and invokes the worker function.
# OCI has no "message → invoke Function" trigger for the Queue service, so
# Streaming is used because it is the only Service Connector source that can
# target Functions — this preserves AWS's SQS→Lambda event-source-mapping model.
# ==============================================================================

# ------------------------------------------------------------------------------
# Stream pool — owns the streaming endpoint the SDK/Service Connector talk to
# ------------------------------------------------------------------------------
# A dedicated pool (rather than the tenancy default) gives us a stable, named
# messages endpoint to hand the post function via config.
# ------------------------------------------------------------------------------
resource "oci_streaming_stream_pool" "keygen" {
  compartment_id = var.compartment_id
  name           = "keygen-pool"
}

# ------------------------------------------------------------------------------
# Stream — single partition is sufficient for the demo's request volume
# ------------------------------------------------------------------------------
# Default retention is 24h, matching the AWS queue's 86400s message retention.
# ------------------------------------------------------------------------------
resource "oci_streaming_stream" "keygen" {
  name           = "keygen-requests"
  partitions     = 1
  stream_pool_id = oci_streaming_stream_pool.keygen.id
}
