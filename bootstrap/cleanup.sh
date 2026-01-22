#!/usr/bin/env bash
# =============================================================================
# Bedrock Platform Cleanup Script
# =============================================================================
# Removes all resources created by hydrate.sh.
# Run this only when completely decommissioning the Bedrock infrastructure.
#
# WARNING: This will delete:
#   - IAM role and policy for GitHub Actions
#   - GitHub repository secrets
#   - Optionally: S3 bucket and DynamoDB table (if not shared)
#
# NOTE: This does NOT delete:
#   - Bedrock resources (run terraform destroy first!)
#   - EKS cluster (managed by project_kubernetes)
#
# USAGE:
#   ./bootstrap/cleanup.sh
#
# =============================================================================
set -euo pipefail

export AWS_PAGER=""
export GH_PROMPT_DISABLED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.hydration-config"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -----------------------------------------------------------------------------
# Load Configuration
# -----------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
  log_error "Configuration file not found: ${CONFIG_FILE}"
  log_error "Run hydrate.sh first to create the configuration."
  exit 1
fi

source "$CONFIG_FILE"

echo ""
log_warn "=========================================="
log_warn "BEDROCK PLATFORM CLEANUP"
log_warn "=========================================="
echo ""
echo "This will delete the following resources:"
echo "  - IAM Role: ${OIDC_ROLE_NAME}"
echo "  - IAM Policy: ${OIDC_POLICY_NAME}"
echo "  - GitHub Secrets in ${GITHUB_ORG}/${GITHUB_REPO}"
echo ""
echo "This will NOT delete (run terraform destroy first!):"
echo "  - Bedrock Knowledge Base"
echo "  - OpenSearch Serverless collection"
echo "  - S3 buckets with documents"
echo "  - CloudWatch log groups"
echo ""
log_warn "S3 bucket and DynamoDB table are SHARED with project_kubernetes"
log_warn "and will NOT be deleted by this script."
echo ""

read -p "Are you sure you want to proceed? [y/N]: " CONFIRM
CONFIRM="${CONFIRM:-n}"

if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
  log_info "Cleanup cancelled."
  exit 0
fi

echo ""

# -----------------------------------------------------------------------------
# Step 1: Run Terraform Destroy Reminder
# -----------------------------------------------------------------------------
log_info "Step 1: Terraform destroy reminder..."

echo ""
log_warn "Have you run 'terraform destroy' to remove Bedrock resources?"
echo ""
echo "If not, run these commands first:"
echo "  cd terraform/environments/dev"
echo "  terraform destroy"
echo ""

read -p "Continue with cleanup? [y/N]: " CONTINUE_CLEANUP
CONTINUE_CLEANUP="${CONTINUE_CLEANUP:-n}"

if [[ "${CONTINUE_CLEANUP,,}" != "y" && "${CONTINUE_CLEANUP,,}" != "yes" ]]; then
  log_info "Run terraform destroy first, then re-run this script."
  exit 0
fi

# -----------------------------------------------------------------------------
# Step 2: Delete GitHub Secrets
# -----------------------------------------------------------------------------
log_info "Step 2: Deleting GitHub repository secrets..."

SECRETS=(
  "AWS_ROLE_ARN"
  "AWS_REGION"
  "TF_STATE_BUCKET"
  "TF_STATE_KEY"
  "TF_LOCK_TABLE"
  "TF_VAR_eks_cluster_name"
)

for secret in "${SECRETS[@]}"; do
  if gh secret delete "$secret" --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null; then
    log_info "Deleted secret: $secret"
  else
    log_warn "Secret not found or already deleted: $secret"
  fi
done

# -----------------------------------------------------------------------------
# Step 3: Delete IAM Role and Policy
# -----------------------------------------------------------------------------
log_info "Step 3: Deleting IAM role and policy..."

# Detach policy from role
if aws iam detach-role-policy \
    --role-name "${OIDC_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${OIDC_POLICY_NAME}" 2>/dev/null; then
  log_info "Detached policy from role"
fi

# Delete inline policies
INLINE_POLICIES=$(aws iam list-role-policies --role-name "${OIDC_ROLE_NAME}" \
  --query 'PolicyNames' --output text 2>/dev/null || true)

for policy in $INLINE_POLICIES; do
  aws iam delete-role-policy --role-name "${OIDC_ROLE_NAME}" --policy-name "$policy" 2>/dev/null || true
  log_info "Deleted inline policy: $policy"
done

# Delete the role
if aws iam delete-role --role-name "${OIDC_ROLE_NAME}" 2>/dev/null; then
  log_info "Deleted IAM role: ${OIDC_ROLE_NAME}"
else
  log_warn "IAM role not found or already deleted: ${OIDC_ROLE_NAME}"
fi

# Delete the policy
if aws iam delete-policy \
    --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${OIDC_POLICY_NAME}" 2>/dev/null; then
  log_info "Deleted IAM policy: ${OIDC_POLICY_NAME}"
else
  log_warn "IAM policy not found or already deleted: ${OIDC_POLICY_NAME}"
fi

# -----------------------------------------------------------------------------
# Step 4: Remove Configuration File
# -----------------------------------------------------------------------------
log_info "Step 4: Removing configuration file..."

rm -f "$CONFIG_FILE"
log_info "Removed: ${CONFIG_FILE}"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
log_info "=========================================="
log_info "Cleanup complete!"
log_info "=========================================="
echo ""
echo "Deleted:"
echo "  - IAM Role: ${OIDC_ROLE_NAME}"
echo "  - IAM Policy: ${OIDC_POLICY_NAME}"
echo "  - GitHub Secrets"
echo "  - Configuration file"
echo ""
echo "NOT deleted (shared with project_kubernetes):"
echo "  - S3 Bucket: ${STATE_BUCKET}"
echo "  - DynamoDB Table: ${LOCK_TABLE}"
echo "  - GitHub OIDC Provider"
echo ""
