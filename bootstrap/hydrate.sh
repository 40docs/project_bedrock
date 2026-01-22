#!/usr/bin/env bash
# =============================================================================
# Bedrock Platform Hydration Script
# =============================================================================
# One-time setup script to bootstrap the Bedrock infrastructure.
# Run this before the first terraform apply.
#
# WHAT THIS DOES:
# ---------------
#   1. Creates/reuses S3 bucket for Terraform state
#   2. Creates/reuses DynamoDB table for state locking
#   3. Creates/reuses GitHub OIDC provider (keyless auth)
#   4. Creates IAM role for GitHub Actions with Bedrock permissions
#   5. Sets GitHub repository secrets
#   6. Saves configuration for cleanup script
#   7. Optionally triggers Terraform Apply via GitHub Actions
#
# NOTE: This can share the same state bucket as project_kubernetes
#       but uses a different state key (bedrock/terraform.tfstate).
#
# PREREQUISITES:
# --------------
#   - AWS CLI configured with admin credentials
#   - GitHub CLI (gh) authenticated
#   - jq installed
#   - project_kubernetes already deployed (provides EKS cluster)
#
# USAGE:
#   ./bootstrap/hydrate.sh [options]
#
# OPTIONS:
#   --help    Show this help message
#   --reuse   Reuse existing state bucket from project_kubernetes
#
# =============================================================================
set -euo pipefail

# Disable AWS CLI pager
export AWS_PAGER=""

# Disable GitHub CLI prompts
export GH_PROMPT_DISABLED=1

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="${PROJECT_NAME:-40docs}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
GITHUB_ORG="${GITHUB_ORG:-40docs}"
GITHUB_REPO="${GITHUB_REPO:-project_bedrock}"

# Related project (for EKS cluster reference)
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-${PROJECT_NAME}-${ENVIRONMENT}}"

# Derived names
STATE_BUCKET="${PROJECT_NAME}-terraform-state-${AWS_REGION}"
LOCK_TABLE="${PROJECT_NAME}-terraform-locks"
OIDC_ROLE_NAME="${PROJECT_NAME}-bedrock-github-actions"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

check_command() {
  if ! command -v "$1" &> /dev/null; then
    log_error "$1 is required but not installed."
    exit 1
  fi
}

show_help() {
  cat << 'EOF'
Bedrock Platform Hydration Script
==================================

One-time setup script to bootstrap the Amazon Bedrock infrastructure
for the project_kubernetes chatbot application.

USAGE:
  ./bootstrap/hydrate.sh [options]

OPTIONS:
  --help    Show this help message
  --reuse   Assume state bucket/table from project_kubernetes exist

WHAT THIS DOES:
  1. Creates/reuses S3 bucket for Terraform state
  2. Creates/reuses DynamoDB table for state locking
  3. Creates/reuses GitHub OIDC provider (keyless auth)
  4. Creates IAM role with Bedrock + OpenSearch permissions
  5. Sets GitHub repository secrets
  6. Saves configuration for cleanup script
  7. Optionally triggers Terraform Apply

PREREQUISITES:
  - AWS CLI configured with admin credentials
  - GitHub CLI (gh) authenticated
  - jq installed
  - project_kubernetes already deployed (provides EKS cluster)

ENVIRONMENT VARIABLES:
  PROJECT_NAME       Project name prefix (default: 40docs)
  ENVIRONMENT        Environment name (default: dev)
  AWS_REGION         AWS region (default: ca-central-1)
  GITHUB_ORG         GitHub organization (default: 40docs)
  GITHUB_REPO        GitHub repository (default: project_bedrock)
  EKS_CLUSTER_NAME   EKS cluster name (default: {PROJECT_NAME}-{ENVIRONMENT})

EXAMPLES:
  # Full hydration (first-time setup)
  ./bootstrap/hydrate.sh

  # Reuse existing state bucket from project_kubernetes
  ./bootstrap/hydrate.sh --reuse

  # Use different project name
  PROJECT_NAME=myproject ./bootstrap/hydrate.sh

EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------
REUSE_EXISTING=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      show_help
      ;;
    --reuse)
      REUSE_EXISTING=true
      shift
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Preflight Checks
# -----------------------------------------------------------------------------
log_info "Running preflight checks..."

check_command aws
check_command gh
check_command jq

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
  log_error "AWS credentials not configured. Run 'aws configure' or 'aws sso login'"
  exit 1
fi

# Verify GitHub CLI auth
if ! gh auth status &> /dev/null; then
  log_error "GitHub CLI not authenticated. Run 'gh auth login'"
  exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_info "AWS Account: ${AWS_ACCOUNT_ID}"
