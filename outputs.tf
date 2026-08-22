output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "nlb_dns_ssm_parameter" {
  value = aws_ssm_parameter.nlb_dns.name
}
