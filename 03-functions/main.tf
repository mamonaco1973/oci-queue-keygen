# ==============================================================================
# Phase 3: Functions — Functions, NoSQL, Networking, IAM, API GW, Connector Hub
# ==============================================================================
# Deploys all backend infrastructure.  Requires the OCIR image built in Phase 2
# and the stream created in Phase 1.  apply.sh supplies:
#   TF_VAR_image_path      (from 02-docker/.build_output)
#   TF_VAR_stream_id       (from 01-stream output)
#   TF_VAR_stream_endpoint (from 01-stream output)
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

variable "image_path" {
  description = "Full OCIR image path including tag (built by 02-docker/build.sh)"
  type        = string
  default     = ""
}

variable "stream_id" {
  description = "OCID of the keygen requests stream (from 01-stream)"
  type        = string
}

variable "stream_endpoint" {
  description = "Streaming messages endpoint the post function publishes to"
  type        = string
}