log_info "AWS Region: ${AWS_REGION}"
log_info "GitHub: ${GITHUB_ORG}/${GITHUB_REPO}"
log_info "EKS Cluster: ${EKS_CLUSTER_NAME}"

# Verify EKS cluster exists (from project_kubernetes)
if ! aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}" &> /dev/null; then
  log_warn "EKS cluster '${EKS_CLUSTER_NAME}' not found."
  echo ""
  echo "This Bedrock IaC requires an existing EKS cluster from project_kubernetes."
  echo "Please deploy project_kubernetes first, then run this script."
  echo ""
  read -p "Continue anyway (for testing)? [y/N]: " CONTINUE_ANYWAY
  CONTINUE_ANYWAY="${CONTINUE_ANYWAY:-n}"
  if [[ "${CONTINUE_ANYWAY,,}" != "y" && "${CONTINUE_ANYWAY,,}" != "yes" ]]; then
    exit 1
  fi
fi

echo ""

# -----------------------------------------------------------------------------
# Step 1: Create/Reuse S3 Bucket for Terraform State
# -----------------------------------------------------------------------------
log_step "Step 1: Setting up S3 bucket for Terraform state..."

if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  log_info "Bucket ${STATE_BUCKET} already exists (reusing)"
else
  if [[ "$REUSE_EXISTING" == "true" ]]; then
    log_error "Bucket ${STATE_BUCKET} not found. Run without --reuse to create it."
    exit 1
  fi

  log_info "Creating S3 bucket: ${STATE_BUCKET}"
  aws s3api create-bucket \
    --bucket "${STATE_BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}"

  # Enable versioning
  aws s3api put-bucket-versioning \
    --bucket "${STATE_BUCKET}" \
    --versioning-configuration Status=Enabled

  # Enable encryption
  aws s3api put-bucket-encryption \
    --bucket "${STATE_BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }]
    }'

  # Block public access
  aws s3api put-public-access-block \
    --bucket "${STATE_BUCKET}" \
    --public-access-block-configuration '{
      "BlockPublicAcls": true,
      "IgnorePublicAcls": true,
      "BlockPublicPolicy": true,
      "RestrictPublicBuckets": true
    }'

  log_info "Created S3 bucket: ${STATE_BUCKET}"
fi

# -----------------------------------------------------------------------------
# Step 2: Create/Reuse DynamoDB Table for State Locking
# -----------------------------------------------------------------------------
log_step "Step 2: Setting up DynamoDB table for state locking..."

if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" 2>/dev/null; then
  log_info "Table ${LOCK_TABLE} already exists (reusing)"
else
  if [[ "$REUSE_EXISTING" == "true" ]]; then
    log_error "Table ${LOCK_TABLE} not found. Run without --reuse to create it."
    exit 1
  fi

  log_info "Creating DynamoDB table: ${LOCK_TABLE}"
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}"

  log_info "Created DynamoDB table: ${LOCK_TABLE}"
fi

# -----------------------------------------------------------------------------
# Step 3: Create/Reuse GitHub OIDC Provider
# -----------------------------------------------------------------------------
log_step "Step 3: Setting up GitHub OIDC provider..."

OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" 2>/dev/null; then
  log_info "GitHub OIDC provider already exists (reusing)"
else
  log_info "Creating GitHub OIDC provider..."

  # Get GitHub's OIDC thumbprint
  THUMBPRINT=$(openssl s_client -servername token.actions.githubusercontent.com \
    -connect token.actions.githubusercontent.com:443 < /dev/null 2>/dev/null \
    | openssl x509 -fingerprint -sha1 -noout \
    | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${THUMBPRINT}"

  log_info "Created GitHub OIDC provider"
fi

# -----------------------------------------------------------------------------
# Step 4: Create IAM Role for GitHub Actions (Bedrock-specific)
# -----------------------------------------------------------------------------
log_step "Step 4: Creating IAM role for GitHub Actions (Bedrock permissions)..."

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${OIDC_ROLE_NAME}"

if aws iam get-role --role-name "${OIDC_ROLE_NAME}" 2>/dev/null; then
  log_warn "Role ${OIDC_ROLE_NAME} already exists, updating policy..."

  # Update the policy
  POLICY_NAME="${OIDC_ROLE_NAME}-policy"
  POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

  # Delete old policy versions if at limit
  OLD_VERSIONS=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null || true)
  for v in $OLD_VERSIONS; do
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "$v" 2>/dev/null || true
  done
else
  log_info "Creating IAM role: ${OIDC_ROLE_NAME}"

  # Trust policy - allow GitHub Actions from this repo to assume the role
  TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF
)

  aws iam create-role \
    --role-name "${OIDC_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}"
fi

