# ==========================================================================================
# AWS Elastic Container Registry (ECR)
# ------------------------------------------------------------------------------------------
# Purpose:
#   - Creates a dedicated Amazon ECR repository for SSH Keygen container images
#   - Enables vulnerability scanning and mutable image tag management
# ==========================================================================================

resource "aws_ecr_repository" "ssh-keygen" {

  # Identification -----------------------------------------------------------
  name = "ssh-keygen" # Repository name within the AWS account

  # Image tag behavior ------------------------------------------------------
  image_tag_mutability = "MUTABLE" # Allow overwriting of existing image tags
  # (e.g., for iterative builds during testing)

  # Image scanning ----------------------------------------------------------
  image_scanning_configuration {
    scan_on_push = true # Automatically scan images when pushed
  }

  # Tags -------------------------------------------------------------------
  tags = {
    Name = "SSH Keygen ECR Repository"
  }
}
