# ==============================================================================
# Networking — VCN + public subnet for the worker VM
# ==============================================================================
# The worker only needs outbound access to reach the OCI Queue and NoSQL public
# data-plane endpoints; SSH inbound is allowed for debugging.  A self-contained
# VCN keeps this phase independent of 03-functions' network state.
# ==============================================================================

resource "oci_core_vcn" "worker" {
  compartment_id = var.compartment_id
  cidr_block     = "10.1.0.0/16"
  display_name   = "keygen-worker-vcn"
  dns_label      = "kgworker"
}

resource "oci_core_internet_gateway" "worker" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.worker.id
  display_name   = "keygen-worker-igw"
  enabled        = true
}

resource "oci_core_route_table" "worker" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.worker.id
  display_name   = "keygen-worker-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.worker.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_security_list" "worker" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.worker.id
  display_name   = "keygen-worker-sl"

  # Allow all egress — the consumer reaches Queue + NoSQL over the internet.
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }

  # SSH inbound for debugging the daemon (journalctl -u keygen-worker).
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false

    tcp_options {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_subnet" "worker" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.worker.id
  cidr_block        = "10.1.0.0/24"
  display_name      = "keygen-worker-subnet"
  dns_label         = "kgworkersub"
  route_table_id    = oci_core_route_table.worker.id
  security_list_ids = [oci_core_security_list.worker.id]

  prohibit_public_ip_on_vnic = false
}