# Create/Update the Bedrock-specific policy
POLICY_NAME="${OIDC_ROLE_NAME}-policy"
POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketVersioning"
      ],
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET}",
        "arn:aws:s3:::${STATE_BUCKET}/*"
      ]
    },
    {
      "Sid": "TerraformStateLocking",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
        "dynamodb:DescribeTable"
      ],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${LOCK_TABLE}"
    },
    {
      "Sid": "BedrockFullAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BedrockAgentAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock-agent:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "OpenSearchServerless",
      "Effect": "Allow",
      "Action": [
        "aoss:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EKSReadAccess",
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMForIRSA",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PassRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:UpdateRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListPolicyVersions",
        "iam:GetOpenIDConnectProvider",
        "iam:CreateServiceLinkedRole"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3ForBedrockBuckets",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${PROJECT_NAME}-${ENVIRONMENT}-bedrock-*",
        "arn:aws:s3:::${PROJECT_NAME}-${ENVIRONMENT}-bedrock-*/*"
      ]
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy",
        "logs:TagLogGroup",
        "logs:ListTagsLogGroup",
        "logs:TagResource",
        "logs:ListTagsForResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "KMSForEncryption",
      "Effect": "Allow",
      "Action": [
        "kms:CreateKey",
        "kms:CreateAlias",
        "kms:DeleteAlias",
        "kms:DescribeKey",
        "kms:GetKeyPolicy",
        "kms:GetKeyRotationStatus",
        "kms:ListAliases",
        "kms:ListResourceTags",
        "kms:ScheduleKeyDeletion",
        "kms:TagResource",
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "STSForIRSA",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

# Check if policy exists
if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}" 2>/dev/null; then
  log_info "Updating policy: ${POLICY_NAME}"
  aws iam create-policy-version \
    --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}" \
    --policy-document "${POLICY_DOCUMENT}" \
    --set-as-default
else
  log_info "Creating policy: ${POLICY_NAME}"
  aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --policy-document "${POLICY_DOCUMENT}"
fi

# Ensure policy is attached to the role (idempotent)
aws iam attach-role-policy \
  --role-name "${OIDC_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}" 2>/dev/null || true

log_info "IAM role configured: ${OIDC_ROLE_NAME}"

# -----------------------------------------------------------------------------
# Step 5: Set GitHub Repository Secrets
# -----------------------------------------------------------------------------
log_step "Step 5: Setting GitHub repository secrets..."

# Check if repo exists
if ! gh repo view "${GITHUB_ORG}/${GITHUB_REPO}" &>/dev/null; then
  log_error "Repository ${GITHUB_ORG}/${GITHUB_REPO} not found."
  log_error "Please create the repo and push your code before running hydrate.sh"
  exit 1
fi

# Set secrets for OIDC authentication
gh secret set AWS_ROLE_ARN --body "${ROLE_ARN}" --repo "${GITHUB_ORG}/${GITHUB_REPO}"
gh secret set AWS_REGION --body "${AWS_REGION}" --repo "${GITHUB_ORG}/${GITHUB_REPO}"

# Set secrets for Terraform backend configuration
gh secret set TF_STATE_BUCKET --body "${STATE_BUCKET}" --repo "${GITHUB_ORG}/${GITHUB_REPO}"
gh secret set TF_STATE_KEY --body "bedrock/${ENVIRONMENT}/terraform.tfstate" --repo "${GITHUB_ORG}/${GITHUB_REPO}"
gh secret set TF_LOCK_TABLE --body "${LOCK_TABLE}" --repo "${GITHUB_ORG}/${GITHUB_REPO}"

# Set EKS cluster name for Terraform
gh secret set TF_VAR_eks_cluster_name --body "${EKS_CLUSTER_NAME}" --repo "${GITHUB_ORG}/${GITHUB_REPO}"

log_info "GitHub secrets configured"

# -----------------------------------------------------------------------------
# Step 6: Configure Bedrock Model Access Reminder
# -----------------------------------------------------------------------------
log_step "Step 6: Bedrock model access reminder..."

echo ""
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │ IMPORTANT: Enable Bedrock Model Access                          │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Before running Terraform, enable model access in AWS Console:"
echo ""
echo "  1. Go to: Amazon Bedrock > Model access"
echo "  2. Request access for:"
echo "     - Anthropic Claude (all versions)"
echo "     - Amazon Titan Embeddings"
echo "  3. Wait for approval (usually instant)"
echo ""
echo "  Without this, the Knowledge Base and chatbot will fail to work."
echo ""

# -----------------------------------------------------------------------------
# Step 7: Save Configuration for Cleanup
# -----------------------------------------------------------------------------
log_step "Step 7: Saving configuration..."

