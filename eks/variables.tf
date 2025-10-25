variable "name_prefix" {
  description = "Prefix for all AWS resources (e.g., cluster, IAM roles, etc.)"
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS region where resources will be deployed"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "VPC ID to deploy EKS into"
  type        = string
  default     = "vpc-02b7ace48d47abcea"
}

variable "public_subnet_ids" {
  description = "List of public subnets used for ALB / public resources"
  type        = list(string)
  default     = [
"subnet-0ce42c0a6f8a75095",
  "subnet-077c75c62d335b517",
  "subnet-0872779df67bfa27c"
  ]
}

variable "private_subnet_ids" {
  description = "List of private subnets used for workloads and pods"
  type        = list(string)
  default     = [
 "subnet-09e40f0c28deae1e2",
  "subnet-0b3c79932e6d1487d",
  "subnet-0decf83a78f55d8bd"
  ]
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "services" {
  description = "Map of microservices configuration, including image tag, port, scaling, and ingress path"
  type = map(object({
    image_tag    = string
    port         = number
    replicas     = number
    min_replicas = number
    max_replicas = number
    path         = string
  }))

  default = {
    user-service = {
      image_tag    = "v1.0.1"
      port         = 8080
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/user"
    }
    order-service = {
      image_tag    = "v1.0.1"
      port         = 8081
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/order"
    }
    payment-service = {
      image_tag    = "v1.0.1"
      port         = 8082
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/payment"
    }
    inventory-service = {
      image_tag    = "v1.0.1"
      port         = 8083
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/inventory"
    }
    notification-service = {
      image_tag    = "v1.0.1"
      port         = 8084
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/notification"
    }
    gateway-service = {
      image_tag    = "v1.0.1"
      port         = 8085
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/gateway"
    }
    report-service = {
      image_tag    = "v1.0.1"
      port         = 8086
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/report"
    }
    auth-service = {
      image_tag    = "v1.0.1"
      port         = 8087
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/auth"
    }
    analytics-service = {
      image_tag    = "v1.0.1"
      port         = 8088
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/analytics"
    }
    frontend-service = {
      image_tag    = "v1.0.1"
      port         = 8089
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/"
    }
  }
}