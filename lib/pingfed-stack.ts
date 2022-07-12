import * as cdk from 'aws-cdk-lib';
import { aws_s3 as s3 } from 'aws-cdk-lib';
import { aws_s3_assets as assets } from 'aws-cdk-lib';
import { aws_iam as iam } from 'aws-cdk-lib';
import { aws_autoscaling as autoscaling } from 'aws-cdk-lib';
import { aws_ec2 as ec2 } from 'aws-cdk-lib';
import { aws_elasticloadbalancingv2 as elbv2 } from 'aws-cdk-lib';
import * as path from 'path';
const config = require('config');

export interface PingFedStackProps extends cdk.StackProps {
  readonly vpc: ec2.IVpc;
  readonly rdsEndpoint: string;
  readonly sgRdsId: string;
}

export class PingFedStack extends cdk.Stack {
    readonly awsRegion: undefined|string;
    readonly vpc: ec2.IVpc;
    readonly rdsEndpoint: string;

  constructor(scope: cdk.App, id: string, props?: PingFedStackProps) {
    super(scope, id, props);

    this.awsRegion = props?.env?.region ?? "ap-southeast-2";
    this.vpc = props?.vpc!;
    this.rdsEndpoint = props?.rdsEndpoint!;

    const deployId = this.stackName;
    
    const pingAmi = ec2.MachineImage.latestAmazonLinux({
      generation: ec2.AmazonLinuxGeneration.AMAZON_LINUX_2
    });

    const runtimeBucket = new s3.Bucket(this, "runtimeBucket", {
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true
    });

    const privateSubnets = this.vpc.privateSubnets; 
    const publicSubnets = this.vpc.publicSubnets; 

    const commonPingFederateApplicationPolicy = new iam.ManagedPolicy(this, "commonPingFederateApplicationPolicy", {
      managedPolicyName: "commonPingFederateApplicationPolicy" + this.stackName,
      statements: [
        new iam.PolicyStatement({
          resources: ["*"],
          actions: [
            "ec2:Describe*",
            "ec2:CreateTags",
            "ec2:DeleteTags",
            "cloudwatch:ListMetrics",
            "cloudwatch:GetMetricStatistics",
            "cloudwatch:Describe*",
            "cloudwatch:PutMetricData",
            "ec2:DescribeVolumes",
            "ec2:DescribeTags",
            "logs:PutLogEvents",
            "logs:DescribeLogStreams",
            "logs:DescribeLogGroups",
            "logs:CreateLogStream",
            "logs:CreateLogGroup",
            "ssm:PutParameter",
            "ssm:DescribeAssociation",
            "ssm:GetDeployablePatchSnapshotForInstance",
            "ssm:GetDocument",
            "ssm:GetParameters",
            "ssm:GetParameter",
            "ssm:ListAssociations",
            "ssm:ListInstanceAssociations",
            "ssm:PutInventory",
            "ssm:UpdateAssociationStatus",
            "ssm:UpdateInstanceAssociationStatus",
            "ssm:UpdateInstanceInformation",
            "ssm:SendCommand",
            "ssm:ListCommandInvocations",
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:ListSecrets",
            "ec2messages:AcknowledgeMessage",
            "ec2messages:DeleteMessage",
            "ec2messages:FailMessage",
            "ec2messages:GetEndpoint",
            "ec2messages:GetMessages",
            "ec2messages:SendReply",
            "route53:List*",
            "route53:Get*",
            "route53:ChangeResourceRecordSets",
            "elasticloadbalancing:Describe*",
            "autoscaling:Describe*",
            "autoscaling:CompleteLifecycleAction",
            "s3:ListBucket",
            "s3:GetObject",
            "s3:PutObject",
          ]
        }),
        new iam.PolicyStatement({
          resources: ["arn:aws:kms:ap-southeast-2:" + this.account + ":key/*"],
          actions: [
            "kms:Decrypt",
            "kms:DescribeKey",
            "kms:Encrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:CreateGrant",
            "kms:GetKeyPolicy",
            "kms:GetKeyRotationStatus",
            "kms:ListKeys",
            "kms:ListAliases",
            "kms:ListKeyPolicies"
          ]
        })
      ]
    });

    var sgAdmin = new ec2.SecurityGroup(this, "sgAdmin", {
        vpc: this.vpc
    })
    var sgEngine = new ec2.SecurityGroup(this, "sgEngine", {
        vpc: this.vpc
    })
    sgAdmin.addIngressRule(sgEngine, ec2.Port.tcp(7600));
    sgAdmin.addIngressRule(sgEngine, ec2.Port.tcp(7700));
    sgAdmin.addIngressRule(ec2.Peer.ipv4(this.vpc.vpcCidrBlock), ec2.Port.tcp(9999));
    sgEngine.addIngressRule(sgAdmin, ec2.Port.tcp(7600));
    sgEngine.addIngressRule(sgAdmin, ec2.Port.tcp(7700));
    let sgRds = ec2.SecurityGroup.fromSecurityGroupId(this, "sgRds", props?.sgRdsId!);
    sgRds.addIngressRule(sgAdmin, ec2.Port.tcp(5432));
    sgRds.addIngressRule(sgEngine, ec2.Port.tcp(5432));

    const asgAdmin = this.createAsgForPingFed('admin', pingAmi, privateSubnets, sgAdmin, 1, 1,
      runtimeBucket, deployId, commonPingFederateApplicationPolicy);
    const asgEngine = this.createAsgForPingFed('engine', pingAmi, privateSubnets, sgEngine, 3, 3,
      runtimeBucket, deployId, commonPingFederateApplicationPolicy);
    //const albAdmin = this.createALBAndAttachAsg('admin', [9999], publicSubnets, asgAdmin);
    const nlbAdmin = this.createNLBAndAttachAdminAsg('admin', [9999], publicSubnets, asgAdmin);
    const albEngine = this.createALBAndAttachEngineAsg('engine', [9031], publicSubnets, asgEngine);

    new cdk.CfnOutput(this, 'PingFedAdminEndpointOutput', {
      value: nlbAdmin.loadBalancerDnsName,
      description: "The access endpoint to PingFed admin",
      exportName: "PingFedAdminEndpoint-" + this.stackName
    });
    new cdk.CfnOutput(this, 'PingFedEngineEndpointOutput', {
      value: albEngine.loadBalancerDnsName,
      description: "The access endpoint to PingFed engines",
      exportName: "PingFedEngineEndpoint-" + this.stackName
    });
  }

