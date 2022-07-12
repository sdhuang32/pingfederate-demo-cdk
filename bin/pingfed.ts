#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { VpcStack } from '../lib/vpc-stack';
import { RdsStack } from '../lib/rds-stack';
import { PingFedStack } from '../lib/pingfed-stack';

const config = require('config');
const app = new cdk.App();

const stackName = app.node.tryGetContext('stackName') ?? "PingFedStack";
const vpcStack = new VpcStack(app, stackName + '-vpc', {
  env: {
    account: config.get('aws').account || process.env.CDK_DEFAULT_ACCOUNT,
    region: config.get('aws').region || process.env.CDK_DEFAULT_REGION
  }
});

const rdsStack = new RdsStack(app, stackName + '-rds', {
  env: {
    account: config.get('aws').account || process.env.CDK_DEFAULT_ACCOUNT,
    region: config.get('aws').region || process.env.CDK_DEFAULT_REGION
  },
  vpc: vpcStack.vpc,
});

new PingFedStack(app, stackName, {
  env: {
    account: config.get('aws').account || process.env.CDK_DEFAULT_ACCOUNT,
    region: config.get('aws').region || process.env.CDK_DEFAULT_REGION
  },
  vpc: vpcStack.vpc,
  rdsEndpoint: rdsStack.rdsEndpoint,
  sgRdsId: rdsStack.sgRdsId
});