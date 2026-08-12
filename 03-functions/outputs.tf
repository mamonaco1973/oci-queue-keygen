# ==============================================================================
# Outputs
# ==============================================================================
# api_gateway_endpoint is read by apply.sh to inject the base URL into the HTML
# template before the 05-webapp phase, and by validate.sh for the smoke test.
# ==============================================================================

output "api_gateway_endpoint" {
  description = "HTTPS base URL for the KeyGen API (no trailing slash)"
  value       = "https://${oci_apigateway_gateway.keygen.hostname}"
}

output "nosql_table_name" {
  description = "OCI NoSQL table name for keygen results"
  value       = oci_nosql_table.keygen_results.name
}

output "ocir_image_path" {
  description = "Full OCIR path of the deployed function image"
  value       = var.image_path
}

# Consumed by 04-sch, which adds the worker function to this same application
# so it inherits the VCN subnet and the keygen-functions-dg grants.
output "functions_application_id" {
  description = "OCID of the Functions Application hosting the keygen functions"
  value       = oci_functions_application.keygen.id
}
