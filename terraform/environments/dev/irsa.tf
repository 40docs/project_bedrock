# =============================================================================
# IRSA (IAM Roles for Service Accounts) - Bedrock Access
# =============================================================================
# Creates IAM role that the chatbot backend pod can assume to invoke Bedrock.
#
# HOW IRSA WORKS:
# ---------------
#   1. EKS cluster has an OIDC provider (from project_kubernetes)
#   2. IAM role trusts tokens from that OIDC provider
#   3. Trust is scoped to specific namespace:serviceaccount
#   4. Pod with that ServiceAccount gets JWT token injected
#   5. AWS SDK uses token to call sts:AssumeRoleWithWebIdentity
#   6. Pod gets temporary credentials for the IAM role
#
# SECURITY (VPC Restriction):
# ---------------------------
# When enable_vpc_restriction=true, all Bedrock API calls MUST originate
# from within the EKS VPC via VPC endpoints. Calls from outside the VPC
# are denied even with valid credentials.
#
# INTEGRATION WITH CHATBOT:
# -------------------------
# The chatbot backend ServiceAccount needs to be annotated with this role:
#
#   apiVersion: v1
#   kind: ServiceAccount
#   metadata:
#     name: chatbot-backend
#     namespace: chatbot
#     annotations:
#       eks.amazonaws.com/role-arn: <output.bedrock_irsa_role_arn>
#
# =============================================================================

# Local for VPC condition - reused across all policies
locals {
  vpc_condition = var.enable_vpc_restriction ? {
    StringEquals = {
      "aws:SourceVpc" = local.vpc_id
    }
  } : {}
}

# -----------------------------------------------------------------------------
# Bedrock Invocation Role
# -----------------------------------------------------------------------------
# Allows the chatbot backend to invoke Bedrock foundation models.
#
# PERMISSIONS:
#   - bedrock:InvokeModel         - Invoke model synchronously
#   - bedrock:InvokeModelWithResponseStream - Invoke model with streaming
#
# OPTIONAL PERMISSIONS (if guardrails enabled):
#   - bedrock:ApplyGuardrail     - Apply guardrail during invocation
#
# TRUST SCOPE:
#   namespace=chatbot, serviceaccount=chatbot-backend
# -----------------------------------------------------------------------------

resource "aws_iam_role" "bedrock_invoke" {
  name = "${local.bedrock_prefix}-invoke"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${var.chatbot_namespace}:${var.chatbot_service_account}"
        }
      }
    }]
  })

  tags = {
    Name = "${local.bedrock_prefix}-invoke-role"
  }
}

# -----------------------------------------------------------------------------
# Bedrock Model Invocation Policy
# -----------------------------------------------------------------------------
# Grants permission to invoke specified Bedrock foundation models.
# Scoped to specific model ARNs for least-privilege access.
#
# SECURITY: When VPC restriction is enabled, aws:SourceVpc condition
# ensures calls MUST come through VPC endpoints.
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "bedrock_invoke" {
  name = "bedrock-model-invocation"
  role = aws_iam_role.bedrock_invoke.id

  policy = var.enable_vpc_restriction ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeModels"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource  = local.bedrock_model_arns
        Condition = local.vpc_condition
      }
    ]
  }) : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeModels"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = local.bedrock_model_arns
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Guardrail Policy (Optional)
# -----------------------------------------------------------------------------
# If guardrails are enabled, grant permission to apply them.
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "bedrock_guardrails" {
  count = var.enable_bedrock_guardrails ? 1 : 0

  name = "bedrock-guardrails"
  role = aws_iam_role.bedrock_invoke.id

  policy = var.enable_vpc_restriction ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ApplyGuardrails"
        Effect = "Allow"
        Action = [
          "bedrock:ApplyGuardrail"
        ]
        Resource  = aws_bedrock_guardrail.chatbot[0].guardrail_arn
        Condition = local.vpc_condition
      }
    ]
  }) : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ApplyGuardrails"
        Effect = "Allow"
        Action = [
          "bedrock:ApplyGuardrail"
        ]
        Resource = aws_bedrock_guardrail.chatbot[0].guardrail_arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Knowledge Base Policy (Optional)
# -----------------------------------------------------------------------------
# If knowledge base is enabled, grant permission to retrieve and generate.
# Supports both RetrieveAndGenerate (recommended) and Retrieve APIs.
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "bedrock_knowledge_base" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "bedrock-knowledge-base"
  role = aws_iam_role.bedrock_invoke.id

  policy = var.enable_vpc_restriction ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RetrieveFromKnowledgeBase"
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve",
          "bedrock:RetrieveAndGenerate"
        ]
        Resource  = aws_bedrockagent_knowledge_base.main[0].arn
        Condition = local.vpc_condition
      },
      {
        Sid    = "InvokeModelForRAG"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:${var.region}::foundation-model/${var.kb_embedding_model}"
        ]
        Condition = local.vpc_condition
      }
    ]
  }) : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RetrieveFromKnowledgeBase"
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve",
          "bedrock:RetrieveAndGenerate"
        ]
        Resource = aws_bedrockagent_knowledge_base.main[0].arn
      },
      {
        Sid    = "InvokeModelForRAG"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:${var.region}::foundation-model/${var.kb_embedding_model}"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Kubernetes ServiceAccount
# -----------------------------------------------------------------------------
# Creates the ServiceAccount in the chatbot namespace with IRSA annotation.
# This allows pods using this ServiceAccount to assume the Bedrock role.
#
# NOTE: If you prefer to manage the ServiceAccount via GitOps (ArgoCD),
# you can set create_service_account = false and add the annotation manually.
# -----------------------------------------------------------------------------

resource "kubernetes_service_account" "chatbot_backend" {
  metadata {
    name      = var.chatbot_service_account
    namespace = var.chatbot_namespace

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.bedrock_invoke.arn
    }

    labels = {
      "app.kubernetes.io/name"       = "chatbot-backend"
      "app.kubernetes.io/component"  = "backend"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}
