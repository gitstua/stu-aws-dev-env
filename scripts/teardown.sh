#!/usr/bin/env bash
# teardown.sh — destroy all CDK stacks and delete the retained EFS filesystem.
#
# SageMaker auto-creates an EFS for the domain home directory and does NOT delete
# it on stack destroy. This script captures the EFS ID before destroying, then
# deletes the filesystem (and its mount targets) after CDK finishes.
#
# Usage:
#   ./scripts/teardown.sh [options]
#
# Options must match those used during deploy:
#   --prod
#   --nat-endpoints
#   --user NAME         (default: dev)
#   --region REGION     (default: ap-southeast-2)
#   --help

set -euo pipefail
cd "$(dirname "$0")/.."

# --- defaults ---
PROD=false
NAT_MODE=nat
USER_NAME=dev
REGION=ap-southeast-2

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --prod)            PROD=true; shift ;;
    --nat-endpoints)   NAT_MODE=endpoints; shift ;;
    --user)            USER_NAME="$2"; shift 2 ;;
    --region)          REGION="$2"; shift 2 ;;
    --help|-h)         usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "=== SageMaker Studio Code Editor — Teardown ==="
echo "  prod:     $PROD"
echo "  natMode:  $NAT_MODE"
echo "  userName: $USER_NAME"
echo "  region:   $REGION"
echo ""
echo "This will destroy ALL stacks and delete the EFS filesystem."
read -r -p "Continue? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

CDK_CONTEXT=(
  "--context" "prod=$PROD"
  "--context" "natMode=$NAT_MODE"
  "--context" "userName=$USER_NAME"
  "--context" "region=$REGION"
)

# Capture EFS ID from CloudFormation outputs BEFORE destroying the stack.
echo "--- Fetching EFS ID from CloudFormation outputs ---"
EFS_ID=$(
  aws cloudformation describe-stacks \
    --stack-name StudioStack \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='EfsId'].OutputValue" \
    --output text 2>/dev/null || true
)

if [[ -z "$EFS_ID" || "$EFS_ID" == "None" ]]; then
  echo "  StudioStack not found or EfsId output missing — skipping EFS cleanup."
  EFS_ID=""
else
  echo "  EFS filesystem to delete after destroy: $EFS_ID"
fi
echo ""

# Destroy all stacks.
echo "--- Destroying CDK stacks ---"
npx cdk destroy --all --force "${CDK_CONTEXT[@]}"
echo ""

# Delete EFS after domain is gone (SageMaker must be destroyed first to release the FS).
if [[ -n "$EFS_ID" ]]; then
  echo "--- Cleaning up EFS filesystem $EFS_ID ---"
  ./scripts/cleanup-efs.sh "$EFS_ID" "$REGION"
fi

echo ""
echo "=== Teardown complete ==="
