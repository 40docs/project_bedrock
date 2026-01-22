# =============================================================================
# Local Values
# =============================================================================
# Computed values and data sources for the Bedrock module.
# =============================================================================

locals {
  # ---------------------------------------------------------------------------
  # Naming
  # ---------------------------------------------------------------------------
  cluster_name = var.eks_cluster_name != "" ? var.eks_cluster_name : "${var.project_name}-${var.environment}"

  # Resource naming prefix for Bedrock resources
  bedrock_prefix = "${var.project_name}-${var.environment}-bedrock"

  # ---------------------------------------------------------------------------
  # OIDC Provider
  # ---------------------------------------------------------------------------
  # Extract OIDC issuer URL without https:// prefix (needed for trust policy)
  oidc_issuer = replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")

  # ---------------------------------------------------------------------------
  # Bedrock Model ARNs
  # ---------------------------------------------------------------------------
  # Convert model IDs to full ARNs for IAM policy
  bedrock_model_arns = var.bedrock_models[0] == "*" ? ["*"] : [
    for model_id in var.bedrock_models :
    "arn:aws:bedrock:${var.region}::foundation-model/${model_id}"
  ]

  # ---------------------------------------------------------------------------
  # VPC Information (from EKS cluster)
  # ---------------------------------------------------------------------------
  # Used for VPC endpoint restrictions - ensures Bedrock calls only come
  # from within the VPC via VPC endpoints, not from the public internet.
  vpc_id = data.aws_eks_cluster.main.vpc_config[0].vpc_id

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

# Reference existing EKS cluster from project_kubernetes
data "aws_eks_cluster" "main" {
  name = local.cluster_name
}

# Get OIDC provider for IRSA
data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.main.identity[0].oidc[0].issuer
}
