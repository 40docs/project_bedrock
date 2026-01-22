#!/usr/bin/env bash
# =============================================================================
# Bedrock Platform Cleanup Script
# =============================================================================
# Tears down all resources created by hydrate.sh and Terraform.
# Run this to completely remove the Bedrock platform.
#
# WARNING: This is destructive and irreversible!
#
# WHAT THIS DOES:
# ---------------
#   1. Triggers terraform destroy via GitHub Actions workflow
#   2. Waits for destroy to complete
#   3. Deletes IAM role and policy for GitHub Actions
#   4. Removes GitHub secrets
#   5. Removes configuration file
#
# USAGE:
#   ./bootstrap/cleanup.sh                  # Full cleanup (terraform + bootstrap)
#   ./bootstrap/cleanup.sh --skip-terraform # Skip destroy, only remove bootstrap
#   ./bootstrap/cleanup.sh --force          # Skip confirmations
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
# Parse Arguments
# -----------------------------------------------------------------------------
SKIP_TERRAFORM=false
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --skip-terraform) SKIP_TERRAFORM=true ;;
    --force) FORCE=true ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --skip-terraform  Skip terraform destroy (only remove bootstrap resources)"
      echo "  --force           Skip confirmation prompts"
      echo "  --help, -h        Show this help message"
      exit 0
      ;;
    *)
      log_error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

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
if [[ "$SKIP_TERRAFORM" != "true" ]]; then
  echo "  - Bedrock Knowledge Base & Data Source"
  echo "  - OpenSearch Serverless collection"
  echo "  - S3 document bucket"
  echo "  - IRSA role & policies"
  echo "  - Guardrails & CloudWatch logs"
fi
echo "  - IAM Role: ${OIDC_ROLE_NAME}"
echo "  - GitHub Secrets in ${GITHUB_ORG}/${GITHUB_REPO}"
echo ""
log_warn "S3 state bucket and DynamoDB table are SHARED with project_kubernetes"
log_warn "and will NOT be deleted by this script."
echo ""

if [[ "$FORCE" != "true" ]]; then
  read -p "Type 'destroy' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "destroy" ]]; then
    log_info "Cleanup cancelled."
    exit 0
  fi
fi

echo ""

# -----------------------------------------------------------------------------
# Step 1: Terraform Destroy via GitHub Actions
# -----------------------------------------------------------------------------
if [[ "$SKIP_TERRAFORM" == "true" ]]; then
  log_warn "Step 1: Skipping terraform destroy (--skip-terraform flag)"
  echo ""
else
  log_info "Step 1: Triggering Terraform Destroy workflow..."

  # Verify gh CLI is available
  if ! command -v gh &>/dev/null; then
    log_error "GitHub CLI (gh) is required to trigger the destroy workflow."
    log_error "Install it or run with --skip-terraform and destroy manually."
    exit 1
  fi

  # Verify workflow exists
  if ! gh workflow list --repo "${GITHUB_ORG}/${GITHUB_REPO}" | grep -qi "destroy"; then
    log_error "No terraform-destroy workflow found in ${GITHUB_ORG}/${GITHUB_REPO}"
    log_error "Push the terraform-destroy.yml workflow file first."
    exit 1
  fi

  # Check if a destroy workflow is already in progress
  IN_PROGRESS_RUN=$(gh run list --workflow=terraform-destroy.yml --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
    --status in_progress --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)

  QUEUED_RUN=$(gh run list --workflow=terraform-destroy.yml --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
    --status queued --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)

  if [[ -n "$IN_PROGRESS_RUN" ]]; then
    log_info "Destroy workflow already in progress (Run ID: ${IN_PROGRESS_RUN})"
    RUN_ID="$IN_PROGRESS_RUN"
  elif [[ -n "$QUEUED_RUN" ]]; then
    log_info "Destroy workflow already queued (Run ID: ${QUEUED_RUN})"
    RUN_ID="$QUEUED_RUN"
  else
    log_info "Triggering terraform-destroy.yml workflow..."
    gh workflow run terraform-destroy.yml \
      --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
      -f confirm="destroy"

    # Wait for workflow to start
    sleep 5

    # Get the run ID
    RUN_ID=$(gh run list --workflow=terraform-destroy.yml --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
      --limit=1 --json databaseId --jq '.[0].databaseId')

    if [[ -z "$RUN_ID" ]]; then
      log_error "Failed to get workflow run ID"
      exit 1
    fi
  fi

  # Watch the workflow
  log_info "Workflow Run ID: ${RUN_ID}"
  log_info "Waiting for Terraform Destroy to complete..."
  log_info "Press Ctrl+C to stop watching (workflow will continue in background)"
  echo ""

  USER_INTERRUPTED=false
  trap 'USER_INTERRUPTED=true' INT

  set +e
  gh run watch "${RUN_ID}" --repo "${GITHUB_ORG}/${GITHUB_REPO}" --exit-status
  WATCH_EXIT_CODE=$?
  set -e

  trap - INT

  if [[ "$USER_INTERRUPTED" == "true" ]]; then
    echo ""
    log_warn "Stopped watching. Terraform destroy continues in background."
    echo ""
    echo "To check status later:"
    echo "  gh run view ${RUN_ID} --repo ${GITHUB_ORG}/${GITHUB_REPO}"
    echo ""
    log_error "Cleanup aborted. Run cleanup again after terraform destroy completes."
    exit 1
  elif [[ $WATCH_EXIT_CODE -eq 0 ]]; then
    log_info "Terraform Destroy completed successfully"
  else
    log_error "Terraform Destroy workflow failed!"
    log_error "Check logs: gh run view ${RUN_ID} --repo ${GITHUB_ORG}/${GITHUB_REPO} --log"
    if [[ "$FORCE" != "true" ]]; then
      exit 1
    else
      log_warn "Continuing cleanup despite failure (--force)"
    fi
  fi

  echo ""
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
# Step 5: Delete Kubernetes ServiceAccount (if exists)
# -----------------------------------------------------------------------------
log_info "Step 5: Cleaning up Kubernetes ServiceAccount..."

if command -v kubectl &>/dev/null; then
  if kubectl delete sa chatbot-backend -n chatbot 2>/dev/null; then
    log_info "Deleted ServiceAccount: chatbot-backend"
  else
    log_warn "ServiceAccount not found or already deleted"
  fi
else
  log_warn "kubectl not available, skipping ServiceAccount cleanup"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
log_info "=========================================="
log_info "Cleanup complete!"
log_info "=========================================="
echo ""
echo "Deleted:"
if [[ "$SKIP_TERRAFORM" != "true" ]]; then
  echo "  - Bedrock Knowledge Base & OpenSearch collection"
  echo "  - S3 document bucket"
  echo "  - IRSA role & Guardrails"
fi
echo "  - IAM Role: ${OIDC_ROLE_NAME}"
echo "  - GitHub Secrets"
echo "  - Configuration file"
echo ""
echo "NOT deleted (shared with project_kubernetes):"
echo "  - S3 Bucket: ${STATE_BUCKET}"
echo "  - DynamoDB Table: ${LOCK_TABLE}"
echo "  - GitHub OIDC Provider"
echo ""
