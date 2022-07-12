import * as cdk from 'aws-cdk-lib';
import { aws_ec2 as ec2 } from 'aws-cdk-lib';
import { aws_kms as kms } from 'aws-cdk-lib';
import { aws_rds as rds } from 'aws-cdk-lib';
//import { aws_secretsmanager as secrets } from 'aws-cdk-lib'; //import when you need actual RDS credentials
const config = require('config');

export interface RdsProps extends cdk.StackProps {
  readonly vpc: ec2.IVpc;
}

export class RdsStack extends cdk.Stack {
    readonly awsRegion: undefined|string;
    vpc: ec2.IVpc;
    rdsEndpoint: string;
    sgRdsId: string;

  constructor(scope: cdk.App, id: string, props?: RdsProps) {
    super(scope, id, props);

    this.awsRegion = props?.env?.region ?? "ap-southeast-2";
    this.vpc = props?.vpc!;

    const rdsSubnetGroup = new rds.SubnetGroup(this, 'rdsSubnetGroup', {
      description: 'rdsSubnetGroup',
      vpc: this.vpc,
      vpcSubnets: {
        subnets: this.vpc.privateSubnets
      }
    });

    var sgRds = new ec2.SecurityGroup(this, "sgRds", {
      vpc: this.vpc
    });
    let sgsForRds: Array<ec2.ISecurityGroup> = [];
    sgsForRds.push(sgRds);

    const rdsKey = new kms.Key(this, "rdsKey");

    const instanceSize = (process.env.NODE_ENV == 'staging' || process.env.NODE_ENV == 'prod')? ec2.InstanceSize.XLARGE : ec2.InstanceSize.LARGE;
    const cluster = new rds.DatabaseCluster(this, 'Database', {
      engine: rds.DatabaseClusterEngine.auroraPostgres({ version: rds.AuroraPostgresEngineVersion.VER_10_16 }),
      instanceProps: {
        vpc: this.vpc,
        securityGroups: sgsForRds,
        instanceType: ec2.InstanceType.of(ec2.InstanceClass.R5, instanceSize)
      },
      subnetGroup: rdsSubnetGroup,
      defaultDatabaseName: 'pingfed',
      instances: 3,
      monitoringInterval: cdk.Duration.seconds(60),
      cloudwatchLogsExports: ['postgresql'],
      storageEncryptionKey: rdsKey,
      removalPolicy: cdk.RemovalPolicy.DESTROY, // Demo purposes
      credentials: {
        username: "postgres",
        password: cdk.SecretValue.unsafePlainText("rdspassword") // Demo purposes. See the following comments.
      }
      /* Use something similar to the following when developing in your actual environments.
      const rdsCredential = secrets.Secret.fromSecretNameV2(this, "rdsCredential", "/credentials/rds");
      const username = rdsCredential.secretValueFromJson('username').toString();
      const password = rdsCredential.secretValueFromJson('password');
      */
    });

    this.rdsEndpoint = cluster.clusterEndpoint.hostname;
    this.sgRdsId = sgRds.securityGroupId;

    new cdk.CfnOutput(this, 'RdsEndpointOutput', {
      value: cluster.clusterEndpoint.hostname,
      description: "The read/write endpoint to the RDS cluster",
      exportName: "RdsEndpoint-" + this.stackName
    });
  }
}