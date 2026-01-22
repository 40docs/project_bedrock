# =============================================================================
# Document Sync to Knowledge Base
# =============================================================================
# Syncs documents from the local documents/ folder to S3 and triggers
# ingestion into the Bedrock Knowledge Base.
#
# USAGE:
# ------
# 1. Add/modify documents in project_bedrock/documents/
# 2. Run `terraform apply`
# 3. Documents are uploaded to S3 and ingestion is triggered
#
# DOCUMENT STRUCTURE:
# -------------------
# documents/
# ├── employees/          # Employee directory, org charts
# ├── policies/           # HR policies, guidelines
# └── confidential/       # Sensitive data (for testing guardrails)
#
# =============================================================================

locals {
  # Path to documents directory (relative to terraform working directory)
  documents_path = "${path.module}/../../../documents"

  # Find all files in the documents directory
  document_files = var.enable_knowledge_base ? fileset(local.documents_path, "**/*") : []

  # Filter to only include actual files (not directories) and supported formats
  supported_extensions = [".md", ".txt", ".pdf", ".html", ".doc", ".docx", ".csv", ".xls", ".xlsx"]

  uploadable_files = [
    for f in local.document_files :
    f if anytrue([for ext in local.supported_extensions : endswith(f, ext)])
  ]
}

# -----------------------------------------------------------------------------
# Upload Documents to S3
# -----------------------------------------------------------------------------
# Each document in the documents/ folder becomes an S3 object.
# Files are uploaded with content hashing to detect changes.
# -----------------------------------------------------------------------------

resource "aws_s3_object" "documents" {
  for_each = var.enable_knowledge_base ? toset(local.uploadable_files) : []

  bucket = aws_s3_bucket.knowledge_base[0].id
  key    = "documents/${each.value}"
  source = "${local.documents_path}/${each.value}"

  # Detect content changes
  etag = filemd5("${local.documents_path}/${each.value}")

  # Set content type based on extension
  content_type = lookup({
    ".md"    = "text/markdown"
    ".txt"   = "text/plain"
    ".pdf"   = "application/pdf"
    ".html"  = "text/html"
    ".doc"   = "application/msword"
    ".docx"  = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    ".csv"   = "text/csv"
    ".xls"   = "application/vnd.ms-excel"
    ".xlsx"  = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  }, regex("\\.[^.]+$", each.value), "application/octet-stream")

  tags = {
    Source    = "terraform"
    Category  = dirname(each.value)
    Filename  = basename(each.value)
  }
}

# -----------------------------------------------------------------------------
# Trigger Ingestion After Upload
# -----------------------------------------------------------------------------
# Automatically starts an ingestion job when documents change.
# This syncs S3 content into the Knowledge Base vector store.
# -----------------------------------------------------------------------------

resource "null_resource" "trigger_ingestion" {
  count = var.enable_knowledge_base ? 1 : 0

  # Re-trigger when any document changes
  triggers = {
    documents_hash = md5(join(",", [for f in local.uploadable_files : filemd5("${local.documents_path}/${f}")]))
    knowledge_base = aws_bedrockagent_knowledge_base.main[0].id
    data_source    = aws_bedrockagent_data_source.s3[0].data_source_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Starting ingestion job for Knowledge Base..."
      aws bedrock-agent start-ingestion-job \
        --knowledge-base-id ${aws_bedrockagent_knowledge_base.main[0].id} \
        --data-source-id ${aws_bedrockagent_data_source.s3[0].data_source_id} \
        --region ${var.region} \
        --output json

      echo "Ingestion job started. Check status with:"
      echo "  aws bedrock-agent list-ingestion-jobs --knowledge-base-id ${aws_bedrockagent_knowledge_base.main[0].id} --data-source-id ${aws_bedrockagent_data_source.s3[0].data_source_id}"
    EOT
  }

  depends_on = [
    aws_s3_object.documents,
    aws_bedrockagent_data_source.s3,
    null_resource.create_vector_index
  ]
}

# -----------------------------------------------------------------------------
# Outputs for Document Management
# -----------------------------------------------------------------------------

output "uploaded_documents" {
  description = "List of documents uploaded to the Knowledge Base"
  value       = var.enable_knowledge_base ? local.uploadable_files : []
}

output "documents_s3_prefix" {
  description = "S3 prefix where documents are stored"
  value       = var.enable_knowledge_base ? "s3://${aws_s3_bucket.knowledge_base[0].id}/documents/" : null
}
