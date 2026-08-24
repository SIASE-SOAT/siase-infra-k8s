output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value     = aws_eks_cluster.this.endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "lb_dns_ssm_parameter" {
  value = aws_ssm_parameter.lb_dns.name
}
