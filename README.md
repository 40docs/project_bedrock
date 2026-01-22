# Project Bedrock

Companion Infrastructure as Code (IaC) for Amazon Bedrock integration with the [project_kubernetes](../project_kubernetes) chatbot application.

## Overview

This repository provides Terraform configuration to:
- Create IRSA (IAM Roles for Service Accounts) for secure Bedrock access from EKS
- Configure Bedrock Guardrails for content safety and PII protection
- **Knowledge Base (RAG)** for grounding responses in your own documents
- Set up CloudWatch logging for model invocation auditing
- Integrate seamlessly with the existing EKS GitOps platform

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              EKS Cluster                                     │
│  (from project_kubernetes)                                                  │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐│
│  │  Chatbot Backend Pod                                                    ││
│  │  ServiceAccount: chatbot-backend (IRSA annotated)                       ││
│  └──────────────────────────────┬─────────────────────────────────────────┘│
└─────────────────────────────────┼───────────────────────────────────────────┘
                                  │ IRSA Token
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Amazon Bedrock                                     │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Knowledge Base (RAG)                              │   │
│  │                                                                      │   │
│  │   ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐    │   │
│  │   │  S3 Bucket   │───▶│   Bedrock    │───▶│    OpenSearch     │    │   │
│  │   │  (Documents) │    │  Ingestion   │    │   Serverless      │    │   │
│  │   │  PDF,TXT,MD  │    │  & Embedding │    │  (Vector Store)   │    │   │
│  │   └──────────────┘    └──────────────┘    └─────────┬─────────┘    │   │
│  │                                                      │              │   │
│  │   User Query ──▶ Retrieve relevant chunks ──────────┘              │   │
│  │                           │                                         │   │
│  └───────────────────────────┼─────────────────────────────────────────┘   │
│                              ▼                                              │
│  ┌────────────────────┐  ┌─────────────────────────────────────────────┐   │
│  │  Foundation Models │  │  Guardrail                                  │   │
│  │  - Claude 3.5      │◀─│  - Content filtering                        │   │
│  │  - Titan Embed     │  │  - PII detection                            │   │
│  └────────────────────┘  └─────────────────────────────────────────────┘   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Model Invocation Logging → CloudWatch / S3                          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **project_kubernetes deployed**: The EKS cluster and chatbot application must be running
2. **Bedrock model access enabled**: Request access to Claude + Titan Embeddings in AWS Console
3. **Same AWS region**: Must match the region used in project_kubernetes (default: `ca-central-1`)
4. **Terraform state backend**: Uses the same S3 backend as project_kubernetes
5. **awscurl installed** (for Knowledge Base): Used to create OpenSearch index

## Quick Start

### 1. Enable Bedrock Model Access

Before deploying, enable model access in AWS Console:
1. Navigate to Amazon Bedrock > **Model access**
2. Request access for:
   - **Anthropic Claude** models (for chat)
   - **Amazon Titan Embeddings** (for knowledge base)
3. Wait for approval (usually instant)

### 2. Initialize Terraform

```bash
cd terraform/environments/dev

# Use the same backend as project_kubernetes
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=bedrock/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=$TF_STATE_LOCK_TABLE"
```

### 3. Review and Apply

```bash
# Review the plan
terraform plan

# Apply the configuration
terraform apply
```

### 4. Upload Documents to Knowledge Base

```bash
# Get the S3 bucket name from outputs
KB_BUCKET=$(terraform output -raw knowledge_base_s3_bucket)

# Upload your documents
aws s3 cp ./docs/ s3://$KB_BUCKET/documents/ --recursive

# Trigger ingestion
KB_ID=$(terraform output -raw knowledge_base_id)
DS_ID=$(terraform output -raw knowledge_base_data_source_id)
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id $KB_ID \
  --data-source-id $DS_ID
```

### 5. Update Chatbot Backend

Update your chatbot backend deployment in `project_kubernetes/manifests-apps/chatbot/`:

```yaml
# backend-deployment.yaml
spec:
  template:
    spec:
      serviceAccountName: chatbot-backend  # Uses IRSA
      containers:
        - name: backend
          env:
            - name: AWS_REGION
              value: "ca-central-1"
            - name: BEDROCK_MODEL_ID
              value: "anthropic.claude-3-5-sonnet-20241022-v2:0"
            - name: BEDROCK_KNOWLEDGE_BASE_ID
              value: "<from terraform output>"
            - name: BEDROCK_GUARDRAIL_ID
              value: "<from terraform output>"
            - name: BEDROCK_GUARDRAIL_VERSION
              value: "<from terraform output>"
```

