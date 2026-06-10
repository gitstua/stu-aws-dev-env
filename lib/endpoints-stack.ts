import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';
import { Config } from './config';
import { VpcStack } from './vpc-stack';

// Deployed only when natMode=endpoints (prod VpcOnly mode).
// Provides private connectivity to AWS services without a NAT Gateway.
export class EndpointsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, vpcStack: VpcStack, config: Config, props?: cdk.StackProps) {
    super(scope, id, props);

    const { vpc } = vpcStack;

    const sg = new ec2.SecurityGroup(this, 'EndpointSg', {
      vpc,
      description: 'HTTPS ingress from VPC CIDR for VPC interface endpoints',
    });
    sg.addIngressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.tcp(443));

    const subnets = vpc.selectSubnets({ subnetGroupName: 'Private' });

    const interfaceEndpoints: Array<[string, ec2.InterfaceVpcEndpointAwsService]> = [
      ['SageMakerApi',     ec2.InterfaceVpcEndpointAwsService.SAGEMAKER_API],
      ['SageMakerRuntime', ec2.InterfaceVpcEndpointAwsService.SAGEMAKER_RUNTIME],
      ['Sts',              ec2.InterfaceVpcEndpointAwsService.STS],
      ['EcrApi',           ec2.InterfaceVpcEndpointAwsService.ECR],
      ['EcrDocker',        ec2.InterfaceVpcEndpointAwsService.ECR_DOCKER],
    ];

    for (const [name, service] of interfaceEndpoints) {
      new ec2.InterfaceVpcEndpoint(this, `Ep${name}`, {
        vpc,
        service,
        subnets,
        securityGroups: [sg],
        privateDnsEnabled: true,
      });
    }

    // S3 gateway endpoint is free and routes S3 traffic inside the VPC.
    new ec2.GatewayVpcEndpoint(this, 'EpS3', {
      vpc,
      service: ec2.GatewayVpcEndpointAwsService.S3,
    });

    void config; // consumed only for future per-region endpoint name overrides
  }
}
