# =============================================================================
# Bedrock Knowledge Base (RAG)
# =============================================================================
# Provides Retrieval Augmented Generation (RAG) capabilities for the chatbot.
#
# ARCHITECTURE:
# -------------
#   1. Documents uploaded to S3 bucket
#   2. Bedrock ingests, chunks, and embeds documents
#   3. Vectors stored in OpenSearch Serverless
#   4. At query time: retrieve relevant chunks → augment prompt → invoke model
#
# USAGE:
# ------
# Option A: RetrieveAndGenerate API (recommended)
#   - Single API call handles retrieval + generation
#   - Bedrock manages the entire RAG pipeline
#
# Option B: Retrieve API + InvokeModel
#   - Call Retrieve to get relevant chunks
#   - Manually construct prompt with context
#   - Call InvokeModel with augmented prompt
#
# =============================================================================

# -----------------------------------------------------------------------------
# S3 Bucket for Documents
# -----------------------------------------------------------------------------
# Upload your knowledge base documents here (PDF, TXT, MD, HTML, DOC, CSV).
# Bedrock will automatically process and index them.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "knowledge_base" {
  count = var.enable_knowledge_base ? 1 : 0

  bucket        = "${local.bedrock_prefix}-kb-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # Allow terraform destroy to delete bucket with versioned objects

  tags = merge(local.common_tags, {
    Name = "${local.bedrock_prefix}-knowledge-base"
  })
}

