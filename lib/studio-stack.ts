import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as sagemaker from 'aws-cdk-lib/aws-sagemaker';
import { Construct } from 'constructs';
import { Config } from './config';
import { VpcStack } from './vpc-stack';

export class StudioStack extends cdk.Stack {
  constructor(scope: Construct, id: string, vpcStack: VpcStack, config: Config, props?: cdk.StackProps) {
    super(scope, id, props);

    const { vpc, privateSubnets } = vpcStack;

    // --- IAM Execution Role ---

    const role = new iam.Role(this, 'ExecutionRole', {
      assumedBy: new iam.ServicePrincipal('sagemaker.amazonaws.com'),
      description: 'SageMaker Studio Code Editor execution role',
    });

    if (config.prod) {
      // Permissions boundary caps what this role can do — denies training/inference APIs.
      const boundary = new iam.ManagedPolicy(this, 'ExecutionBoundary', {
        statements: [
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            actions: [
              'sagemaker:CreateApp',
              'sagemaker:DeleteApp',
              'sagemaker:DescribeApp',
              'sagemaker:ListApps',
              'sagemaker:DescribeDomain',
              'sagemaker:DescribeUserProfile',
              'sagemaker:UpdateUserProfile',
              'sagemaker:CreatePresignedDomainUrl',
              's3:GetObject',
              's3:PutObject',
              's3:DeleteObject',
              's3:ListBucket',
              'ecr:GetDownloadUrlForLayer',
              'ecr:BatchGetImage',
              'ecr:GetAuthorizationToken',
              'ecr:BatchCheckLayerAvailability',
              'logs:CreateLogGroup',
              'logs:CreateLogStream',
              'logs:PutLogEvents',
              'logs:DescribeLogGroups',
              'logs:DescribeLogStreams',
              'ssm:GetParameter',
            ],
            resources: ['*'],
          }),
        ],
      });
      iam.PermissionsBoundary.of(role).apply(boundary);

