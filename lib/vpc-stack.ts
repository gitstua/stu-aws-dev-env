import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';
import { Config } from './config';

export class VpcStack extends cdk.Stack {
  public readonly vpc: ec2.Vpc;
  // Private subnets — PRIVATE_WITH_EGRESS in nat mode, PRIVATE_ISOLATED in endpoints mode.
  public readonly privateSubnets: ec2.ISubnet[];

  constructor(scope: Construct, id: string, config: Config, props?: cdk.StackProps) {
    super(scope, id, props);

    const useNat = config.natMode === 'nat';

    this.vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: useNat ? 1 : 0,
      subnetConfiguration: [
        {
          name: 'Private',
          subnetType: useNat
            ? ec2.SubnetType.PRIVATE_WITH_EGRESS
            : ec2.SubnetType.PRIVATE_ISOLATED,
          cidrMask: 24,
        },
        {
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
      ],
    });

    this.privateSubnets = useNat ? this.vpc.privateSubnets : this.vpc.isolatedSubnets;

    new cdk.CfnOutput(this, 'VpcId', { value: this.vpc.vpcId });
  }
}
