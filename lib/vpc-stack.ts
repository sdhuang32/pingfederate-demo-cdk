import * as cdk from 'aws-cdk-lib';
import { aws_ec2 as ec2 } from 'aws-cdk-lib';
const config = require('config');

export class VpcStack extends cdk.Stack {
    readonly awsRegion: undefined|string;
    vpc: ec2.IVpc;

  constructor(scope: cdk.App, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    this.vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 3,
      natGateways: 1,
      natGatewaySubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
        availabilityZones: ["ap-southeast-2b"]
      }
    });
  }
}