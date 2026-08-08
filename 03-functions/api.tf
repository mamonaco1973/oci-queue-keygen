# ==============================================================================
# OCI API Gateway
# ==============================================================================
# Public API Gateway with two routes mapping to the post and get functions:
#   POST /keygen        → keygen-post
#   GET  /result/{id}   → keygen-get
#
# Path parameters:
#   For /result/{id}, a header transformation policy injects
#   ${request.path[id]} as X-Request-Id before the function is invoked.
#   The function reads ctx.Headers().get("x-request-id") to retrieve the value.
#
# CORS:
#   Set at the deployment specification level so it applies to all routes;
#   the gateway answers OPTIONS preflight automatically.
# ==============================================================================

# ------------------------------------------------------------------------------
# API Gateway — public endpoint in the shared subnet
# ------------------------------------------------------------------------------
resource "oci_apigateway_gateway" "keygen" {
  compartment_id = var.compartment_id
  display_name   = "keygen-gateway"
  endpoint_type  = "PUBLIC"
  subnet_id      = oci_core_subnet.public.id
}

# ------------------------------------------------------------------------------
# API Deployment — routes, CORS, and function backends
# ------------------------------------------------------------------------------
resource "oci_apigateway_deployment" "keygen" {
  compartment_id = var.compartment_id
  display_name   = "keygen-api"
  gateway_id     = oci_apigateway_gateway.keygen.id
  path_prefix    = "/"

  specification {

    # CORS — applies to all routes; gateway handles OPTIONS preflight.
    request_policies {
      cors {
        allowed_origins              = ["*"]
        allowed_methods              = ["GET", "POST", "OPTIONS"]
        allowed_headers              = ["Content-Type", "content-type"]
        exposed_headers              = ["Content-Type"]
        is_allow_credentials_enabled = false
        max_age_in_seconds           = 300
      }
    }

    # ------------------------------------------------------------------
    # POST /keygen — enqueue a key generation request
    # ------------------------------------------------------------------
    routes {
      path    = "/keygen"
      methods = ["POST"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.post.id
      }
    }

    # ------------------------------------------------------------------
    # GET /result/{id} — retrieve a result by correlation id
    # ------------------------------------------------------------------
    # Header transform injects the path parameter so the function can read
    # it from ctx.Headers().get("x-request-id").
    # ------------------------------------------------------------------
    routes {
      path    = "/result/{id}"
      methods = ["GET"]

      backend {
        type        = "ORACLE_FUNCTIONS_BACKEND"
        function_id = oci_functions_function.get.id
      }

      request_policies {
        header_transformations {
          set_headers {
            items {
              name      = "X-Request-Id"
              values    = ["$${request.path[id]}"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
    }
  }
}
