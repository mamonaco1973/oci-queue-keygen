# ================================================================================
# File: s3.tf
# ================================================================================
# Purpose:
#   Creates an Amazon S3 bucket for hosting a static website that
#   serves the KeyGen web client. The bucket and policy allow
#   public read access to the index.html file.
#
# Notes:
#   - A random suffix ensures globally unique bucket names.
#   - Public access must remain open for static web hosting.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: random_id.suffix
# --------------------------------------------------------------------------------
# Description:
#   Generates a random 4-byte hexadecimal suffix to guarantee a
#   unique S3 bucket name.
# --------------------------------------------------------------------------------
resource "random_id" "suffix" {
  byte_length = 4
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_s3_bucket.web_bucket
# --------------------------------------------------------------------------------
# Description:
#   Creates the S3 bucket that stores website content. The name
#   includes a random suffix to prevent naming conflicts.
# --------------------------------------------------------------------------------
resource "aws_s3_bucket" "web_bucket" {
  bucket = "keygen-web-${random_id.suffix.hex}"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_s3_bucket_public_access_block.allow_public
# --------------------------------------------------------------------------------
# Description:
#   Disables S3 Block Public Access settings to permit a public
#   read policy on the website bucket.
# --------------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "allow_public" {
  bucket                  = aws_s3_bucket.web_bucket.id
  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_s3_bucket_policy.public_policy
# --------------------------------------------------------------------------------
# Description:
#   Applies a bucket policy that grants public read (GET) access
#   to all objects within the S3 bucket.
# --------------------------------------------------------------------------------
resource "aws_s3_bucket_policy" "public_policy" {
  bucket = aws_s3_bucket.web_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AllowPublicRead",
        Effect    = "Allow",
        Principal = "*",
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.web_bucket.arn}/*"
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.allow_public]
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_s3_object.index_html
# --------------------------------------------------------------------------------
# Description:
#   Uploads the local index.html file to the S3 bucket so it can
#   be accessed as a static website entry point.
# --------------------------------------------------------------------------------
resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.web_bucket.id
  key          = "index.html"
  source       = "${path.module}/index.html"
  content_type = "text/html"

  depends_on = [aws_s3_bucket_policy.public_policy]
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_s3_object.favicon
# --------------------------------------------------------------------------------
# Description:
#   Uploads the local favicon file to the S3 bucket 
# --------------------------------------------------------------------------------
resource "aws_s3_object" "favicon" {
  bucket       = aws_s3_bucket.web_bucket.id
  key          = "favicon.ico"
  source       = "${path.module}/favicon.ico"
  content_type = "image/x-icon"

  depends_on = [aws_s3_bucket_policy.public_policy]
}

# --------------------------------------------------------------------------------
# DATA: aws_region.current
# --------------------------------------------------------------------------------
# Description:
#   Retrieves the current AWS region for constructing the output
#   HTTPS website URL.
# --------------------------------------------------------------------------------
data "aws_region" "current" {}

# --------------------------------------------------------------------------------
# OUTPUT: website_https_url
# --------------------------------------------------------------------------------
# Description:
#   Displays the direct HTTPS link to the hosted index.html page.
# --------------------------------------------------------------------------------
output "website_https_url" {
  description = "Direct HTTPS link to the hosted index.html page."
  value = format(
    "https://%s.s3.%s.amazonaws.com/index.html",
    aws_s3_bucket.web_bucket.bucket,
    data.aws_region.current.id,
  )
}