resource "aws_s3_bucket_versioning" "knowledge_base" {
  count = var.enable_knowledge_base ? 1 : 0

  bucket = aws_s3_bucket.knowledge_base[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "knowledge_base" {
  count = var.enable_knowledge_base ? 1 : 0

  bucket = aws_s3_bucket.knowledge_base[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "knowledge_base" {
  count = var.enable_knowledge_base ? 1 : 0

  bucket = aws_s3_bucket.knowledge_base[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# OpenSearch Serverless Collection
# -----------------------------------------------------------------------------
# Vector database for storing document embeddings.
# Serverless = no infrastructure management, pay per usage.
# -----------------------------------------------------------------------------

resource "aws_opensearchserverless_security_policy" "kb_encryption" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.opensearch_prefix}-kb-enc"
  type = "encryption"

  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.opensearch_prefix}-kb"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "kb_network" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.opensearch_prefix}-kb-net"
  type = "network"

  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.opensearch_prefix}-kb"]
    }, {
      ResourceType = "dashboard"
      Resource     = ["collection/${local.opensearch_prefix}-kb"]
    }]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_access_policy" "kb_access" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.opensearch_prefix}-kb-access"
  type = "data"

  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/${local.opensearch_prefix}-kb/*"]
        Permission = [
          "aoss:CreateIndex",
          "aoss:DeleteIndex",
          "aoss:UpdateIndex",
          "aoss:DescribeIndex",
          "aoss:ReadDocument",
          "aoss:WriteDocument"
        ]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.opensearch_prefix}-kb"]
        Permission = [
          "aoss:CreateCollectionItems",
          "aoss:DeleteCollectionItems",
          "aoss:UpdateCollectionItems",
          "aoss:DescribeCollectionItems"
        ]
      }
    ]
    Principal = [
      aws_iam_role.bedrock_kb[0].arn,
      data.aws_caller_identity.current.arn
    ]
  }])
}

resource "aws_opensearchserverless_collection" "knowledge_base" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.opensearch_prefix}-kb"
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.kb_encryption,
    aws_opensearchserverless_security_policy.kb_network,
    aws_opensearchserverless_access_policy.kb_access
  ]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# IAM Role for Bedrock Knowledge Base
# -----------------------------------------------------------------------------
# Allows Bedrock to read documents from S3 and write vectors to OpenSearch.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "bedrock_kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.bedrock_prefix}-kb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "bedrock.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:knowledge-base/*"
        }
      }
    }]
  })

  tags = {
    Name = "${local.bedrock_prefix}-kb-role"
  }
}

resource "aws_iam_role_policy" "bedrock_kb_s3" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "s3-access"
  role = aws_iam_role.bedrock_kb[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ListBucket"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.knowledge_base[0].arn]
      },
      {
        Sid    = "S3GetObject"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.knowledge_base[0].arn}/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_kb_aoss" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "opensearch-access"
  role = aws_iam_role.bedrock_kb[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "OpenSearchServerlessAccess"
      Effect = "Allow"
      Action = ["aoss:APIAccessAll"]
      Resource = [aws_opensearchserverless_collection.knowledge_base[0].arn]
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_kb_model" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "embedding-model-access"
  role = aws_iam_role.bedrock_kb[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "InvokeEmbeddingModel"
      Effect = "Allow"
      Action = ["bedrock:InvokeModel"]
      Resource = [
        "arn:aws:bedrock:${var.region}::foundation-model/${var.kb_embedding_model}"
      ]
    }]
  })
}

# -----------------------------------------------------------------------------
# Bedrock Knowledge Base
# -----------------------------------------------------------------------------
# The main knowledge base resource that ties everything together.
# -----------------------------------------------------------------------------

resource "aws_bedrockagent_knowledge_base" "main" {
  count = var.enable_knowledge_base ? 1 : 0

  name     = "${local.bedrock_prefix}-kb"
  role_arn = aws_iam_role.bedrock_kb[0].arn

  knowledge_base_configuration {
    type = "VECTOR"

    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.region}::foundation-model/${var.kb_embedding_model}"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"

    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.knowledge_base[0].arn
      vector_index_name = var.kb_vector_index_name

      field_mapping {
        vector_field   = "vector"
        text_field     = "text"
        metadata_field = "metadata"
      }
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy.bedrock_kb_s3,
    aws_iam_role_policy.bedrock_kb_aoss,
    aws_iam_role_policy.bedrock_kb_model,
    aws_opensearchserverless_collection.knowledge_base
  ]
}

# -----------------------------------------------------------------------------
# Data Source (S3 → Knowledge Base)
# -----------------------------------------------------------------------------
# Connects the S3 bucket to the knowledge base for automatic ingestion.
# -----------------------------------------------------------------------------

resource "aws_bedrockagent_data_source" "s3" {
  count = var.enable_knowledge_base ? 1 : 0

  name              = "${local.bedrock_prefix}-s3-source"
  knowledge_base_id = aws_bedrockagent_knowledge_base.main[0].id

  data_source_configuration {
    type = "S3"

    s3_configuration {
      bucket_arn = aws_s3_bucket.knowledge_base[0].arn
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = var.kb_chunking_strategy

      dynamic "fixed_size_chunking_configuration" {
        for_each = var.kb_chunking_strategy == "FIXED_SIZE" ? [1] : []
        content {
          max_tokens         = var.kb_chunk_max_tokens
          overlap_percentage = var.kb_chunk_overlap_percentage
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# OpenSearch Serverless Index
# -----------------------------------------------------------------------------
# Creates the vector index in OpenSearch for storing embeddings.
# This must be created before the knowledge base can ingest documents.
#
# NOTE: This uses a null_resource with local-exec because Terraform doesn't
# have native support for creating OpenSearch Serverless indexes.
# -----------------------------------------------------------------------------

resource "null_resource" "create_vector_index" {
  count = var.enable_knowledge_base ? 1 : 0

  triggers = {
    collection_endpoint = aws_opensearchserverless_collection.knowledge_base[0].collection_endpoint
    index_name          = var.kb_vector_index_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for collection to be active
      sleep 60

      # Create the vector index using awscurl
      # The index must match the field mappings in the knowledge base config
      awscurl --service aoss \
        --region ${var.region} \
        -X PUT \
        "${aws_opensearchserverless_collection.knowledge_base[0].collection_endpoint}/${var.kb_vector_index_name}" \
        -H "Content-Type: application/json" \
        -d '{
          "settings": {
            "index": {
              "knn": true,
              "number_of_shards": 2,
              "number_of_replicas": 0
            }
          },
          "mappings": {
            "properties": {
              "vector": {
                "type": "knn_vector",
                "dimension": ${var.kb_embedding_dimensions},
                "method": {
                  "engine": "faiss",
                  "space_type": "l2",
                  "name": "hnsw",
                  "parameters": {}
                }
              },
              "text": {
                "type": "text"
              },
              "metadata": {
                "type": "text"
              }
            }
          }
        }' || echo "Index may already exist, continuing..."
    EOT
  }

  depends_on = [
    aws_opensearchserverless_collection.knowledge_base,
    aws_opensearchserverless_access_policy.kb_access
  ]
}
