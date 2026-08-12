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
# Defaults are deliberately set to the most aggressive (lowest-latency) values
# Connector Hub accepts, NOT the service defaults.  The service default batch
# time is 60s, which makes a request/response workload look far worse than the
# service is capable of; measuring at the floor keeps the comparison fair.
#
# Raise batch_time_in_sec to 60 to reproduce out-of-the-box behaviour.
# ------------------------------------------------------------------------------

variable "batch_time_in_sec" {
  description = "Connector Hub batch rollover time — lower is faster, floor varies"
  type        = number
  default     = 5
}

variable "batch_size_in_num" {
  description = "Messages per batch; 1 flushes as soon as a message is read"
  type        = number
  default     = 1
}
