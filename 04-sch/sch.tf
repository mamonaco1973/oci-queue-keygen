# ==============================================================================
# Connector Hub — Queue source → Functions target
# ==============================================================================
# OCI's official bridge from a queue to compute.  Note what it is NOT: there is
# no "invoke on message arrival" semantic here.  The connector polls the source
# and flushes a batch when either the size or the time threshold is reached.
# The timer starts with the first message of a batch, so at the default size a
# lone request waits the FULL window — see the measurements in main.tf.
# ==============================================================================

resource "oci_sch_service_connector" "keygen" {
  compartment_id = var.compartment_id
  display_name   = "keygen-queue-to-function"
  description    = "Reads keygen requests from the Queue and invokes the worker"

  # ----------------------------------------------------------------------------
  # Source — the queue, addressed through the plugin interface
  # ----------------------------------------------------------------------------
  # Queue sources are modelled as a connector *plugin*, not a first-class kind
  # like logging/streaming, so the queue OCID travels inside config_map rather
  # than a dedicated attribute.  config_map is a JSON string in the provider,
  # hence jsonencode rather than a bare map.
  # ----------------------------------------------------------------------------
  source {
    kind        = "plugin"
    plugin_name = "QueueSource"
    config_map  = jsonencode({ queueId = var.queue_id })
  }

  # ----------------------------------------------------------------------------
  # Target — the worker function
  # ----------------------------------------------------------------------------
  # Only one of batch_size_in_kbs / batch_size_in_num may be set; messages here
  # are a few hundred bytes, so a size threshold in KB would never trigger and
  # the 60s time limit would govern every flush.  Counting messages is the only
  # remaining way to ask for a faster flush — batch_time_in_sec cannot go below
  # 60 (see main.tf).
  # ----------------------------------------------------------------------------
  target {
    kind              = "functions"
    function_id       = oci_functions_function.worker.id
    batch_time_in_sec = var.batch_time_in_sec
    batch_size_in_num = var.batch_size_in_num
  }

  # The connector starts reading the moment it is ACTIVE; without the policy in
  # place first it would fail its reads and surface as a dead pipeline rather
  # than an auth error.
  depends_on = [oci_identity_policy.connector]
}
