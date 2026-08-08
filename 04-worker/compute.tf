# ==============================================================================
# Compute — the worker VM
# ==============================================================================
# A single small instance running the consumer daemon via cloud-init.  Defaults
# to an always-free shape so the always-on worker costs nothing.  An SSH key is
# generated locally for debugging access.
# ==============================================================================

# First availability domain in the region.
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Latest Canonical Ubuntu 24.04 image for the chosen shape.
data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ------------------------------------------------------------------------------
# SSH key — generated so you can shell in to inspect the daemon
# ------------------------------------------------------------------------------
resource "tls_private_key" "worker" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "worker_key" {
  content         = tls_private_key.worker.private_key_openssh
  filename        = "${path.module}/worker_key.pem"
  file_permission = "0600"
}

# ------------------------------------------------------------------------------
# Worker instance
# ------------------------------------------------------------------------------
resource "oci_core_instance" "worker" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = "keygen-worker"
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id        = oci_core_subnet.worker.id
    assign_public_ip = true
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.worker.public_key_openssh

    # cloud-init installs deps, drops the daemon + config, and starts systemd.
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tmpl", {
      consumer_b64     = base64encode(file("${path.module}/consumer.py"))
      queue_id         = var.queue_id
      queue_endpoint   = var.queue_endpoint
      nosql_table_name = var.nosql_table_name
      compartment_id   = var.compartment_id
      region           = var.region
    }))
  }
}
