#!/usr/bin/env bash
# check-spending.sh — verify no billable resources are running in ap-southeast-2.

set -euo pipefail

REGION=${1:-ap-southeast-2}

echo "=== Checking for billable resources in $REGION ==="
echo ""

echo "--- NAT Gateways ---"
aws ec2 describe-nat-gateways --region "$REGION" \
  --filter Name=state,Values=available \
  --query "NatGateways[*].{ID:NatGatewayId,VPC:VpcId,State:State}" \
  --output table

echo "--- EFS Filesystems ---"
aws efs describe-file-systems --region "$REGION" \
  --query "FileSystems[*].{ID:FileSystemId,SizeGB:SizeInBytes.Value,State:LifeCycleState}" \
  --output table

echo "--- SageMaker Domains ---"
aws sagemaker list-domains --region "$REGION" \
  --query "Domains[*].{ID:DomainId,Name:DomainName,Status:Status}" \
  --output table

echo "--- SageMaker Apps (InService only — these bill) ---"
aws sagemaker list-apps --region "$REGION" \
  --query "Apps[?Status=='InService'].{Domain:DomainId,Space:SpaceName,App:AppName,Status:Status}" \
  --output table

echo "--- VPC Interface Endpoints ---"
aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters Name=vpc-endpoint-state,Values=available,pending \
  --query "VpcEndpoints[?VpcEndpointType=='Interface'].{ID:VpcEndpointId,Service:ServiceName,State:State}" \
  --output table

echo ""
echo "=== Done. Empty tables = nothing billable running. ==="
