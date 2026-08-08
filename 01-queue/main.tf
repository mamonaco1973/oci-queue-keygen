# ==============================================================================
# Phase 1: Queue + OCIR — message bus and container registry
# ==============================================================================
# Creates the two prerequisites the rest of the deployment depends on:
#   - an OCI Queue (the async message bus; SQS analog)
#   - a private OCIR repository to hold the keygen functions image
# Must run before 02-docker (image push), 03-functions (post fn publishes to the
# queue), and 04-worker (a VM consumer drains the queue). apply.sh passes the
# queue OCID + endpoint to those phases via TF_VAR.
# ==============================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

# Auth uses ~/.oci/config by default (API key mode).
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
