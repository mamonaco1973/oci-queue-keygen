# ==============================================================================
# OCI NoSQL Table — keygen results
# ==============================================================================
# Stores completed keypairs keyed by correlation_id.  The worker writes here;
# the get function reads here.  Single primary key mirrors the DynamoDB design
# from the AWS reference implementation.
#
# Row shape:
#   {
#     "correlation_id":  "<uuid4>",
#     "status":          "complete",
#     "key_type":        "rsa" | "ed25519",
#     "public_key_b64":  "<base64 OpenSSH public key>",
#     "private_key_b64": "<base64 PEM private key>",
#     "created_at":      "<ISO-8601 UTC>"
#   }
#
# TTL:
#   USING TTL 1 DAYS auto-expires rows one day after write — the keys are
#   short-lived by design (dev/sandbox use), matching the AWS DynamoDB TTL.
# ==============================================================================

resource "oci_nosql_table" "keygen_results" {
  compartment_id = var.compartment_id
  name           = "keygen_results"

  ddl_statement = join(" ", [
    "CREATE TABLE IF NOT EXISTS keygen_results (",
    "  correlation_id  STRING,",
    "  status          STRING,",
    "  key_type        STRING,",
    "  public_key_b64  STRING,",
    "  private_key_b64 STRING,",
    "  created_at      STRING,",
    "  PRIMARY KEY(correlation_id)",
    ") USING TTL 1 DAYS"
  ])

  # Demo teardown convenience — allow the table to be reclaimed on destroy.
  is_auto_reclaimable = false

  table_limits {
    max_read_units     = 50
    max_write_units    = 50
    max_storage_in_gbs = 1
  }
}
