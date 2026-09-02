variable "aws_region" {
  type        = string
  description = "Região AWS."
}

variable "environment" {
  type        = string
  default     = "production"
  description = "Ambiente fixo."
}

variable "project_name" {
  type        = string
  default     = "siase"
  description = "Prefixo dos recursos."
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.40.1.0/24", "10.40.2.0/24"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.40.101.0/24", "10.40.102.0/24"]
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "lab_role_arn" {
  type        = string
  description = "ARN da role pré-criada LabRole do AWS Academy Learner Lab."
}

variable "grafana_secret_arn" {
  type        = string
  description = "ARN do segredo JSON no Secrets Manager. O JSON deve conter password."
}

variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "grafana_service_type" {
  type        = string
  default     = "ClusterIP"
  description = "Tipo do Service do Grafana. Use LoadBalancer somente durante a gravação, com CIDRs permitidos configurados."

  validation {
    condition     = contains(["ClusterIP", "LoadBalancer"], var.grafana_service_type)
    error_message = "grafana_service_type deve ser ClusterIP ou LoadBalancer."
  }
}

variable "grafana_allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "Lista de CIDRs autorizados a alcançar o Load Balancer do Grafana, por exemplo o IP público do usuário com máscara /32."
}

variable "lb_dns_ssm_parameter" {
  type        = string
  default     = ""
  description = "Override opcional do parâmetro SSM que receberá o DNS do Load Balancer."
}

variable "tags" {
  type    = map(string)
  default = {}
}
