# =============================================================================
# Provider Configuration
# =============================================================================
# This file configures Terraform and the AWS provider for the Bedrock module.
# This is a companion IaC to project_kubernetes, providing Amazon Bedrock
# access for the chatbot application running on EKS.
#
# INTEGRATION:
# ------------
# This module uses terraform_remote_state to read outputs from the
# project_kubernetes state file. This decouples the projects - bedrock
# can destroy cleanly even if the EKS cluster is already gone.
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
# Connects to the EKS cluster using values from project_kubernetes remote state.
# Used to create ServiceAccount with IRSA annotation.
# -----------------------------------------------------------------------------

provider "kubernetes" {
  host                   = local.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(local.eks_cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.eks_cluster_name, "--region", var.region]
  }
}
