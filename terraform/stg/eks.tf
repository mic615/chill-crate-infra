module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0"

  name               = var.cluster_name
  kubernetes_version = "1.33"

  endpoint_public_access = true

  # Without this the cluster comes up with no Kubernetes RBAC for the principal
  # that created it -- you get a cluster you cannot kubectl into.
  enable_cluster_creator_admin_permissions = true

  addons = {
    # before_compute matters here. The module creates addons AFTER node groups
    # by default, which deadlocks: nodes register, then sit NotReady waiting
    # for a CNI that Terraform will not install until the nodes are Ready.
    # The node group times out with "NodeCreationFailure: Unhealthy nodes".
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }

    kube-proxy = {
      most_recent    = true
      before_compute = true
    }

    # CoreDNS is a Deployment and needs somewhere to schedule, so it has to
    # come after the nodes exist.
    coredns = { most_recent = true }

    # EKS has no local-path provisioner, so without this every PVC carried
    # over from the homelab sits Pending forever. Pairs with
    # storage/storageclass-gp3.yaml.
    aws-ebs-csi-driver = { most_recent = true }

    # Runs the agent that swaps a pod's token for IAM role credentials.
    # Required for the EBS CSI association below to do anything.
    eks-pod-identity-agent = { most_recent = true }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    amc-cluster-wg = {
      ami_type = "AL2023_x86_64_STANDARD"

      # Deliberately NOT attaching the cluster primary security group. With it
      # on, nodes carry two security groups both tagged
      # kubernetes.io/cluster/<name>, and the in-tree AWS cloud controller
      # refuses to provision an NLB for a LoadBalancer Service:
      #
      #   Multiple tagged security groups found for instance i-...;
      #   ensure only the k8s security group is tagged
      #
      # The module's own node security group already carries the rules nodes
      # need to reach the control plane, so the primary group is redundant.
      attach_cluster_primary_security_group = false

      min_size     = 2
      max_size     = 4
      desired_size = 2

      # t3.medium is 4 GiB (~3.3 GiB allocatable) -- Keycloak alone requests
      # 1700Mi and limits at 2Gi. Multiple types give the spot allocator
      # somewhere to fall back to when one pool is dry.
      instance_types = ["t3.large", "t3a.large", "m5.large", "m6i.large"]
      capacity_type  = "SPOT"

      labels = {
        # Carried over from the homelab, where one big node held the heavy
        # workloads. Keycloak's nodeAffinity, the ArgoCD nodeSelector patch and
        # monitoring-values.yaml all still require it. Applied to every node
        # so those manifests schedule unchanged -- drop the label and the
        # selectors together whenever you feel like it.
        workload = "heavy"
      }
    }
  }

  tags = {
    Project = "chill-crate"
  }
}

# ---------------------------------------------------------------------------
# Pod Identity for the EBS CSI driver
#
# The addon above installs the driver, but it needs IAM permission to actually
# create volumes. Pod Identity rather than IRSA: the trust policy is static, so
# it survives the cluster being destroyed and rebuilt under the same name.
#
# Terraform cannot order these against an addon nested inside the module, so on
# a first apply the CSI controller may crashloop for a minute until the
# association lands. It recovers on its own.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}