  createAsgForPingFed(name: string, ami: ec2.IMachineImage, subnets: ec2.ISubnet [], sg: ec2.ISecurityGroup,
      minCapacity: number, maxCapacity: number, runtimeBucket: s3.IBucket, deployId: string,
      managedPolicy: iam.ManagedPolicy): autoscaling.AutoScalingGroup {

    sg.addIngressRule(sg, ec2.Port.tcp(7600));
    sg.addIngressRule(sg, ec2.Port.tcp(7700));

    /*
    if (name == 'admin') {
    } else if (name == 'engine') {
    }
    */
    
    const asg = new autoscaling.AutoScalingGroup(this, 'asg-' + name, {
      vpc: this.vpc,
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.C5, ec2.InstanceSize.LARGE),
      machineImage: ami,
      minCapacity: minCapacity,
      maxCapacity: maxCapacity,
      healthCheck: autoscaling.HealthCheck.elb({grace: cdk.Duration.seconds(30)}),
      securityGroup: sg,
      vpcSubnets: {
        subnets: subnets,
      },
    });

    /* START: For SSM Session Manager */
    asg.role.addManagedPolicy(iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"));
    asg.role.addToPrincipalPolicy(new iam.PolicyStatement({
      resources: ["*"],
      actions: ["s3:GetEncryptionConfiguration"]
    }));
    /* END: For SSM Session Manager */

    asg.role.addManagedPolicy(managedPolicy);

    cdk.Tags.of(asg).add('PFClusterID','PFC-' + deployId);

    asg.addUserData(
      "set -euxo pipefail",
    );

    /* Use when your AMI doesn't have built-in SSM agent
    asg.addUserData(
      "sudo yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm",
      "sudo systemctl enable amazon-ssm-agent",
      "sudo systemctl start amazon-ssm-agent"
    );
    */

    const assetPingfedConf = new assets.Asset(this, "assetPingfedConf-" + name, {
      path: path.join(__dirname, "pingfed-assets/pingfed-configs"),
    });
    const assetLocalPathPingfedConfig = asg.userData.addS3DownloadCommand({
      bucket: assetPingfedConf.bucket,
      bucketKey: assetPingfedConf.s3ObjectKey,
      localFile: '/data/' + assetPingfedConf.s3ObjectKey
    });

    const assetUserdata = new assets.Asset(this, "assetUserdata-" + name, {
        path: path.join(__dirname, "pingfed-assets/ec2-userdata"),
    });
    const assetLocalPathUserdata = asg.userData.addS3DownloadCommand({
      bucket: assetUserdata.bucket,
      bucketKey: assetUserdata.s3ObjectKey,
      localFile: '/data/' + assetUserdata.s3ObjectKey
    });

    asg.addUserData(
      "unzip " + assetLocalPathUserdata + " -d /data/"
    );
    
    asg.userData.addExecuteFileCommand({
      filePath: "/data/entrypoint.sh",
      arguments: runtimeBucket.bucketName + " " + assetLocalPathPingfedConfig + " "
        + name + " " + this.awsRegion + " " + deployId + " "
        + this.rdsEndpoint + ' > /var/log/pingfed-init.log 2>&1',
    });

    // In order to let lifecycle hooks take effect during ASG initial creation,
    // we have to manually add the "LifecycleHookSpecificationList" property
    // inside the ASG CloudFormation definition for now.
    // https://github.com/aws/aws-cdk/issues/16356
    const cfnasg = asg.node.defaultChild as autoscaling.CfnAutoScalingGroup;
    cfnasg.lifecycleHookSpecificationList = [
      {
        lifecycleHookName: "service-init-hook",
        lifecycleTransition: "autoscaling:EC2_INSTANCE_LAUNCHING",
        heartbeatTimeout: 600
      }
    ];

    return asg;
  }

