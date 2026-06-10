#!/usr/bin/env bash
# check-spending.sh — verify no billable resources are running in ap-southeast-2.

set -euo pipefail
export AWS_PAGER=""

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

echo "--- AWS costs this month (by service) ---"
echo "    Note: Cost Explorer data is typically delayed 24-48 hrs. Third-party marketplace"
echo "    charges (e.g. SageMaker Distribution image fees) may take up to 72 hrs to appear."
START=$(date -v1d +%Y-%m-%d 2>/dev/null || date -d "$(date +%Y-%m-01)" +%Y-%m-%d)
END=$(date +%Y-%m-%d)
aws ce get-cost-and-usage \
  --time-period "Start=$START,End=$END" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --region us-east-1 2>/dev/null \
| python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = []
for result in data.get('ResultsByTime', []):
    for group in result.get('Groups', []):
        amt = float(group['Metrics']['UnblendedCost']['Amount'])
        if amt > 0.0001:
            rows.append((group['Keys'][0], amt))
rows.sort(key=lambda x: -x[1])
if rows:
    print(f'  {\"Service\":<50} {\"USD\":>10}')
    print(f'  {\"-\"*50} {\"-\"*10}')
    for svc, amt in rows:
        print(f'  {svc:<50} \${amt:>9.4f}')
    print(f'  {\"-\"*50} {\"-\"*10}')
    print(f'  {\"TOTAL\":<50} \${sum(a for _,a in rows):>9.4f}')
else:
    print('  No costs recorded yet this month.')
" || echo "  (Cost Explorer unavailable — enable it in the AWS Console under Billing)"

echo ""
echo "=== Done. All resource tables should be empty for zero ongoing charges. ==="
echo "    Note: EFS bills by storage used — delete any listed filesystems if no longer needed."
