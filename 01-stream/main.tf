# ==============================================================================
# Phase 1: Stream + OCIR — message bus and container registry
# ==============================================================================
# Creates the two prerequisites the rest of the deployment depends on:
#   - an OCI Streaming stream (the async message bus; SQS analog)
#   - a private OCIR repository to hold the keygen functions image
# Must run before 02-docker (image push) and 03-functions (which read the
# stream OCID + endpoint via TF_VAR set by apply.sh).
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
