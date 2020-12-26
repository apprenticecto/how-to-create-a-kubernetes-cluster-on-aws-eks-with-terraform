# How To Create a Kubernetes Cluster on AWS EKS with Terraform

![GitHub license](https://img.shields.io/badge/license-MIT-informational)
![GitHub version](https://img.shields.io/badge/terraform-v0.13.5-success)
![GitHub version](https://img.shields.io/badge/EKS%20cluster-v1.18-success)
![GitHub version](https://img.shields.io/badge/local__machine__OS-OSX-blue)

This repo builds a management VPC in which a [kubernetes](https://kubernetes.io/) cluster is set-up using [AWS EKS](https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html).

**Please consider that AWS will [charge you](https://aws.amazon.com/eks/pricing/) for your EKS cluster, regardless of your eligibility for the [free-tier program](https://aws.amazon.com/free/).** 

## AWS CLI and Terraform Set-Up

Check my [repo](https://github.com/apprenticecto/create-aws-ec2-with-terraform), which illustrates how to set-up [Terraform](https://www.terraform.io/) and [AWS CLI](https://aws.amazon.com/cli/) in order to provision infrastructure on AWS using Terraform.

## IAM Set-Up

This repo leverages the code in my [how-to-create-aws-iam-user-group-assumable-role-with-terraform repo](https://github.com/apprenticecto/how-to-create-aws-iam-user-group-assumable-role-with-terraform) to create AWS IAM entities.

Here, we'll add a new user (`iam_user_eks_reader`) in a group (`admins`);  this user will be able to assume a [cluster read only](https://docs.aws.amazon.com/eks/latest/userguide/security_iam_id-based-policy-examples.html#policy_example3) role (`eks_cluster_read`) within the same AWS account.

The role is added to the aws-auth configmap by the Terraform eks module, as described [here](https://docs.aws.amazon.com/eks/latest/userguide/add-user-role.html). 

## EKS Cluster Networking Drill-Down

See [here](https://docs.aws.amazon.com/eks/latest/userguide/eks-networking.html) for a general introduction. 

### VPC
The cluster is built within the `mgmt_vpc`, created through the [VPC Terraform module](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest). Check my [repo](https://github.com/apprenticecto/how-to-create-your-aws-vpcs-pillars-with-terraform) to deep-dive into it.

Our cluster is placed in `eu-central` region, using its availbility zones and has public (`10.20.101.0/24`, `10.20.102.0/24`, `10.20.103.0/24`) and private (`10.20.1.0/24`, `10.20.2.0/24`, `10.20.3.0/24`) subnets.

### Nodes

Nodes are placed in the private subnets; worker groups with more than one node are associated with different availability zones, starting from `eu-central-1a`.

Multiple and secondary ip addresses to nodes are managed by [Amazon VPC Container Network Interface (CNI) plugin for Kubernetes](https://docs.aws.amazon.com/eks/latest/userguide/pod-networking.html), which is [opensource](https://github.com/aws/amazon-vpc-cni-k8s).

IP addresses are provisioned by the [L-IPAM daemon](https://docs.aws.amazon.com/eks/latest/userguide/pod-networking.html), with defaults indicated [here](https://docs.aws.amazon.com/eks/latest/userguide/cni-env-vars.html). The number of IP addresses for each network interface varies by [instance type](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-eni.html#AvailableIpPerENI). 

### NAT Access
Each private subnet can reach the internet through the [NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html), which has an associated [elastic IP address](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html).

### Internet Access
Public subnets can reach the internet through an [internet gateway](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html).

### Security Groups
[Security groups](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_SecurityGroups.html) are added by the Terraform EKS module for each node, to allow communication between nodes and the EKS control plane by the EKS module.

Additional security groups are added to allow port 22 traffic.

## Build Our Kubernetes Cluster

Launch:

-  `terraform init`
-  `terraform plan`
-  `terraform apply`, entering ´yes´ when required or using the `-auto-approve` option.

## Configure kubectl

We now need to configure [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/) and [AWS IAM Authenticator](https://docs.aws.amazon.com/eks/latest/userguide/install-aws-iam-authenticator.html).

The following command will get the access credentials for your cluster and automatically configure kubectl:

```
$ aws eks --region $(terraform output region) update-kubeconfig --name $(terraform output cluster_name)
```

The [Kubernetes cluster name](https://github.com/hashicorp/learn-terraform-eks/blob/master/outputs.tf#L26) and [region](https://github.com/hashicorp/learn-terraform-eks/blob/master/outputs.tf#L21)  are directly taken from the output variables showed after the successful Terraform run.

If you wish, you can view these outputs again by running:

```
$ terraform output
```

## Deploy and access Kubernetes Dashboard

To verify that our cluster is configured correctly and running, we'll install a Kubernetes dashboard and navigate to it in our local browser. 

### Deploy Kubernetes Metrics Server

The Kubernetes Metrics Server, used to gether metrics such as cluster CPU and memory usage over time, is not deployed by default in EKS clusters.

Download and unzip the metrics server by running the following command:

```
$ wget -O v0.3.6.tar.gz https://codeload.github.com/kubernetes-sigs/metrics-server/tar.gz/v0.3.6 && tar -xzf v0.3.6.tar.gz
```

Deploy the metrics server to the cluster by running the following command:

```
$ kubectl apply -f metrics-server-0.3.6/deploy/1.8+/
```

Verify that the metrics server has been deployed. If successful, you should see something like this:

```
$ kubectl get deployment metrics-server -n kube-system
NAME             READY   UP-TO-DATE   AVAILABLE   AGE
metrics-server   1/1     1            1           4s
```

### Deploy Kubernetes Dashboard

The following command will schedule the resources necessary for the dashboard:

```
$ kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta8/aio/deploy/recommended.yaml
```

Now, create a proxy server that will allow you to navigate to the dashboard 
from the browser on your local machine. This will continue running until you stop the process by pressing `CTRL + C`:

```
$ kubectl proxy
```

You should be able to access the Kubernetes dashboard by entering the following URL in your browser:

```
http://127.0.0.1:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
```

## Authenticate the dashboard

Generate the token in another terminal (do not close the `kubectl proxy` process):

```
$ kubectl -n kube-system describe secret $(kubectl -n kube-system get secret | grep service-controller-token | awk '{print $1}')
```

Select "Token" on the Dashboard UI then copy and paste the entire token you 
get in the terminal into the [dashboard authentication screen](http://127.0.0.1:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/).

You are now signed in to the dashboard for your Kubernetes cluster.

You can read more in the [Kubernetes documentation](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/#accessing-the-dashboard-ui).

## Sign-in With Our Added User

Login with the `iam_user_eks_reader` user to the console and select `switch role` from your account menu. 

You'll need to enter the following information:

- your account ID
- name of the role you want to assume with this user (´eks_cluster_mgmt´)
- a color to highlight your role.
 
After completion, you should be able to access your cluster from your console, by selecting the EKS service. 

## Destroy Your Cluster

Don't forget to destroy your infrastructure, by launching: `terraform destroy` and entering `yes` when required or using the `-auto-approve` option.

## Documentation

- [Terraform tutorial](https://github.com/hashicorp/learn-terraform-provision-eks-cluster), from which most of the code in this repo is based
- [This example](https://github.com/terraform-aws-modules/terraform-aws-eks/tree/master/examples/basic)
- [My repo on creating VPCs](https://github.com/apprenticecto/how-to-create-your-aws-vpcs-pillars-with-terraform)
- [De-mystifying cluster networking for Amazon EKS worker nodes](https://aws.amazon.com/blogs/containers/de-mystifying-cluster-networking-for-amazon-eks-worker-nodes/)
- [Terraform AWS Documentation](https://learn.hashicorp.com/collections/terraform/aws-get-started)
- [AWS Documentation](https://docs.aws.amazon.com/).

## Authors

This repository is maintained by [ApprenticeCTO](https://github.com/apprenticecto).

## License

MIT Licensed. See LICENSE for full details.


