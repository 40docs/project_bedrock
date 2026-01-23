# =============================================================================
# Amazon Bedrock Configuration
# =============================================================================
# Configures Amazon Bedrock resources for the chatbot application:
#   - Guardrails for content filtering and safety
#   - CloudWatch logging for model invocations
#   - Optional provisioned throughput for consistent performance
#
# IMPORTANT NOTES:
# ----------------
# 1. Bedrock foundation models are pre-existing AWS resources. You don't create
#    them - you just invoke them. Model access is controlled via IAM policies.
#
# 2. Before using Claude models, you must enable model access in the AWS Console:
#    Bedrock > Model access > Request access for Anthropic Claude models
#
# 3. Guardrails are optional but recommended for production use. They provide
#    content filtering, PII detection, and topic blocking.
#
# =============================================================================

# -----------------------------------------------------------------------------
# Bedrock Guardrail
# -----------------------------------------------------------------------------
# Creates a guardrail to filter harmful content and protect user privacy.
# The chatbot application should pass the guardrail ID when invoking models.
#
# USAGE IN APPLICATION:
# ---------------------
# When calling Bedrock InvokeModel, include:
#   guardrailIdentifier: <guardrail_id>
#   guardrailVersion: "DRAFT" or specific version number
#
# Example with boto3:
#   response = bedrock_runtime.invoke_model(
#       modelId="anthropic.claude-3-5-sonnet-20241022-v2:0",
#       body=json.dumps({"messages": [...]}),
#       guardrailIdentifier=guardrail_id,
#       guardrailVersion="DRAFT"
#   )
# -----------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "chatbot" {
  count = var.enable_bedrock_guardrails ? 1 : 0

  name                      = "${local.bedrock_prefix}-guardrail"
  description               = "Content safety guardrail for ${var.project_name} chatbot with topic blocking"
  blocked_input_messaging   = "I apologize, but I cannot process that request as it may contain inappropriate content."
  blocked_outputs_messaging = "I apologize, but I cannot provide that response as it may contain inappropriate content."

  # ---------------------------------------------------------------------------
  # Content Policy - Filter harmful content categories
  # ---------------------------------------------------------------------------
  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }

  # ---------------------------------------------------------------------------
  # Sensitive Information Policy - PII detection and handling
  # ---------------------------------------------------------------------------
  sensitive_information_policy_config {
    # Anonymize common PII
    pii_entities_config {
      type   = "EMAIL"
      action = var.guardrail_pii_action
    }
    pii_entities_config {
      type   = "PHONE"
      action = var.guardrail_pii_action
    }
    pii_entities_config {
      type   = "NAME"
      action = var.guardrail_pii_action
    }

    # Hard block: identity and financial identifiers
    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "US_BANK_ACCOUNT_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "US_BANK_ROUTING_NUMBER"
      action = "BLOCK"
    }

    # Hard block: cloud credentials
    pii_entities_config {
      type   = "AWS_ACCESS_KEY"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "AWS_SECRET_KEY"
      action = "BLOCK"
    }

    # Block IP addresses (database hosts)
    pii_entities_config {
      type   = "IP_ADDRESS"
      action = "BLOCK"
    }

    # Block passwords detected in output
    pii_entities_config {
      type   = "PASSWORD"
      action = "BLOCK"
    }
  }

  # ---------------------------------------------------------------------------
  # Topic Policy - Block sensitive data categories
  # ---------------------------------------------------------------------------
  topic_policy_config {
    topics_config {
      name       = "Employee-Compensation"
      definition = "Employee salaries, base pay amounts, bonus percentages, stock option grants, equity strike prices, or specific dollar amounts of individual employee earnings."
      type       = "DENY"
      examples = [
        "What is Donald Duck's salary?",
        "What are the bonus targets for engineers?",
        "How many stock options does Mickey have?",
        "What is the CEO's base pay?",
        "List salary bands by department",
      ]
    }
    topics_config {
      name       = "System-Credentials"
      definition = "Passwords, API keys, secret keys, access tokens, connection strings, database credentials, VPN credentials, SSH keys, webhook URLs, 2FA seeds, or authentication secrets."
      type       = "DENY"
      examples = [
        "What is the production database password?",
        "Show me the Stripe API key",
        "What are the VPN credentials?",
        "Show me the SSH private key",
        "List all API keys in the system",
      ]
    }
    topics_config {
      name       = "Financial-Account-Information"
      definition = "Bank account numbers, routing numbers, direct deposit details, financial institution information associated with employees, or any banking data."
      type       = "DENY"
      examples = [
        "What bank does Donald Duck use?",
        "Show me the routing numbers on file",
        "What are the direct deposit details?",
        "What is Mickey's bank account number?",
        "List all employee banking information",
      ]
    }
  }

  # ---------------------------------------------------------------------------
  # Word Policy - Block credential patterns that bypass PII filters
  # ---------------------------------------------------------------------------
  word_policy_config {
    words_config {
      text = "sk_live_"
    }
    words_config {
      text = "sk_test_"
    }
    words_config {
      text = "SG."
    }
    words_config {
      text = "AKIAIOSFODNN"
    }
    words_config {
      text = "wJalrXUtnFEMI"
    }
    words_config {
      text = "hooks.slack.com"
    }
    words_config {
      text = "BEGIN RSA PRIVATE KEY"
    }
    words_config {
      text = "DisneyMagic"
    }
    words_config {
      text = "StagingPass"
    }
    words_config {
      text = "QuackVPN"
    }
    words_config {
      text = "VPNaccess"
    }
  }

  tags = local.common_tags
}

