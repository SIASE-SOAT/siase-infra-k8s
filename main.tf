locals {
  name = "${var.project_name}-${var.environment}"

  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names,
    0,
    2
  )

  lb_dns_parameter = var.lb_dns_ssm_parameter != "" ? var.lb_dns_ssm_parameter : "/siase/production/lb-dns"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  })

  grafana_service_values = yamlencode({
    grafana = {
      service = merge(
        { type = var.grafana_service_type },
        var.grafana_service_type == "LoadBalancer" ? {
          loadBalancerSourceRanges = var.grafana_allowed_cidrs
        } : {}
      )
    }
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

  enable_nat_gateway      = false
  map_public_ip_on_launch = true

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

resource "aws_eks_cluster" "this" {
  name     = local.name
  version  = var.cluster_version
  role_arn = var.lab_role_arn

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = module.vpc.public_subnets
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  tags = local.common_tags
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = var.lab_role_arn
  subnet_ids      = module.vpc.public_subnets

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = var.node_instance_types

  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = local.common_tags
}

data "aws_secretsmanager_secret_version" "grafana" {
  secret_id = var.grafana_secret_arn
}

resource "aws_ssm_parameter" "lb_dns" {
  name  = local.lb_dns_parameter
  type  = "String"
  value = "PENDING_LB_DNS"
  tags  = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_security_group" "secretsmanager_endpoint" {
  name        = "${local.name}-secretsmanager-endpoint"
  description = "Permite HTTPS da VPC ao endpoint privado do Secrets Manager"
  vpc_id      = module.vpc.vpc_id
  tags        = local.common_tags

  ingress {
    description = "Secrets Manager a partir da VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Saida necessaria do endpoint"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.secretsmanager_endpoint.id]
  tags                = local.common_tags
}

resource "aws_ssm_parameter" "secretsmanager_endpoint_id" {
  name  = "/siase/production/secretsmanager-endpoint-id"
  type  = "String"
  value = aws_vpc_endpoint.secretsmanager.id
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "secretsmanager_endpoint_sg_id" {
  name  = "/siase/production/secretsmanager-endpoint-sg-id"
  type  = "String"
  value = aws_security_group.secretsmanager_endpoint.id
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "vpc_id" {
  name  = "/siase/production/vpc-id"
  type  = "String"
  value = module.vpc.vpc_id
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "/siase/production/private-subnet-ids"
  type  = "String"
  value = jsonencode(module.vpc.private_subnets)
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "eks_node_sg_id" {
  name  = "/siase/production/eks-node-sg-id"
  type  = "String"
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  tags  = local.common_tags
}

resource "kubernetes_namespace_v1" "siase" {
  depends_on = [aws_eks_node_group.default]

  metadata {
    name = "siase"
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  depends_on = [aws_eks_node_group.default]

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

  values     = [file("${path.module}/helm/metrics-server-values.yaml")]
  depends_on = [aws_eks_node_group.default]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "61.7.2"
  wait             = true

  values = [
    templatefile("${path.module}/helm/kube-prometheus-stack-values.yaml", {
      grafana_admin_user     = var.grafana_admin_user
      grafana_admin_password = jsondecode(data.aws_secretsmanager_secret_version.grafana.secret_string)["password"]
    }),
    local.grafana_service_values
  ]

  lifecycle {
    precondition {
      condition     = var.grafana_service_type != "LoadBalancer" || length(var.grafana_allowed_cidrs) > 0
      error_message = "grafana_allowed_cidrs deve conter ao menos um CIDR ao usar LoadBalancer."
    }
  }

  depends_on = [kubernetes_namespace_v1.monitoring, aws_eks_node_group.default]
}

resource "helm_release" "loki" {
  name             = "loki"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "6.6.2"
  wait             = true
  timeout          = 900

  values     = [file("${path.module}/helm/loki-values.yaml")]
  depends_on = [kubernetes_namespace_v1.monitoring, aws_eks_node_group.default]
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
