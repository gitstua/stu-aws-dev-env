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

# Delete all spaces before CDK destroy — SageMaker won't delete a user profile
# while spaces exist, and CDK won't delete a domain while the user profile exists.
DOMAIN_ID=$(
  aws cloudformation describe-stacks \
    --stack-name StudioStack \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='DomainId'].OutputValue" \
    --output text 2>/dev/null || true
)

if [[ -n "$DOMAIN_ID" && "$DOMAIN_ID" != "None" ]]; then
  echo "--- Deleting SageMaker apps and spaces in domain $DOMAIN_ID ---"

  # Delete all non-deleted apps first (spaces can't be deleted while apps are running)
  APPS=$(aws sagemaker list-apps --region "$REGION" --domain-id-equals "$DOMAIN_ID" \
    --query "Apps[?Status!='Deleted'].[DomainId,UserProfileName,SpaceName,AppType,AppName]" \
    --output text 2>/dev/null || true)
  while IFS=$'\t' read -r dom user space apptype appname; do
    [[ -z "$appname" ]] && continue
    echo "  Deleting app: $appname ($apptype) in space $space"
    aws sagemaker delete-app --region "$REGION" \
      --domain-id "$dom" --space-name "$space" \
      --app-type "$apptype" --app-name "$appname" 2>/dev/null || true
  done <<< "$APPS"

  # Wait for apps to reach Deleted state
  echo "  Waiting for apps to be deleted..."
  for i in $(seq 1 24); do
    REMAINING=$(aws sagemaker list-apps --region "$REGION" --domain-id-equals "$DOMAIN_ID" \
      --query "length(Apps[?Status!='Deleted'])" --output text 2>/dev/null || echo 0)
    [[ "$REMAINING" == "0" ]] && break
    echo "  $REMAINING app(s) still deleting... (${i}/24)"
    sleep 10
  done

  # Delete all spaces
  SPACES=$(aws sagemaker list-spaces --region "$REGION" --domain-id-equals "$DOMAIN_ID" \
    --query "Spaces[*].[DomainId,SpaceName]" --output text 2>/dev/null || true)
  while IFS=$'\t' read -r dom space; do
    [[ -z "$space" ]] && continue
    echo "  Deleting space: $space"
    aws sagemaker delete-space --region "$REGION" \
      --domain-id "$dom" --space-name "$space" 2>/dev/null || true
  done <<< "$SPACES"

  # Wait for spaces to be deleted
  echo "  Waiting for spaces to be deleted..."
  for i in $(seq 1 24); do
    REMAINING=$(aws sagemaker list-spaces --region "$REGION" --domain-id-equals "$DOMAIN_ID" \
      --query "length(Spaces)" --output text 2>/dev/null || echo 0)
    [[ "$REMAINING" == "0" ]] && break
    echo "  $REMAINING space(s) still deleting... (${i}/24)"
    sleep 10
  done

  echo ""
fi

# Delete SageMaker-created NFS security groups that block VPC deletion.
if [[ -n "$DOMAIN_ID" && "$DOMAIN_ID" != "None" ]]; then
  VPC_ID=$(aws cloudformation describe-stack-resources \
    --stack-name VpcStack --region "$REGION" \
    --query "StackResources[?LogicalResourceId=='Vpc8378EB38'].PhysicalResourceId" \
    --output text 2>/dev/null || true)
  if [[ -n "$VPC_ID" ]]; then
    SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=security-group-for-*-nfs-${DOMAIN_ID}" \
      --query "SecurityGroups[*].GroupId" --output text 2>/dev/null || true)
    for SG_ID in $SG_IDS; do
      echo "  Clearing rules and deleting security group $SG_ID"
      RULES=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG_ID" \
        --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null || echo "[]")
      [[ "$RULES" != "[]" ]] && aws ec2 revoke-security-group-ingress \
        --region "$REGION" --group-id "$SG_ID" --ip-permissions "$RULES" 2>/dev/null || true
      EGRESS=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG_ID" \
        --query "SecurityGroups[0].IpPermissionsEgress" --output json 2>/dev/null || echo "[]")
      [[ "$EGRESS" != "[]" ]] && aws ec2 revoke-security-group-egress \
        --region "$REGION" --group-id "$SG_ID" --ip-permissions "$EGRESS" 2>/dev/null || true
      aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null || true
    done
  fi
fi

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
