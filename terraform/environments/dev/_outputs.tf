# =============================================================================
# Outputs
# =============================================================================
# Values needed for integrating the chatbot application with Bedrock.
# These can be used to configure the chatbot backend deployment.
# =============================================================================

# -----------------------------------------------------------------------------
# IRSA Role
# -----------------------------------------------------------------------------

output "bedrock_irsa_role_arn" {
  description = "IAM role ARN for the chatbot backend to assume (IRSA)"
  value       = aws_iam_role.bedrock_invoke.arn
}

output "bedrock_irsa_role_name" {
  description = "IAM role name for the chatbot backend"
  value       = aws_iam_role.bedrock_invoke.name
}

# -----------------------------------------------------------------------------
# ServiceAccount
# -----------------------------------------------------------------------------

output "service_account_name" {
  description = "Kubernetes ServiceAccount name for IRSA annotation"
  value       = var.chatbot_service_account
}

output "service_account_namespace" {
  description = "Kubernetes namespace for the ServiceAccount"
  value       = var.chatbot_namespace
}

# -----------------------------------------------------------------------------
# Guardrail
# -----------------------------------------------------------------------------

output "guardrail_id" {
  description = "Bedrock Guardrail ID (use in InvokeModel requests)"
  value       = var.enable_bedrock_guardrails ? aws_bedrock_guardrail.chatbot[0].guardrail_id : null
}

output "guardrail_arn" {
  description = "Bedrock Guardrail ARN"
  value       = var.enable_bedrock_guardrails ? aws_bedrock_guardrail.chatbot[0].guardrail_arn : null
}

output "guardrail_version" {
  description = "Published Guardrail version number"
  value       = var.enable_bedrock_guardrails ? aws_bedrock_guardrail_version.chatbot[0].version : null
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group for Bedrock invocation logs"
  value       = var.enable_model_logging ? aws_cloudwatch_log_group.bedrock[0].name : null
}

output "s3_logs_bucket" {
  description = "S3 bucket for large Bedrock log payloads"
  value       = var.enable_model_logging ? aws_s3_bucket.bedrock_logs[0].id : null
}

# -----------------------------------------------------------------------------
# Allowed Models
# -----------------------------------------------------------------------------

output "allowed_models" {
  description = "List of Bedrock model IDs allowed for invocation"
  value       = var.bedrock_models
}

# -----------------------------------------------------------------------------
# Knowledge Base (RAG)
# -----------------------------------------------------------------------------

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID (use in Retrieve/RetrieveAndGenerate requests)"
  value       = var.enable_knowledge_base ? aws_bedrockagent_knowledge_base.main[0].id : null
}

output "knowledge_base_arn" {
  description = "Bedrock Knowledge Base ARN"
  value       = var.enable_knowledge_base ? aws_bedrockagent_knowledge_base.main[0].arn : null
}

output "knowledge_base_data_source_id" {
  description = "Data source ID for the S3 bucket"
  value       = var.enable_knowledge_base ? aws_bedrockagent_data_source.s3[0].data_source_id : null
}

output "knowledge_base_s3_bucket" {
  description = "S3 bucket for uploading knowledge base documents"
  value       = var.enable_knowledge_base ? aws_s3_bucket.knowledge_base[0].id : null
}

output "knowledge_base_s3_bucket_arn" {
  description = "S3 bucket ARN for knowledge base documents"
  value       = var.enable_knowledge_base ? aws_s3_bucket.knowledge_base[0].arn : null
}

output "opensearch_collection_endpoint" {
  description = "OpenSearch Serverless collection endpoint"
  value       = var.enable_knowledge_base ? aws_opensearchserverless_collection.knowledge_base[0].collection_endpoint : null
}

# -----------------------------------------------------------------------------
# Integration Instructions
# -----------------------------------------------------------------------------

