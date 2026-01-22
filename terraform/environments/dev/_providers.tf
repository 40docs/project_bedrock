# =============================================================================
# Provider Configuration
# =============================================================================
# This file configures Terraform and the AWS provider for the Bedrock module.
# This is a companion IaC to project_kubernetes, providing Amazon Bedrock
# access for the chatbot application running on EKS.
#
# INTEGRATION:
# ------------
# This module uses data sources to reference the existing EKS cluster from
# project_kubernetes. It creates IRSA roles that pods can assume to access
# Bedrock APIs.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Backend config values injected via -backend-config at runtime
  # Uses same S3 backend as project_kubernetes (different key)
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "bedrock"
    }
  }
}

# -----------------------------------------------------------------------------
# Kubernetes Provider
# -----------------------------------------------------------------------------
# Connects to the existing EKS cluster from project_kubernetes.
# Used to create ServiceAccount with IRSA annotation.
# -----------------------------------------------------------------------------

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.main.name, "--region", var.region]
  }
}
