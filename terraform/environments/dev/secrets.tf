# =============================================================================
# AWS Secrets Manager - Chatbot Integration Config
# =============================================================================
# Writes Bedrock resource IDs to Secrets Manager so the chatbot pod can
# pull them via ExternalSecrets operator (no manual ConfigMap updates needed).
#
# Flow: terraform apply → Secrets Manager → ExternalSecrets → K8s Secret → Pod env
# =============================================================================

resource "aws_secretsmanager_secret" "chatbot_bedrock" {
  name        = "${var.environment}/chatbot-bedrock"
  description = "Bedrock configuration for chatbot application (managed by Terraform)"

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

resource "aws_secretsmanager_secret_version" "chatbot_bedrock" {
  secret_id = aws_secretsmanager_secret.chatbot_bedrock.id

  secret_string = jsonencode({
    aws_region              = var.region
    bedrock_model_id        = var.bedrock_models[0]
    bedrock_knowledge_base_id = var.enable_knowledge_base ? aws_bedrockagent_knowledge_base.main[0].id : ""
    bedrock_guardrail_id      = var.enable_bedrock_guardrails ? aws_bedrock_guardrail.chatbot[0].guardrail_id : ""
    bedrock_guardrail_version = var.enable_bedrock_guardrails ? aws_bedrock_guardrail_version.chatbot[0].version : ""
  })
}