  createALBAndAttachEngineAsg(name: string, port: number [], subnets: ec2.ISubnet [],
      asg: autoscaling.AutoScalingGroup): elbv2.ApplicationLoadBalancer {

    const alb = new elbv2.ApplicationLoadBalancer(this, "alb-" + name, {
      vpc: this.vpc,
      internetFacing: true,
      vpcSubnets: {
        subnets: subnets,
      },
    });
    
    for (let val of port) {
      const listener = alb.addListener("listener-" + val + name, {
        port: val,
        protocol: elbv2.ApplicationProtocol.HTTP
      });

      listener.addTargets("target", {
        port: val,
        protocol: elbv2.ApplicationProtocol.HTTPS,
        targets: [ asg ],
        healthCheck: {
          path: "/pf/heartbeat.ping",
          timeout: cdk.Duration.seconds(10),
          interval: cdk.Duration.seconds(15),
          healthyThresholdCount: 2,
          unhealthyThresholdCount: 2
        }
      });

      listener.connections.allowTo(asg, ec2.Port.tcp(val));
    }

    return alb;
  }

  createNLBAndAttachAdminAsg(name: string, port: number [], subnets: ec2.ISubnet [],
      asg: autoscaling.AutoScalingGroup): elbv2.NetworkLoadBalancer {

    const nlb = new elbv2.NetworkLoadBalancer(this, "nlb-" + name, {
      vpc: this.vpc,
      internetFacing: true,
      crossZoneEnabled: true,
      vpcSubnets: {
        subnets: subnets,
      },
    });
    
    for (let val of port) {
      const listener = nlb.addListener("listener-" + val + name, {
        port: 443,
        protocol: elbv2.Protocol.TCP
      });

      listener.addTargets("target", {
        port: val,
        protocol: elbv2.Protocol.TCP,
        preserveClientIp: false,
        targets: [ asg ],
      });
    }

    return nlb;
  }
}