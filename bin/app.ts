import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { resolveConfig } from '../lib/config';
import { VpcStack } from '../lib/vpc-stack';
import { EndpointsStack } from '../lib/endpoints-stack';
import { StudioStack } from '../lib/studio-stack';

const app = new cdk.App();
const config = resolveConfig(app);

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: config.region,
};

const vpcStack = new VpcStack(app, 'VpcStack', config, { env });

let endpointsStack: EndpointsStack | undefined;
if (config.natMode === 'endpoints') {
  endpointsStack = new EndpointsStack(app, 'EndpointsStack', vpcStack, config, { env });
  endpointsStack.addDependency(vpcStack);
}

const studioStack = new StudioStack(app, 'StudioStack', vpcStack, config, { env });
studioStack.addDependency(vpcStack);
if (endpointsStack) {
  studioStack.addDependency(endpointsStack);
}
