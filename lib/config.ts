import * as cdk from 'aws-cdk-lib';

export interface Config {
  prod: boolean;
  natMode: 'nat' | 'endpoints';
  userName: string;
  region: string;
}

export function resolveConfig(app: cdk.App): Config {
  const prod = app.node.tryGetContext('prod') === 'true';
  const rawNatMode = app.node.tryGetContext('natMode') ?? 'nat';
  const natMode: 'nat' | 'endpoints' = rawNatMode === 'endpoints' ? 'endpoints' : 'nat';

  return {
    prod,
    natMode,
    userName: app.node.tryGetContext('userName') ?? 'dev',
    region: app.node.tryGetContext('region') ?? 'ap-southeast-2',
  };
}