## Knowledge Base (RAG)

### How It Works

1. **Document Ingestion**: Upload documents (PDF, TXT, MD, HTML, DOC, CSV) to S3
2. **Chunking**: Bedrock splits documents into chunks (configurable size/overlap)
3. **Embedding**: Titan Embeddings converts chunks to vectors
4. **Storage**: Vectors stored in OpenSearch Serverless
5. **Query**: User questions are embedded and matched against stored vectors
6. **Generation**: Retrieved context is passed to Claude for grounded responses

### Supported Document Formats

| Format | Extensions |
|--------|------------|
| Text | `.txt`, `.md`, `.html` |
| Documents | `.pdf`, `.doc`, `.docx` |
| Data | `.csv`, `.xls`, `.xlsx` |

### S3 Folder Structure

```
s3://your-kb-bucket/
├── documents/
│   ├── policies/       # Company policies
│   ├── guides/         # User guides
│   └── faqs/           # FAQ documents
```

### Python SDK Examples

#### Option A: RetrieveAndGenerate (Recommended)

Single API call that handles retrieval + generation:

```python
import boto3
import os

bedrock_agent = boto3.client('bedrock-agent-runtime', region_name=os.environ['AWS_REGION'])

response = bedrock_agent.retrieve_and_generate(
    input={'text': 'What is our refund policy?'},
    retrieveAndGenerateConfiguration={
        'type': 'KNOWLEDGE_BASE',
        'knowledgeBaseConfiguration': {
            'knowledgeBaseId': os.environ['BEDROCK_KNOWLEDGE_BASE_ID'],
            'modelArn': f"arn:aws:bedrock:{os.environ['AWS_REGION']}::foundation-model/{os.environ['BEDROCK_MODEL_ID']}"
        }
    }
)

print(response['output']['text'])

# Access citations
for citation in response.get('citations', []):
    for ref in citation.get('retrievedReferences', []):
        print(f"Source: {ref['location']['s3Location']['uri']}")
```

#### Option B: Retrieve + Custom Prompt

For more control over the prompt:

```python
import boto3
import json
import os

bedrock_agent = boto3.client('bedrock-agent-runtime', region_name=os.environ['AWS_REGION'])
bedrock_runtime = boto3.client('bedrock-runtime', region_name=os.environ['AWS_REGION'])

# Step 1: Retrieve relevant documents
retrieve_response = bedrock_agent.retrieve(
    knowledgeBaseId=os.environ['BEDROCK_KNOWLEDGE_BASE_ID'],
    retrievalQuery={'text': 'refund policy'},
    retrievalConfiguration={
        'vectorSearchConfiguration': {'numberOfResults': 5}
    }
)

# Step 2: Build context from retrieved chunks
context = "\n\n".join([
    result['content']['text']
    for result in retrieve_response['retrievalResults']
])

# Step 3: Create custom prompt
prompt = f"""Based on the following context, answer the user's question.

Context:
{context}

Question: What is our refund policy?

Answer:"""

# Step 4: Call Claude with the augmented prompt
response = bedrock_runtime.invoke_model(
    modelId=os.environ['BEDROCK_MODEL_ID'],
    body=json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 1024,
        "messages": [{"role": "user", "content": prompt}]
    })
)

result = json.loads(response['body'].read())
print(result['content'][0]['text'])
```

### Sync Documents

Documents are synced manually or on a schedule:

```bash
# Manual sync
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id $KB_ID \
  --data-source-id $DS_ID

# Check sync status
aws bedrock-agent get-ingestion-job \
  --knowledge-base-id $KB_ID \
  --data-source-id $DS_ID \
  --ingestion-job-id <job-id>
```

## Configuration

### Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `project_name` | Project name (should match project_kubernetes) | `40docs` |
| `environment` | Environment (dev, staging, prod) | `dev` |
| `region` | AWS region | `ca-central-1` |
| `chatbot_namespace` | K8s namespace for chatbot | `chatbot` |
| `chatbot_service_account` | K8s ServiceAccount name | `chatbot-backend` |
| `bedrock_models` | List of allowed model IDs | Claude 3.5 Sonnet/Haiku |
| `enable_vpc_restriction` | Restrict Bedrock to VPC-only access | `true` |
| `enable_bedrock_guardrails` | Enable content guardrails | `true` |
| `guardrail_pii_action` | PII handling (BLOCK/ANONYMIZE) | `ANONYMIZE` |
| `enable_model_logging` | Enable CloudWatch logging | `true` |
| `enable_knowledge_base` | Enable RAG with Knowledge Base | `true` |
| `kb_embedding_model` | Embedding model for vectors | `amazon.titan-embed-text-v2:0` |
| `kb_chunk_max_tokens` | Max tokens per chunk | `512` |
| `kb_chunk_overlap_percentage` | Chunk overlap (0-99) | `20` |

