# ==============================================================================
# OCI Object Storage — Static Web Hosting
# ==============================================================================
# Public Object Storage bucket hosting index.html (generated from
# index.html.tmpl with API_BASE substituted by apply.sh) and favicon.ico.
#
# URL pattern:
#   https://objectstorage.{region}.oraclecloud.com/n/{namespace}/b/{bucket}/o/{object}
# ==============================================================================

# Tenancy namespace is required for the Object Storage URL and API calls.
data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_id
}

resource "random_id" "suffix" {
  byte_length = 4
}

# ------------------------------------------------------------------------------
# Bucket — public read, random-suffix name to avoid global conflicts
# ------------------------------------------------------------------------------
resource "oci_objectstorage_bucket" "web" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "keygen-web-${random_id.suffix.hex}"

  # ObjectRead makes all objects publicly readable without auth tokens.
  access_type = "ObjectRead"
}

# ------------------------------------------------------------------------------
# index.html — generated from template by apply.sh before terraform apply
# ------------------------------------------------------------------------------
resource "oci_objectstorage_object" "index_html" {
  bucket        = oci_objectstorage_bucket.web.name
  namespace     = data.oci_objectstorage_namespace.ns.namespace
  object        = "index.html"
  source        = "${path.module}/index.html"
  content_type  = "text/html"
  cache_control = "no-store, max-age=0"
}

# ------------------------------------------------------------------------------
# favicon.ico — prevents browsers generating 404s on the default icon request
# ------------------------------------------------------------------------------
resource "oci_objectstorage_object" "favicon" {
  bucket        = oci_objectstorage_bucket.web.name
  namespace     = data.oci_objectstorage_namespace.ns.namespace
  object        = "favicon.ico"
  source        = "${path.module}/favicon.ico"
  content_type  = "image/x-icon"
  cache_control = "no-store, max-age=0"
}

# ------------------------------------------------------------------------------
# Output — direct HTTPS link to the hosted index.html
# ------------------------------------------------------------------------------
output "website_url" {
  description = "Direct HTTPS link to the KeyGen web application"
  value = join("", [
    "https://objectstorage.${var.region}.oraclecloud.com",
    "/n/${data.oci_objectstorage_namespace.ns.namespace}",
    "/b/${oci_objectstorage_bucket.web.name}",
    "/o/index.html",
  ])
}