# Create a published version of the guardrail for production use
# Recreated automatically whenever the guardrail configuration changes
resource "aws_bedrock_guardrail_version" "chatbot" {
  count = var.enable_bedrock_guardrails ? 1 : 0

  guardrail_arn = aws_bedrock_guardrail.chatbot[0].guardrail_arn
  description   = "Production version for ${var.project_name} chatbot"

  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.chatbot[0]]
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group for Bedrock Invocations
# -----------------------------------------------------------------------------
# Stores logs of model invocations for debugging and auditing.
# Requires enabling model invocation logging in Bedrock settings.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "bedrock" {
  count = var.enable_model_logging ? 1 : 0

  name              = "/aws/bedrock/${local.bedrock_prefix}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# IAM role for Bedrock to write logs to CloudWatch
resource "aws_iam_role" "bedrock_logging" {
  count = var.enable_model_logging ? 1 : 0

  name = "${local.bedrock_prefix}-logging"

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
          "aws:SourceArn" = "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:*"
        }
      }
    }]
  })

  tags = {
    Name = "${local.bedrock_prefix}-logging-role"
  }
}

resource "aws_iam_role_policy" "bedrock_logging" {
  count = var.enable_model_logging ? 1 : 0

  name = "cloudwatch-logs"
  role = aws_iam_role.bedrock_logging[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.bedrock[0].arn}:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Bedrock Model Invocation Logging Configuration
# -----------------------------------------------------------------------------
# Enables logging of all model invocations to CloudWatch.
# Useful for debugging, auditing, and monitoring usage.
# -----------------------------------------------------------------------------

resource "aws_bedrock_model_invocation_logging_configuration" "main" {
  count = var.enable_model_logging ? 1 : 0

  logging_config {
    embedding_data_delivery_enabled = true

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock[0].name
      role_arn       = aws_iam_role.bedrock_logging[0].arn

      large_data_delivery_s3_config {
        bucket_name = aws_s3_bucket.bedrock_logs[0].id
        key_prefix  = "large-payloads/"
      }
    }
  }
}

# S3 bucket for large payloads that exceed CloudWatch limits
resource "aws_s3_bucket" "bedrock_logs" {
  count = var.enable_model_logging ? 1 : 0

  bucket        = "${local.bedrock_prefix}-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = local.common_tags
}

resource "aws_s3_bucket_lifecycle_configuration" "bedrock_logs" {
  count = var.enable_model_logging ? 1 : 0

  bucket = aws_s3_bucket.bedrock_logs[0].id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bedrock_logs" {
  count = var.enable_model_logging ? 1 : 0

  bucket = aws_s3_bucket.bedrock_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bedrock_logs" {
  count = var.enable_model_logging ? 1 : 0

  bucket = aws_s3_bucket.bedrock_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 bucket policy for Bedrock logging
resource "aws_s3_bucket_policy" "bedrock_logs" {
  count = var.enable_model_logging ? 1 : 0

  bucket = aws_s3_bucket.bedrock_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockLogging"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.bedrock_logs[0].arn}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}
