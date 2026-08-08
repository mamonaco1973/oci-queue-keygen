# ==============================================================================
# OCIR Container Repository
# ==============================================================================
# Private repository for the keygen functions image. A single image carries all
# three handlers (post, get, worker); 02-docker/build.sh builds and pushes it
# after this phase completes.
# ==============================================================================

resource "oci_artifacts_container_repository" "keygen" {
  compartment_id = var.compartment_id
  display_name   = "keygen-functions"
  is_public      = false
}
