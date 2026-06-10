# Spec: SageMaker Studio Code Editor — CDK Automation

## Goal
Deploy SageMaker Studio with Code Editor (VS Code in browser) into a private VPC.
Single-user POC that can be promoted to multi-user prod with a config flag.

---

## Stack
- **CDK v2**, TypeScript
- **Target account**: single AWS account, single region (default `ap-southeast-2`)
- **Entry**: `cdk deploy` with context flags for POC vs prod mode

---

## Architecture

```
Browser (HTTPS)
  → AWS Console / presigned Studio URL   [AWS-managed, not in our VPC]
  → SageMaker control plane
  → Code Editor app instance             [private subnet, our VPC]
  → VPC Endpoints                        [S3, STS, ECR, SageMaker API]
```

The compute (Code Editor instance) runs in our VPC.
The browser-to-Studio hop is AWS-managed HTTPS — no VPN required on client side.

---

## CDK Stacks

### Stack 1: `VpcStack`

Create a new VPC (do not use default VPC).

```
Construct:  ec2.Vpc
AZs:        2 (enough for POC; SageMaker requires >= 1 subnet)
Subnets:
  - PRIVATE_WITH_EGRESS  (Code Editor instances live here)
  - PUBLIC               (NAT Gateway attachment only — POC mode)
NAT:
  - POC mode:  1x NAT Gateway (cheapest, ~$32/month)
  - Prod mode: 0x NAT Gateway + VPC endpoints only (context flag: natMode=endpoints)
```

Context flag: `--context natMode=nat|endpoints`  
Default: `nat` (POC)

### Stack 2: `EndpointsStack`

VPC Interface Endpoints required for `VpcOnly` mode (no public internet from instance).

| Endpoint | Type | Required |
|---|---|---|
| `com.amazonaws.{region}.sagemaker.api` | Interface | Yes |
| `com.amazonaws.{region}.sagemaker.runtime` | Interface | Yes |
| `com.amazonaws.{region}.sts` | Interface | Yes |
| `com.amazonaws.{region}.ecr.api` | Interface | Yes |
| `com.amazonaws.{region}.ecr.dkr` | Interface | Yes |
| `com.amazonaws.{region}.s3` | Gateway | Yes (free) |

Deploy endpoints only when `natMode=endpoints`.  
In POC (`natMode=nat`) skip interface endpoints — traffic routes via NAT.

### Stack 3: `StudioStack`

#### IAM — Execution Role
```
Principal:  sagemaker.amazonaws.com
Policies:
  - AmazonSageMakerFullAccess (POC)
  - Custom boundary (prod): deny CreateTrainingJob, CreateEndpoint, etc.
    (Code Editor only needs: Studio, S3, ECR pull, CloudWatch Logs)
```

Prod policy should scope S3 to specific bucket ARNs via context.

#### SageMaker Domain
```typescript
new sagemaker.CfnDomain({
  domainName: 'code-editor-domain',
  authMode: 'IAM',                        // SSO if prod + AWS SSO configured
  vpcId: vpc.vpcId,
  subnetIds: vpc.privateSubnets.map(s => s.subnetId),
  appNetworkAccessType: isProd            // context flag: prod=true
    ? 'VpcOnly'
    : 'PublicInternetOnly',              // cheaper for POC — no endpoints needed
  defaultUserSettings: {
    executionRole: role.roleArn,
    codeEditorAppSettings: {
      appLifecycleManagement: {
        idleSettings: {
          lifecycleManagement: 'ENABLED',
          idleTimeoutInMinutes: 60,        // minimum allowed
          minIdleTimeoutInMinutes: 60,
          maxIdleTimeoutInMinutes: 480,
        }
      },
      // SageMaker Distribution v2.0+ required for native idle shutdown
      defaultResourceSpec: {
        instanceType: 'ml.t3.medium',
        sageMakerImageArn: '<SMD-2.0-image-arn-per-region>'  // resolve in code
      }
    }
  }
})
```

> **Note**: SageMaker Distribution image ARNs differ per region. Resolve at synth time
> from SSM parameter: `/aws/service/sagemaker/Studio/image-versions/sagemaker-distribution/2.0/{arch}`

#### User Profile
```
One profile per deploy (POC).
Name: from context --context userName=<name>, default 'dev'
```

#### EFS (Home Directory)
```
SageMaker auto-creates EFS on domain creation.
Do NOT provision separately — just ensure VPC has EFS SG ingress on 2049 from SageMaker SG.
Output the EFS ID in CfnOutput for manual deletion reminder.
```

---

## Context Flags

| Flag | Values | Default | Effect |
|---|---|---|---|
| `prod` | `true\|false` | `false` | VpcOnly, tighter IAM, multi-AZ |
| `natMode` | `nat\|endpoints` | `nat` | NAT GW vs VPC endpoints |
| `userName` | string | `dev` | Studio user profile name |
| `region` | string | `ap-southeast-2` | Deploy region |

Usage:
```bash
# POC (cheapest)
cdk deploy --all --context prod=false --context userName=myname

# Prod-ready
cdk deploy --all --context prod=true --context natMode=endpoints
```

---

## Outputs (CfnOutput)

| Output | Value |
|---|---|
| `StudioUrl` | `https://studio.{region}.sagemaker.aws/domain/{domainId}` |
| `DomainId` | SageMaker domain ID |
| `EfsId` | EFS filesystem ID (reminder to delete for cost) |
| `ExecutionRoleArn` | IAM role ARN |

---

## Cost Profile (ap-southeast-2, POC mode)

| Resource | Cost |
|---|---|
| Code Editor ml.t3.medium | ~$0.07/hr (stopped = $0) |
| NAT Gateway | ~$0.059/hr + data (always on while stack deployed) |
| EFS | ~$0.36/GB/month |
| VPC, subnets, SG | $0 |

**POC teardown**: `cdk destroy --all` removes everything except EFS (SageMaker retains it).
Must manually delete EFS after domain deletion or it bills indefinitely.

Add a `cdk destroy` post-hook reminder or a separate `DestroyHelper` custom resource
that deletes the EFS mount targets + filesystem on stack destroy.

---

## File Structure (expected output from Claude Code)

```
sagemaker-code-editor/
├── bin/
│   └── app.ts                  # CDK app entry, reads context
├── lib/
│   ├── vpc-stack.ts
│   ├── endpoints-stack.ts
│   ├── studio-stack.ts
│   └── config.ts               # context resolution, SMD ARN lookup
├── scripts/
│   └── cleanup-efs.sh          # manual EFS delete helper
├── cdk.json
├── package.json
└── README.md                   # deploy instructions, cost table, teardown steps
```

---

## Key Constraints

1. SageMaker Distribution **v2.0+** required for native idle shutdown — hardcode or resolve via SSM.
2. `VpcOnly` requires all 5 interface endpoints — skip in POC (`prod=false`).
3. EFS is NOT auto-deleted by `cdk destroy` — implement custom resource or document manual step.
4. Idle timeout minimum is **60 minutes** — do not attempt lower values.
5. Code Editor image ARNs are **region-specific** — must be resolved dynamically, not hardcoded.
6. SageMaker domain requires **at least 1 private subnet** — even in POC mode.