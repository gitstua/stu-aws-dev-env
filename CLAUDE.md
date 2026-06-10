# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

CDK v2 TypeScript project that deploys SageMaker Studio with Code Editor (VS Code in browser) into a private VPC. Single-user POC that can be promoted to multi-user prod via context flags. Target region: `ap-southeast-2`.

The full spec is in [SPEC.md](SPEC.md).

## Commands

```bash
# Install dependencies (after scaffolding)
npm install

# Synthesize CloudFormation templates
npx cdk synth

# Deploy all stacks — POC mode (default)
npx cdk deploy --all --context prod=false --context userName=dev

# Deploy all stacks — prod mode
npx cdk deploy --all --context prod=true --context natMode=endpoints

# Destroy all stacks (EFS requires manual deletion after — see below)
npx cdk destroy --all

# TypeScript compile check
npx tsc --noEmit

# Run tests
npm test
```

## Context flags

| Flag | Values | Default | Effect |
|---|---|---|---|
| `prod` | `true\|false` | `false` | VpcOnly networking, tighter IAM |
| `natMode` | `nat\|endpoints` | `nat` | NAT Gateway vs VPC interface endpoints |
| `userName` | string | `dev` | SageMaker Studio user profile name |
| `region` | string | `ap-southeast-2` | Deploy region |

## Architecture

Three CDK stacks, deployed in dependency order:

**VpcStack** → **EndpointsStack** → **StudioStack**

- **VpcStack**: Creates a new VPC (never the default VPC). 2 AZs, private-with-egress subnets (Code Editor lives here) + public subnets. POC: 1 NAT Gateway. Prod (`natMode=endpoints`): 0 NAT Gateways.
- **EndpointsStack**: VPC interface endpoints for `sagemaker.api`, `sagemaker.runtime`, `sts`, `ecr.api`, `ecr.dkr`, and an S3 gateway endpoint. Only deployed when `natMode=endpoints`; skipped in POC.
- **StudioStack**: IAM execution role, SageMaker Domain, one user profile, and CfnOutputs. Domain uses `appNetworkAccessType: VpcOnly` in prod, `PublicInternetOnly` in POC.

Config/context resolution lives in `lib/config.ts`. The CDK app entry (`bin/app.ts`) reads context and wires stacks together.

## Key constraints

1. **SageMaker Distribution v2.0+** is required for native idle shutdown. The image ARN is region-specific — resolve at synth time from SSM parameter `/aws/service/sagemaker/Studio/image-versions/sagemaker-distribution/2.0/{arch}`, do not hardcode.
2. **`VpcOnly` requires all 5 interface endpoints** — if `prod=true`, `EndpointsStack` must be deployed; without them the domain will fail to launch.
3. **EFS is not deleted by `cdk destroy`** — SageMaker auto-creates EFS on domain creation and retains it after destroy. Implement a custom resource (or `scripts/cleanup-efs.sh`) and document the manual deletion step to avoid indefinite billing.
4. **Idle timeout minimum is 60 minutes** — `minIdleTimeoutInMinutes` cannot go below 60.
5. **At least 1 private subnet required** — SageMaker domain creation fails without it, even in POC mode.
6. IAM role in POC uses `AmazonSageMakerFullAccess`. Prod mode should add a permissions boundary denying `CreateTrainingJob`, `CreateEndpoint`, and similar; scope S3 to specific bucket ARNs via context.

## Cost notes (ap-southeast-2, POC)

- Code Editor `ml.t3.medium`: ~$0.07/hr (stopped = $0)
- NAT Gateway: ~$0.059/hr + data transfer (always on while stack is deployed)
- EFS: ~$0.36/GB/month
- Interface endpoints: ~$0.013/hr each × 5 (only in prod mode)

Teardown: `cdk destroy --all`, then manually delete the EFS filesystem.