output "chatbot_integration" {
  description = "Instructions for integrating Bedrock with the chatbot application"
  value       = <<-EOT

    =============================================================================
    BEDROCK INTEGRATION FOR CHATBOT
    =============================================================================

    1. SERVICE ACCOUNT
    ------------------
    The ServiceAccount '${var.chatbot_service_account}' in namespace '${var.chatbot_namespace}'
    has been configured with IRSA annotation:
      eks.amazonaws.com/role-arn: ${aws_iam_role.bedrock_invoke.arn}

    Update your chatbot backend deployment to use this ServiceAccount:
      spec:
        serviceAccountName: ${var.chatbot_service_account}

    2. ENVIRONMENT VARIABLES
    ------------------------
    Add these to your chatbot backend deployment:

      env:
        - name: AWS_REGION
          value: "${var.region}"
        - name: BEDROCK_MODEL_ID
          value: "${var.bedrock_models[0]}"
        ${var.enable_bedrock_guardrails ? "- name: BEDROCK_GUARDRAIL_ID\n          value: \"${aws_bedrock_guardrail.chatbot[0].guardrail_id}\"" : "# Guardrails disabled"}
        ${var.enable_bedrock_guardrails ? "- name: BEDROCK_GUARDRAIL_VERSION\n          value: \"${aws_bedrock_guardrail_version.chatbot[0].version}\"" : ""}
        ${var.enable_knowledge_base ? "- name: BEDROCK_KNOWLEDGE_BASE_ID\n          value: \"${aws_bedrockagent_knowledge_base.main[0].id}\"" : "# Knowledge base disabled"}

    3. PYTHON SDK EXAMPLE - Direct Model Invocation
    -----------------------------------------------
    import boto3
    import json

    bedrock = boto3.client('bedrock-runtime', region_name='${var.region}')

    response = bedrock.invoke_model(
        modelId='${var.bedrock_models[0]}',
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": "Hello!"}]
        }),
        ${var.enable_bedrock_guardrails ? "guardrailIdentifier='${aws_bedrock_guardrail.chatbot[0].guardrail_id}',\n        guardrailVersion='${aws_bedrock_guardrail_version.chatbot[0].version}'," : "# No guardrail configured"}
    )

    ${var.enable_knowledge_base ? <<-KB
    4. PYTHON SDK EXAMPLE - RAG with Knowledge Base
    -----------------------------------------------
    # Option A: RetrieveAndGenerate (recommended - single API call)
    bedrock_agent = boto3.client('bedrock-agent-runtime', region_name='${var.region}')

    response = bedrock_agent.retrieve_and_generate(
        input={'text': 'What is our refund policy?'},
        retrieveAndGenerateConfiguration={
            'type': 'KNOWLEDGE_BASE',
            'knowledgeBaseConfiguration': {
                'knowledgeBaseId': '${aws_bedrockagent_knowledge_base.main[0].id}',
                'modelArn': 'arn:aws:bedrock:${var.region}::foundation-model/${var.bedrock_models[0]}'
            }
        }
    )
    print(response['output']['text'])

    # Option B: Retrieve only (for custom prompt construction)
    response = bedrock_agent.retrieve(
        knowledgeBaseId='${aws_bedrockagent_knowledge_base.main[0].id}',
        retrievalQuery={'text': 'refund policy'},
        retrievalConfiguration={
            'vectorSearchConfiguration': {'numberOfResults': 5}
        }
    )
    # Use retrieved chunks to build your own prompt

    5. UPLOAD DOCUMENTS TO KNOWLEDGE BASE
    -------------------------------------
    # Upload documents to S3
    aws s3 cp my-document.pdf s3://${aws_s3_bucket.knowledge_base[0].id}/documents/

    # Trigger sync (or wait for automatic sync)
    aws bedrock-agent start-ingestion-job \
        --knowledge-base-id ${aws_bedrockagent_knowledge_base.main[0].id} \
        --data-source-id ${aws_bedrockagent_data_source.s3[0].data_source_id}

    6. SUPPORTED DOCUMENT FORMATS
    -----------------------------
    - PDF, TXT, MD, HTML, DOC, DOCX, CSV, XLS, XLSX
    - Upload to: s3://${aws_s3_bucket.knowledge_base[0].id}/documents/
    KB
    : ""}

    ${var.enable_knowledge_base ? "7" : "4"}. ALLOWED MODELS
    -----------------
    The following models are permitted by IAM policy:
    ${join("\n    ", [for m in var.bedrock_models : "- ${m}"])}

    ${var.enable_knowledge_base ? "8" : "5"}. PREREQUISITES
    ----------------
    Ensure model access is enabled in AWS Console:
    Bedrock > Model access > Request access for Anthropic Claude models
    ${var.enable_knowledge_base ? "Bedrock > Model access > Request access for Amazon Titan Embeddings" : ""}

    =============================================================================
  EOT
}
