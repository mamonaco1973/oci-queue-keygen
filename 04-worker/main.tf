# ==============================================================================
# Phase 4: Worker — always-on queue consumer on a micro-VM
# ==============================================================================
# OCI has no native "message → invoke Function" trigger, so the key-generation
# worker is a long-polling consumer daemon on a small (always-free) instance.
# It drains the Queue (01-queue), generates keypairs, and writes results to the
# NoSQL table (03-functions).  apply.sh supplies queue + table identifiers via
# TF_VAR after those phases complete.
# ==============================================================================

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
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

variable "queue_endpoint" {
  description = "Queue messages endpoint the consumer polls (from 01-queue)"
  type        = string
}

variable "nosql_table_name" {
  description = "OCI NoSQL table name results are written to (from 03-functions)"
  type        = string
}

variable "instance_shape" {
  description = "Compute shape for the worker (default is an always-free shape)"
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}
