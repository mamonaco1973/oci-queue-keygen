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
# MEASURED 2026-08-12, and it contradicts the obvious reading of the docs:
#
#   batch_size_in_num = 1,  batch_time_in_sec = 60  ->  1-2s end to end
#   a KB-based size threshold, batch_time_in_sec = 60 ->  ~30s end to end
#
# Connector Hub flushes on whichever threshold is reached FIRST.  With a size
# threshold of one message the batch is full the moment a message is read, so
# the timer never expires and batch_time_in_sec is effectively inert.  The
# residual 1-2s is the connector's own source-read interval plus the function
# invoke — not the batch window.
#
# This is why the ~30s originally observed here was a configuration artifact,
# not a service limit: a few-hundred-byte message never fills a KB-sized batch,
# so the time limit governed every flush and requests waited ~half of it.
#
# 60 remains an API-enforced floor on batch_time_in_sec (5 is rejected outright,
# despite Oracle's queue-to-function doc showing a 5-second example), but with
# batch_size_in_num = 1 that floor almost never binds.
# ------------------------------------------------------------------------------

variable "batch_time_in_sec" {
  description = "Batch rollover time; API floor is 60s, inert when size is 1"
  type        = number
  default     = 60

  # Fail in plan rather than after a round trip to the create API.
  validation {
    condition     = var.batch_time_in_sec >= 60
    error_message = "Connector Hub rejects target.batchTimeInSec below 60."
  }
}

# THE setting that determines latency.  Raising it trades responsiveness for
# fewer function invocations; leaving it unset (so a KB threshold governs) is
# what makes the service look 30x slower than it is.
variable "batch_size_in_num" {
  description = "Messages per batch; 1 flushes immediately and dominates latency"
  type        = number
  default     = 1
}
