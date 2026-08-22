locals {
  name = "${var.project_name}-${var.environment}"

  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names,
    0,
    2
  )

  alb_dns_parameter = var.alb_dns_ssm_parameter != "" ? var.alb_dns_ssm_parameter : "/siase/${var.environment}/alb-dns"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = local.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.common_tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.2"

  name               = local.name
  kubernetes_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access = true

  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      subnet_ids = module.vpc.private_subnets
    }
  }

  access_entries = {}
  tags           = local.common_tags
}

data "aws_iam_policy_document" "load_balancer_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = "${local.name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.load_balancer_controller_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "load_balancer_controller" {
  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.load_balancer_controller.id
  policy = file("${path.module}/iam/aws-load-balancer-controller-policy.json")
}

data "aws_secretsmanager_secret_version" "grafana" {
  secret_id = var.grafana_secret_arn
}

resource "aws_ssm_parameter" "alb_dns" {
  name  = local.alb_dns_parameter
  type  = "String"
  value = "PENDING_ALB_DNS"
  tags  = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "kubernetes_namespace_v1" "siase" {
  metadata {
    name = "siase"
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_config_map_v1" "siase_dashboard" {
  metadata {
    name      = "siase-overview-dashboard"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "siase-overview.json" = file("${path.module}/dashboards/siase-overview.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  namespace        = "kube-system"
  create_namespace = true
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  version          = "3.12.2"
  wait             = true

  values = [file("${path.module}/helm/metrics-server-values.yaml")]
}

resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  namespace        = "kube-system"
  create_namespace = true
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.8.1"
  wait             = true

  values = [templatefile("${path.module}/helm/aws-load-balancer-controller-values.yaml", {
    cluster_name = module.eks.cluster_name
    region       = var.aws_region
    vpc_id       = module.vpc.vpc_id
    role_arn     = aws_iam_role.load_balancer_controller.arn
  })]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "61.7.2"
  wait             = true

  values = [templatefile("${path.module}/helm/kube-prometheus-stack-values.yaml", {
    grafana_admin_user     = var.grafana_admin_user
    grafana_admin_password = jsondecode(data.aws_secretsmanager_secret_version.grafana.secret_string)["password"]
  })]

  depends_on = [kubernetes_namespace_v1.monitoring]
}

resource "helm_release" "loki" {
  name             = "loki"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "6.6.2"
  wait             = true

  values     = [file("${path.module}/helm/loki-values.yaml")]
  depends_on = [kubernetes_namespace_v1.monitoring]
}

resource "helm_release" "alloy" {
  name             = "alloy"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "alloy"
  version          = "0.7.0"
  wait             = true

  values = [templatefile("${path.module}/helm/alloy-values.yaml", {
    loki_url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
  })]

  depends_on = [helm_release.loki]
}
