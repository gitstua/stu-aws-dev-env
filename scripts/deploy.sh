#!/usr/bin/env bash
# deploy.sh — build and deploy the SageMaker Studio Code Editor CDK stacks.
#
# Usage:
#   ./scripts/deploy.sh [options]
#
# Options (all optional, passed straight through to cdk deploy):
#   --prod              Deploy in prod mode (VpcOnly, tighter IAM)
#   --nat-endpoints     Use VPC endpoints instead of NAT Gateway
#   --user NAME         Studio user profile name (default: dev)
#   --region REGION     AWS region (default: ap-southeast-2)
#   --help
#
# Examples:
#   ./scripts/deploy.sh
#   ./scripts/deploy.sh --prod --nat-endpoints --user alice
#   ./scripts/deploy.sh --region us-east-1 --user bob

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

# Validate: prod without endpoints is unusual — warn but allow.
if [[ "$PROD" == "true" && "$NAT_MODE" == "nat" ]]; then
  echo "Warning: --prod is set but --nat-endpoints is not. Domain will use VpcOnly but"
  echo "         interface endpoints won't be deployed (NAT will handle service traffic)."
  echo "         Pass --nat-endpoints to deploy full endpoint set."
  echo ""
fi

echo "=== SageMaker Studio Code Editor — Deploy ==="
echo "  prod:     $PROD"
echo "  natMode:  $NAT_MODE"
echo "  userName: $USER_NAME"
echo "  region:   $REGION"
echo ""

# Install dependencies if node_modules is missing or package.json is newer.
if [[ ! -d node_modules ]] || [[ package.json -nt node_modules ]]; then
  echo "--- Installing npm dependencies ---"
  npm install
  echo ""
fi

CDK_CONTEXT=(
  "--context" "prod=$PROD"
  "--context" "natMode=$NAT_MODE"
  "--context" "userName=$USER_NAME"
  "--context" "region=$REGION"
)

echo "--- Synthesising CloudFormation templates ---"
npx cdk synth --all "${CDK_CONTEXT[@]}"
echo ""

echo "--- Deploying all stacks ---"
npx cdk deploy --all --require-approval never "${CDK_CONTEXT[@]}"
echo ""

echo "=== Deploy complete ==="
echo ""
echo "Tip: To stop the Code Editor instance and avoid compute charges, open Studio"
echo "     and shut down the running app from the Running Instances panel."
echo ""
echo "Tip: To tear everything down (including EFS cleanup), run:"
echo "     ./scripts/teardown.sh [same flags as above]"
