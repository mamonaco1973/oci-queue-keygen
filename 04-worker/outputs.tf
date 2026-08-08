# ==============================================================================
# Outputs
# ==============================================================================

output "worker_public_ip" {
  description = "Public IP of the worker VM (SSH in to debug the daemon)"
  value       = oci_core_instance.worker.public_ip
}

output "worker_ssh_command" {
  description = "Ready-to-run SSH command for the worker VM"
  value       = "ssh -i 04-worker/worker_key.pem ubuntu@${oci_core_instance.worker.public_ip}"
}
