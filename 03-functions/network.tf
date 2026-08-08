# ==============================================================================
# Networking
# ==============================================================================
# Minimal VCN with a single public subnet used by both OCI Functions (for
# outbound connectivity to OCIR, NoSQL, and the Queue) and the API Gateway
# (for inbound HTTPS).  An Internet Gateway keeps the topology simple for a demo.
# ==============================================================================

# ------------------------------------------------------------------------------
# VCN
# ------------------------------------------------------------------------------
resource "oci_core_vcn" "keygen" {
  compartment_id = var.compartment_id
  cidr_block     = "10.0.0.0/16"
  display_name   = "keygen-vcn"
  dns_label      = "keygenvcn"
}

# ------------------------------------------------------------------------------
# Internet Gateway — default route for public subnet egress
# ------------------------------------------------------------------------------
resource "oci_core_internet_gateway" "keygen" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.keygen.id
  display_name   = "keygen-igw"
  enabled        = true
}

# ------------------------------------------------------------------------------
# Route Table — default route to the internet gateway
# ------------------------------------------------------------------------------
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.keygen.id
  display_name   = "keygen-public-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.keygen.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

# ------------------------------------------------------------------------------
# Security List
# ------------------------------------------------------------------------------
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.keygen.id
  display_name   = "keygen-public-sl"

  # Allow all egress — Functions reach OCIR (image pull), NoSQL, and the Queue.
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }

  # Allow HTTPS inbound — API Gateway needs port 443 open to serve traffic.
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false

    tcp_options {
      min = 443
      max = 443
    }
  }
}

# ------------------------------------------------------------------------------
# Public Subnet — shared by API Gateway and the Functions Application
# ------------------------------------------------------------------------------
resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.keygen.id
  cidr_block        = "10.0.0.0/24"
  display_name      = "keygen-public-subnet"
  dns_label         = "keygenpub"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]

  # Public subnet — VNICs in this subnet receive public IPs.
  prohibit_public_ip_on_vnic = false
}