### Disable Knowledge Base

For simpler deployments without RAG:

```hcl
enable_knowledge_base = false
```

## Outputs

| Output | Description |
|--------|-------------|
| `bedrock_irsa_role_arn` | IAM role ARN for IRSA annotation |
| `guardrail_id` | Guardrail ID for InvokeModel requests |
| `guardrail_version` | Published guardrail version |
| `knowledge_base_id` | Knowledge Base ID for RAG queries |
| `knowledge_base_s3_bucket` | S3 bucket for document uploads |
| `knowledge_base_data_source_id` | Data source ID for sync jobs |
| `opensearch_collection_endpoint` | OpenSearch endpoint (for debugging) |
| `chatbot_integration` | Complete integration instructions |

## Cost Considerations

| Resource | Estimated Monthly Cost |
|----------|----------------------|
| **Bedrock API (Claude)** | $3-15 / 1M tokens |
| **Bedrock API (Titan Embed)** | $0.10 / 1M tokens |
| **OpenSearch Serverless** | ~$24/month (2 OCUs minimum) |
| **S3 Storage** | ~$0.023/GB |
| **CloudWatch Logs** | ~$0.50/GB ingested |

**Note**: OpenSearch Serverless has a minimum of 2 OCUs ($0.24/hour each = ~$350/month for production). For development, costs are lower due to scale-to-zero capabilities.

## Troubleshooting

### Knowledge Base returns no results

1. Verify documents were uploaded to S3
2. Check ingestion job completed successfully
3. Ensure embedding model access is enabled
4. Try increasing `numberOfResults` in retrieve call

### "Access Denied" when querying Knowledge Base

1. Verify IRSA role has `bedrock:Retrieve` permission
2. Check ServiceAccount annotation is correct
3. Ensure pod is using the correct ServiceAccount

### OpenSearch index creation fails

1. Ensure `awscurl` is installed
2. Verify AWS credentials have AOSS permissions
3. Check collection is in ACTIVE state
4. Manually create index if needed (see Terraform output)

### Slow retrieval performance

1. Reduce chunk size for more granular matching
2. Increase chunk overlap for better context
3. Consider using a larger embedding model

## Security

### Network Security (VPC Endpoints)

Traffic to Bedrock flows through VPC endpoints, never touching the public internet:

```
Chatbot Pod → VPC Endpoint → AWS PrivateLink → Bedrock
```

**Requirements** (implemented in project_kubernetes):
- `bedrock-runtime` VPC endpoint for model invocation
- `bedrock-agent-runtime` VPC endpoint for Knowledge Base queries

**IAM VPC Restriction** (enabled by default):
```hcl
enable_vpc_restriction = true  # Default
```

When enabled, IAM policies include an `aws:SourceVpc` condition that **denies all Bedrock calls from outside the VPC**, even with valid credentials. This protects against credential theft/misuse.

### IRSA (IAM Roles for Service Accounts)

- No long-lived credentials stored in pods
- Temporary credentials via OIDC token exchange
- Scoped to specific namespace:serviceaccount

### Guardrails

- **Content filtering**: Blocks hate, violence, sexual content
- **PII protection**: Detects and blocks/anonymizes sensitive data
- **Prompt injection defense**: Filters prompt attack attempts

### Data Protection

- S3 bucket encrypted with KMS
- OpenSearch Serverless encrypted at rest
- All traffic via VPC endpoints (private network path)

### Security Layers Summary

| Layer | Protection |
|-------|------------|
| VPC Endpoints | Private network path, no public internet |
| VPC Restriction | IAM condition blocks external calls |
| IRSA | No stored credentials, OIDC token exchange |
| Guardrails | Content/PII filtering, prompt attack defense |
| Encryption | S3 + OpenSearch encrypted at rest |
| CloudWatch | Audit logging for all invocations |

## Related Resources

- [Amazon Bedrock Documentation](https://docs.aws.amazon.com/bedrock/)
- [Bedrock Knowledge Bases Guide](https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html)
- [OpenSearch Serverless](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless.html)
- [IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [project_kubernetes Repository](../project_kubernetes)
