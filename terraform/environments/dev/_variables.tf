# =============================================================================
# Input Variables
# =============================================================================
# All input variables for the Bedrock environment.
# Values should match project_kubernetes for seamless integration.
# =============================================================================

# -----------------------------------------------------------------------------
# Project Configuration
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used for resource naming and tagging (should match project_kubernetes)"
  type        = string
  default     = "40docs"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

# -----------------------------------------------------------------------------
# AWS Configuration
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region for all resources (should match project_kubernetes)"
  type        = string
  default     = "ca-central-1"
}

# -----------------------------------------------------------------------------
# EKS Integration (via Remote State)
# -----------------------------------------------------------------------------

variable "eks_cluster_name" {
  description = "Name of the existing EKS cluster from project_kubernetes"
  type        = string
  default     = "" # If empty, defaults to {project_name}-{environment}
}

variable "tf_state_bucket" {
  description = "S3 bucket containing Terraform state (shared with project_kubernetes)"
  type        = string
}

variable "kubernetes_state_key" {
  description = "S3 key for the project_kubernetes Terraform state file"
  type        = string
  default     = "" # If empty, defaults to eks/{environment}/terraform.tfstate
}

# -----------------------------------------------------------------------------
# Security Configuration
# -----------------------------------------------------------------------------

variable "enable_vpc_restriction" {
  description = <<-EOT
    Restrict Bedrock API calls to only come through VPC endpoints.

    When enabled, adds an IAM condition (aws:SourceVpc) that denies any
    Bedrock calls that don't originate from within the EKS VPC.

    IMPORTANT: Requires VPC endpoints for Bedrock to be created in
    project_kubernetes first (bedrock-runtime, bedrock-agent-runtime).

    This is the strongest security posture - even with valid credentials,
    calls from outside the VPC will be denied.
  EOT
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Chatbot Application Configuration
# -----------------------------------------------------------------------------

variable "chatbot_namespace" {
  description = "Kubernetes namespace where the chatbot application runs"
  type        = string
  default     = "chatbot"
}

variable "chatbot_service_account" {
  description = "Kubernetes ServiceAccount name for the chatbot backend"
  type        = string
  default     = "chatbot-backend"
}

variable "create_service_account" {
  description = <<-EOT
    Create the Kubernetes ServiceAccount via Terraform.
    Set to false when running from CI/CD that lacks EKS auth.
    The ServiceAccount can be created via kubectl or GitOps instead.
  EOT
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Bedrock Configuration
# -----------------------------------------------------------------------------

variable "bedrock_models" {
  description = <<-EOT
    List of Bedrock model IDs to allow access to.

    Common model IDs:
    - anthropic.claude-3-5-sonnet-20241022-v2:0  (Claude 3.5 Sonnet v2)
    - anthropic.claude-3-5-haiku-20241022-v1:0   (Claude 3.5 Haiku)
    - anthropic.claude-3-opus-20240229-v1:0      (Claude 3 Opus)
    - anthropic.claude-3-sonnet-20240229-v1:0    (Claude 3 Sonnet)
    - anthropic.claude-3-haiku-20240307-v1:0     (Claude 3 Haiku)
    - amazon.titan-text-express-v1              (Amazon Titan Text Express)
    - amazon.titan-embed-text-v1                (Amazon Titan Embeddings)

    Use "*" to allow all models (not recommended for production).
  EOT
  type        = list(string)
  default = [
    "anthropic.claude-3-5-sonnet-20241022-v2:0",
    "anthropic.claude-3-5-haiku-20241022-v1:0"
  ]
}

variable "enable_bedrock_guardrails" {
  description = "Enable Bedrock Guardrails for content filtering and safety"
  type        = bool
  default     = true
}

variable "guardrail_blocked_topics" {
  description = "List of topics to block in Guardrails (e.g., 'Financial Advice', 'Medical Advice')"
  type        = list(string)
  default     = []
}

variable "guardrail_pii_action" {
  description = "Action to take when PII is detected: BLOCK or ANONYMIZE"
  type        = string
  default     = "ANONYMIZE"

  validation {
    condition     = contains(["BLOCK", "ANONYMIZE"], var.guardrail_pii_action)
    error_message = "guardrail_pii_action must be either BLOCK or ANONYMIZE"
  }
}

variable "enable_model_logging" {
  description = "Enable CloudWatch logging for Bedrock model invocations"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Number of days to retain Bedrock invocation logs in CloudWatch"
  type        = number
  default     = 30
}

# -----------------------------------------------------------------------------
# Cost Control
# -----------------------------------------------------------------------------

variable "enable_provisioned_throughput" {
  description = "Enable provisioned throughput for consistent performance (additional cost)"
  type        = bool
  default     = false
}

variable "provisioned_model_units" {
  description = "Number of model units for provisioned throughput (if enabled)"
  type        = number
  default     = 1
}

# -----------------------------------------------------------------------------
# Knowledge Base (RAG) Configuration
# -----------------------------------------------------------------------------

variable "enable_knowledge_base" {
  description = "Enable Bedrock Knowledge Base for RAG capabilities"
  type        = bool
  default     = true
}

variable "kb_embedding_model" {
  description = <<-EOT
    Embedding model for vectorizing documents.

    Options:
    - amazon.titan-embed-text-v2:0    (1024 dimensions, recommended)
    - amazon.titan-embed-text-v1      (1536 dimensions)
    - cohere.embed-english-v3         (1024 dimensions)
    - cohere.embed-multilingual-v3    (1024 dimensions)
  EOT
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "kb_embedding_dimensions" {
  description = "Vector dimensions for the embedding model (must match the model)"
  type        = number
  default     = 1024
}

variable "kb_vector_index_name" {
  description = "Name of the vector index in OpenSearch Serverless"
  type        = string
  default     = "bedrock-knowledge-base-index"
}

variable "kb_chunking_strategy" {
  description = <<-EOT
    Document chunking strategy:
    - FIXED_SIZE: Split into fixed-size chunks (configurable)
    - NONE: No chunking (use for pre-chunked documents)
    - SEMANTIC: Semantic chunking based on content (coming soon)
  EOT
  type        = string
  default     = "FIXED_SIZE"

  validation {
    condition     = contains(["FIXED_SIZE", "NONE"], var.kb_chunking_strategy)
    error_message = "kb_chunking_strategy must be FIXED_SIZE or NONE"
  }
}

variable "kb_chunk_max_tokens" {
  description = "Maximum tokens per chunk (for FIXED_SIZE strategy)"
  type        = number
  default     = 512
}

variable "kb_chunk_overlap_percentage" {
  description = "Percentage of overlap between chunks (0-99)"
  type        = number
  default     = 20

  validation {
    condition     = var.kb_chunk_overlap_percentage >= 0 && var.kb_chunk_overlap_percentage < 100
    error_message = "kb_chunk_overlap_percentage must be between 0 and 99"
  }
}