CONFIG_FILE="${SCRIPT_DIR}/.hydration-config"
cat > "${CONFIG_FILE}" <<EOF
# Generated by hydrate.sh - used by cleanup.sh
# Do not edit manually
PROJECT_NAME="${PROJECT_NAME}"
ENVIRONMENT="${ENVIRONMENT}"
AWS_REGION="${AWS_REGION}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}"
GITHUB_ORG="${GITHUB_ORG}"
GITHUB_REPO="${GITHUB_REPO}"
STATE_BUCKET="${STATE_BUCKET}"
LOCK_TABLE="${LOCK_TABLE}"
OIDC_ROLE_NAME="${OIDC_ROLE_NAME}"
OIDC_POLICY_NAME="${OIDC_ROLE_NAME}-policy"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME}"
HYDRATION_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

log_info "Saved config to ${CONFIG_FILE}"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
log_info "=========================================="
log_info "Hydration complete!"
log_info "=========================================="
echo ""
echo "Resources created/configured:"
echo "  - S3 Bucket:      ${STATE_BUCKET} (shared with project_kubernetes)"
echo "  - DynamoDB Table: ${LOCK_TABLE} (shared with project_kubernetes)"
echo "  - OIDC Provider:  token.actions.githubusercontent.com"
echo "  - IAM Role:       ${OIDC_ROLE_NAME}"
echo "  - IAM Policy:     ${OIDC_ROLE_NAME}-policy (Bedrock + OpenSearch)"
echo ""
echo "GitHub secrets set:"
echo "  - AWS_ROLE_ARN"
echo "  - AWS_REGION"
echo "  - TF_STATE_BUCKET, TF_STATE_KEY, TF_LOCK_TABLE"
echo "  - TF_VAR_eks_cluster_name (${EKS_CLUSTER_NAME})"
echo ""

# -----------------------------------------------------------------------------
# Step 8: Optionally Trigger Terraform Apply
# -----------------------------------------------------------------------------
TRIGGER_TERRAFORM="y"
read -p "Trigger Terraform Apply via GitHub Actions? [Y/n]: " TRIGGER_TERRAFORM
TRIGGER_TERRAFORM="${TRIGGER_TERRAFORM:-y}"

if [[ "${TRIGGER_TERRAFORM,,}" == "y" || "${TRIGGER_TERRAFORM,,}" == "yes" ]]; then
  log_step "Step 8: Triggering Terraform Apply via GitHub Actions..."

  # Check if workflow exists
  if ! gh workflow list --repo "${GITHUB_ORG}/${GITHUB_REPO}" | grep -qi "terraform"; then
    log_error "No terraform workflow found in ${GITHUB_ORG}/${GITHUB_REPO}"
    log_error "Please push the .github/workflows/terraform.yml file first"
    exit 1
  fi

  # Check if a terraform workflow is already running
  IN_PROGRESS_RUN=$(gh run list --workflow=terraform.yml --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
    --status in_progress --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)

  if [[ -n "$IN_PROGRESS_RUN" ]]; then
    log_info "Terraform workflow already in progress (Run ID: ${IN_PROGRESS_RUN})"
    RUN_ID="$IN_PROGRESS_RUN"
  else
    log_info "Triggering terraform.yml workflow..."
    gh workflow run terraform.yml --repo "${GITHUB_ORG}/${GITHUB_REPO}"

    # Wait for workflow to start
    sleep 5

    # Get the run ID
    RUN_ID=$(gh run list --workflow=terraform.yml --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
      --limit=1 --json databaseId --jq '.[0].databaseId')
  fi

  if [[ -z "$RUN_ID" ]]; then
    log_error "Failed to get workflow run ID"
    exit 1
  fi

  log_info "Workflow Run ID: ${RUN_ID}"
  log_info "View at: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/actions/runs/${RUN_ID}"
  echo ""

  read -p "Watch workflow progress? [Y/n]: " WATCH_WORKFLOW
  WATCH_WORKFLOW="${WATCH_WORKFLOW:-y}"

  if [[ "${WATCH_WORKFLOW,,}" == "y" || "${WATCH_WORKFLOW,,}" == "yes" ]]; then
    log_info "Watching workflow (Ctrl+C to stop)..."
    gh run watch "${RUN_ID}" --repo "${GITHUB_ORG}/${GITHUB_REPO}" --exit-status || true
  fi
else
  log_info "Skipping Terraform Apply"
  echo ""
  echo "Next steps:"
  echo "  1. Enable Bedrock model access in AWS Console"
  echo "  2. Push code to GitHub (if not already)"
  echo "  3. Trigger Terraform manually:"
  echo "     gh workflow run terraform.yml --repo ${GITHUB_ORG}/${GITHUB_REPO}"
fi

echo ""
log_info "Done! Your Bedrock infrastructure is ready to deploy."
echo ""
