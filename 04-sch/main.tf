# ==============================================================================
# Phase 4 (sch mode): Connector Hub — the serverless alternative to the VM
# ==============================================================================
# The counterpart to 04-worker.  Instead of a long-polling consumer on a VM,
# Connector Hub reads the Queue on a batch schedule and invokes a worker
# Function with the batch.  Exactly one of 04-worker / 04-sch is applied,
# selected by PROCESSING_MODE in apply.sh.
#
# This exists to make the latency claim measurable rather than asserted:
# Connector Hub is a batch data-movement service, not an event-source mapping,
# so end-to-end time is bounded below by the batch window plus a Function cold
# start.  Deploy both modes and compare the timing the web client logs.
#
# apply.sh supplies via TF_VAR after earlier phases complete:
#   TF_VAR_image_path                (02-docker)
#   TF_VAR_queue_id                  (01-queue)
#   TF_VAR_functions_application_id  (03-functions)
#   TF_VAR_nosql_table_name          (03-functions)
# ==============================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

provider "oci" {
  region = var.region
}

# ==============================================================================
# Variables
# ==============================================================================

variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy (root compartment)"
  type        = string
}

variable "compartment_id" {
  description = "OCID of the compartment where all resources are created"
  type        = string
}

variable "region" {
  description = "OCI region identifier (e.g., us-ashburn-1)"
  type        = string
}

variable "queue_id" {
  description = "OCID of the keygen requests queue (from 01-queue)"
  type        = string
}

variable "image_path" {
  description = "Full OCIR image path including tag (built by 02-docker/build.sh)"
  type        = string
}

variable "functions_application_id" {
  description = "OCID of the Functions Application to host the worker (03-functions)"
  type        = string
}

variable "nosql_table_name" {
  description = "OCI NoSQL table name results are written to (from 03-functions)"
  type        = string
}

# ------------------------------------------------------------------------------
# Batch tuning — the whole point of this mode
# ------------------------------------------------------------------------------
# 60s is a HARD FLOOR enforced by the API, not a soft default.  Setting 5 here
# is rejected at create time:
#
#   400-InvalidParameter, target.batchTimeInSec must be greater than or equal
#   to 60
#
# (Oracle's own queue-to-function doc shows a 5-second example.  It is wrong for
# this target.)  This is the measurement: a request arriving at a uniformly
# random point in a 60s window waits ~30s on average before compute even starts,
# which is why the VM long-poll exists.
#
# batch_size_in_num is therefore the only latency lever left.  Whether a size
# threshold of 1 short-circuits the time window — or the connector still waits
# out the full 60s — is exactly what deploying this mode measures.
# ------------------------------------------------------------------------------

variable "batch_time_in_sec" {
  description = "Connector Hub batch rollover time; API floor is 60s"
  type        = number
  default     = 60

  # Fail in plan rather than after a round trip to the create API.
  validation {
    condition     = var.batch_time_in_sec >= 60
    error_message = "Connector Hub rejects target.batchTimeInSec below 60."
  }
}

variable "batch_size_in_num" {
  description = "Messages per batch; 1 is the lowest-latency setting available"
  type        = number
  default     = 1
}