      role.addToPolicy(
        new iam.PolicyStatement({
          effect: iam.Effect.ALLOW,
          actions: [
            'sagemaker:CreateApp',
            'sagemaker:DeleteApp',
            'sagemaker:DescribeApp',
            'sagemaker:ListApps',
            'sagemaker:DescribeDomain',
            'sagemaker:DescribeUserProfile',
            'sagemaker:UpdateUserProfile',
            'sagemaker:CreatePresignedDomainUrl',
            's3:GetObject',
            's3:PutObject',
            's3:DeleteObject',
            's3:ListBucket',
            'ecr:GetDownloadUrlForLayer',
            'ecr:BatchGetImage',
            'ecr:GetAuthorizationToken',
            'ecr:BatchCheckLayerAvailability',
            'logs:CreateLogGroup',
            'logs:CreateLogStream',
            'logs:PutLogEvents',
            'logs:DescribeLogGroups',
            'logs:DescribeLogStreams',
            'ssm:GetParameter',
          ],
          resources: ['*'],
        }),
      );
    } else {
      role.addManagedPolicy(
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSageMakerFullAccess'),
      );
    }


    // --- Lifecycle Config: install Claude Code extension on space start ---

    const lccScript = [
      '#!/bin/bash',
      'set -eux',
      '',
      'EXTENSIONS_DIR=/home/sagemaker-user/sagemaker-code-editor-server-data/extensions',
      'mkdir -p "$EXTENSIONS_DIR"',
      '',
      '# Query marketplace API for latest version number',
      "VERSION=$(curl -sf 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' \\",
      "  -H 'Content-Type: application/json' \\",
      "  -H 'Accept: application/json;api-version=7.2-preview.1' \\",
      '  -d \'{"filters":[{"criteria":[{"filterType":7,"value":"Anthropic.claude-code"}]}],"flags":512}\' \\',
      "  | python3 -c \"import json,sys; print(json.load(sys.stdin)['results'][0]['extensions'][0]['versions'][0]['version'])\")",
      'echo "Installing Claude Code extension version: $VERSION"',
      '',
      'curl -sSL -o /tmp/claude-code.vsix \\',
      '  "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/Anthropic/vsextensions/claude-code/$VERSION/vspackage?targetPlatform=linux-x64"',
      '',
      'cd /tmp && rm -rf claude-code-extract && mkdir claude-code-extract',
      'unzip -q claude-code.vsix -d claude-code-extract',
      '',
      'EXT_DIR=$(python3 -c "import json; d=json.load(open(\'/tmp/claude-code-extract/extension/package.json\')); print(d[\'publisher\']+\'.\'+d[\'name\']+\'-\'+d[\'version\'])")',
      'rm -rf "$EXTENSIONS_DIR/$EXT_DIR"',
      'mv /tmp/claude-code-extract/extension "$EXTENSIONS_DIR/$EXT_DIR"',
      'rm -rf /tmp/claude-code.vsix /tmp/claude-code-extract',
    ].join('\n');

    const lcc = new sagemaker.CfnStudioLifecycleConfig(this, 'ClaudeCodeLCC', {
      studioLifecycleConfigName: 'install-claude-code-8',
      studioLifecycleConfigAppType: 'CodeEditor',
      studioLifecycleConfigContent: Buffer.from(lccScript).toString('base64'),
    });

    // --- SageMaker Domain ---

    const domain = new sagemaker.CfnDomain(this, 'Domain', {
      domainName: 'code-editor-domain',
      authMode: 'IAM',
      vpcId: vpc.vpcId,
      subnetIds: privateSubnets.map((s) => s.subnetId),
      appNetworkAccessType: config.prod ? 'VpcOnly' : 'PublicInternetOnly',
      defaultUserSettings: {
        executionRole: role.roleArn,
        studioWebPortalSettings: {
          hiddenAppTypes: ['JupyterLab', 'RStudioServerPro', 'Canvas'],
          hiddenMlTools: ['DataWrangler', 'FeatureStore', 'EmrClusters', 'AutoMl',
                          'Experiments', 'Training', 'ModelEvaluation', 'Pipelines',
                          'Models', 'JumpStart', 'InferenceRecommender', 'Endpoints',
                          'Projects', 'InferenceOptimization', 'HyperPodClusters'],
        },
        codeEditorAppSettings: {
          appLifecycleManagement: {
            idleSettings: {
              lifecycleManagement: 'ENABLED',
              idleTimeoutInMinutes: 60,
              minIdleTimeoutInMinutes: 60,
              maxIdleTimeoutInMinutes: 480,
            },
          },
          // No sageMakerImageArn needed — Code Editor only supports SageMaker
          // Distribution, so SageMaker always provisions the correct image.
          lifecycleConfigArns: [lcc.attrStudioLifecycleConfigArn],
          defaultResourceSpec: {
            instanceType: 'ml.t3.medium',
            lifecycleConfigArn: lcc.attrStudioLifecycleConfigArn,
          },
        },
      },
    });

    // --- User Profile ---

    const userProfile = new sagemaker.CfnUserProfile(this, 'UserProfile', {
      domainId: domain.attrDomainId,
      userProfileName: config.userName,
    });
    userProfile.addDependency(domain);

    // --- Outputs ---

    new cdk.CfnOutput(this, 'StudioUrl', {
      description: 'SageMaker Studio URL',
      value: `https://studio.${this.region}.sagemaker.aws/domain/${domain.attrDomainId}`,
    });

    new cdk.CfnOutput(this, 'DomainId', {
      description: 'SageMaker Domain ID',
      value: domain.attrDomainId,
    });

    // EFS is auto-created by SageMaker and NOT deleted by cdk destroy.
    // teardown.sh uses this ID to delete the filesystem after stack removal.
    new cdk.CfnOutput(this, 'EfsId', {
      description: 'Home EFS filesystem ID — must be manually deleted after cdk destroy',
      value: domain.attrHomeEfsFileSystemId,
    });

    new cdk.CfnOutput(this, 'ExecutionRoleArn', {
      description: 'SageMaker execution role ARN',
      value: role.roleArn,
    });
  }
}
