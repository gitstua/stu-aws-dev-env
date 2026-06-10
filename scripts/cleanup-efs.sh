#!/usr/bin/env bash
# cleanup-efs.sh — delete an EFS filesystem and all of its mount targets.
#
# Called automatically by teardown.sh, or run manually if you need to clean up
# an orphaned filesystem left behind by a previous deploy.
#
# Usage:
#   ./scripts/cleanup-efs.sh <EFS_ID> [REGION]
#
# Examples:
#   ./scripts/cleanup-efs.sh fs-0123456789abcdef0
#   ./scripts/cleanup-efs.sh fs-0123456789abcdef0 us-east-1
#
# To find EFS IDs from a running stack:
#   aws cloudformation describe-stacks --stack-name StudioStack \
#     --query "Stacks[0].Outputs[?OutputKey=='EfsId'].OutputValue" --output text

set -euo pipefail

EFS_ID="${1:-}"
REGION="${2:-${AWS_DEFAULT_REGION:-ap-southeast-2}}"

if [[ -z "$EFS_ID" ]]; then
  echo "Usage: $0 <EFS_ID> [REGION]" >&2
  exit 1
fi

echo "Deleting EFS mount targets for $EFS_ID in $REGION..."

MT_IDS=$(
  aws efs describe-mount-targets \
    --file-system-id "$EFS_ID" \
    --region "$REGION" \
    --query 'MountTargets[].MountTargetId' \
    --output text 2>/dev/null || true
)

if [[ -n "$MT_IDS" ]]; then
  for MT_ID in $MT_IDS; do
    echo "  Deleting mount target $MT_ID..."
    aws efs delete-mount-target \
      --mount-target-id "$MT_ID" \
      --region "$REGION"
  done

  echo "  Waiting for mount targets to be deleted (up to 60s)..."
  DEADLINE=$(( $(date +%s) + 60 ))
  while true; do
    REMAINING=$(
      aws efs describe-mount-targets \
        --file-system-id "$EFS_ID" \
        --region "$REGION" \
        --query 'MountTargets[].MountTargetId' \
        --output text 2>/dev/null || true
    )
    [[ -z "$REMAINING" ]] && break
    if (( $(date +%s) >= DEADLINE )); then
      echo "  Timed out waiting for mount target deletion. Retrying delete-file-system anyway..." >&2
      break
    fi
    sleep 5
  done
else
  echo "  No mount targets found."
fi

echo "Deleting EFS filesystem $EFS_ID..."
aws efs delete-file-system \
  --file-system-id "$EFS_ID" \
  --region "$REGION"

echo "EFS filesystem $EFS_ID deleted."
