terraform {
  required_version = ">= 0.13"
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  version = ">= 3.0"
  region  = "eu-central-1"
}


# IAM user, login profile and access key
module "iam_user_login_access_key" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-user"
  version = "3.4.0"

  name          = "iam_user_eks_reader"
  force_destroy = true

  create_iam_user_login_profile = true

  pgp_key = "keybase:apprenticecto"

  password_reset_required = false

  # SSH public key
  upload_iam_user_ssh_key = false

  ssh_public_key = ""
}

# IAM assumable role with custom policies
module "iam_assumable_role_custom" {
  source = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"

  trusted_role_arns = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${module.iam_user_login_access_key.this_iam_user_name}",
  ]

  create_role = true

  role_name         = "eks_cluster_read"
  role_requires_mfa = false

  custom_role_policy_arns = [
    module.iam_policy.arn
  ]
}

# IAM policy
module "iam_policy" {
  source = "terraform-aws-modules/iam/aws//modules/iam-policy"

  name        = "eks_read"
  path        = "/"
  description = "eks_read"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "eks:DescribeNodegroup",
        "eks:ListNodegroups",
        "eks:DescribeCluster",
        "eks:ListClusters",
        "eks:AccessKubernetesApi",
        "ssm:GetParameter",
        "eks:ListUpdates",
        "eks:ListFargateProfiles",
        "eks:ListAddons",
        "eks:DescribeAddonVersions",
        "eks:AccessKubernetesApi",
        "eks:DescribeCluster",
        "eks:ListClusters" 
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

# IAM group where IAM user is allowed to assume admin role in current AWS account
data "aws_caller_identity" "current" {}

module "iam_group_complete" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-group-with-assumable-roles-policy"
  version = "3.4.0"

  name = "admins"

  assumable_roles = [
     "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/eks_cluster_read", 
  #   "arn:aws:iam::data.aws_caller_identity.current.account_id:role/AWSServiceRoleForAmazonEKS",
  ]
 

  group_users = [
    module.iam_user_login_access_key.this_iam_user_name,
  ]
}


# Extending policies of IAM group admins
module "iam_group_complete_with_custom_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-group-with-policies"
  version = "3.4.0"

  name = module.iam_group_complete.group_name

  create_group = false

  custom_group_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
  ]
}

# Retrieves availability zones fro the region
data "aws_availability_zones" "available" {}

# sets the cluster name, using a random suffix
locals {
  cluster_name = "mgmt-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

# creates the vpc for the cluster
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 2.64.0"

  name = var.vpc_name
  cidr = var.vpc_cidr

  azs             = data.aws_availability_zones.available.names
  private_subnets = var.vpc_private_subnets
  public_subnets  = var.vpc_public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

# K8s specific taggin added -see https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html#vpc-tagging
  tags = {
    Terraform   = "true"
    Environment = "mgmt"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

# Retrieves information about an EKS Cluster.
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

# adds specific security group for worker-1
resource "aws_security_group" "worker_group_mgmt_one" {
  name_prefix = "worker_group_mgmt_one"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
    ]
    }
  }

# adds specific security group for worker-2
resource "aws_security_group" "worker_group_mgmt_two" {
  name_prefix = "worker_group_mgmt_two"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "192.168.0.0/16",
    ]
  }
}

# adds specific security group for all workers
resource "aws_security_group" "all_worker_mgmt" {
  name_prefix = "all_worker_management"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
      "172.16.0.0/12",
      "192.168.0.0/16",
    ]
  }
}

module "eks" {
  version = "13.2.1"
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = local.cluster_name
  cluster_version = "1.18"
  subnets         = module.vpc.private_subnets

  tags = var.eks_tags
  vpc_id = module.vpc.vpc_id

  worker_groups = [
    {
      name                          = "worker-group-1"
      instance_type                 = "t2.micro"
      additional_userdata           = "echo foo bar"
      asg_desired_capacity          = 2
      additional_security_group_ids = [aws_security_group.worker_group_mgmt_one.id]
    },
    {
      name                          = "worker-group-2"
      instance_type                 = "t2.micro"
      additional_userdata           = "echo foo bar"
      additional_security_group_ids = [aws_security_group.worker_group_mgmt_two.id]
      asg_desired_capacity          = 1
    },
  ]
  
# additional security group ids to attach to worker instances
  worker_additional_security_group_ids = [aws_security_group.all_worker_mgmt.id]

# Additional IAM roles to add to the aws-auth configmap
  map_roles = [
    {
    rolearn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/eks_cluster_mgmt"
    username = "eks_cluster_mgmt"
    groups   = ["system:masters"]
    },
  ]
 
# Additional IAM users to add to the aws-auth configmap
  map_users                            = [
    {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/iam_user_top_admin"
      username = "iam_user_top_admin"
      groups   = ["system:masters"]
    },
  ]
}

# Gets an authentication token to communicate with an EKS cluster.
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

# Enables interaction with the resources supported by Kubernetes.
provider "kubernetes" {
  version = "~> 1.13" 
  load_config_file       = "false"
  host                   = data.aws_eks_cluster.cluster.endpoint
  token                  = data.aws_eks_cluster_auth.cluster.token
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
}



