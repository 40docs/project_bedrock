# =============================================================================
# Local Values
# =============================================================================
# Computed values and data sources for the Bedrock module.
#
# REMOTE STATE:
# -------------
# This module reads outputs from project_kubernetes via terraform_remote_state.
# This decouples the two projects - project_bedrock can still run terraform
# destroy even if the EKS cluster has already been deleted, because the state
# file retains the last known output values.
# =============================================================================

locals {
  # ---------------------------------------------------------------------------
  # Naming
  # ---------------------------------------------------------------------------
  cluster_name = var.eks_cluster_name != "" ? var.eks_cluster_name : "${var.project_name}-${var.environment}"

  # Resource naming prefix for Bedrock resources
  bedrock_prefix = "${var.project_name}-${var.environment}-bedrock"

  # State key for project_kubernetes
  kubernetes_state_key = var.kubernetes_state_key != "" ? var.kubernetes_state_key : "eks/${var.environment}/terraform.tfstate"

  # ---------------------------------------------------------------------------
  # Values from project_kubernetes Remote State
  # ---------------------------------------------------------------------------
  eks_cluster_endpoint = data.terraform_remote_state.kubernetes.outputs.cluster_endpoint
  eks_cluster_ca       = data.terraform_remote_state.kubernetes.outputs.cluster_certificate_authority
  eks_cluster_name     = data.terraform_remote_state.kubernetes.outputs.cluster_name
  oidc_provider_arn    = data.terraform_remote_state.kubernetes.outputs.oidc_provider_arn
  oidc_issuer          = data.terraform_remote_state.kubernetes.outputs.oidc_provider_url
  vpc_id               = data.terraform_remote_state.kubernetes.outputs.vpc_id

  # ---------------------------------------------------------------------------
  # Bedrock Model ARNs
  # ---------------------------------------------------------------------------
  # Convert model IDs to full ARNs for IAM policy
  bedrock_model_arns = var.bedrock_models[0] == "*" ? ["*"] : [
    for model_id in var.bedrock_models :
    "arn:aws:bedrock:${var.region}::foundation-model/${model_id}"
  ]

  # ---------------------------------------------------------------------------
  # Common Tags
  # ---------------------------------------------------------------------------
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "bedrock"
  }
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Remote State - project_kubernetes
# -----------------------------------------------------------------------------
# Reads outputs from the project_kubernetes Terraform state.
# This provides EKS cluster details, VPC ID, and OIDC provider info
# without requiring the EKS cluster to exist at plan/destroy time.
# -----------------------------------------------------------------------------

data "terraform_remote_state" "kubernetes" {
  backend = "s3"

  config = {
    bucket = var.tf_state_bucket
    key    = local.kubernetes_state_key
    region = var.region
  }
}
