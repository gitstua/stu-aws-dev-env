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

    // --- SageMaker Domain ---

    const domain = new sagemaker.CfnDomain(this, 'Domain', {
      domainName: 'code-editor-domain',
      authMode: 'IAM',
      vpcId: vpc.vpcId,
      subnetIds: privateSubnets.map((s) => s.subnetId),
      appNetworkAccessType: config.prod ? 'VpcOnly' : 'PublicInternetOnly',
      defaultUserSettings: {
        executionRole: role.roleArn,
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
          defaultResourceSpec: {
            instanceType: 'ml.t3.medium',
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
