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
  default     = "vpc-0ddd4652ed3ab0f93"
}

variable "public_subnet_ids" {
  description = "List of public subnets used for ALB / public resources"
  type        = list(string)
  default     = [
     "subnet-05b21b389824313c9",
  "subnet-00d638cb30a394d23",
  "subnet-0e8da55dcbd31c37a"
  ]
}

variable "private_subnet_ids" {
  description = "List of private subnets used for workloads and pods"
  type        = list(string)
  default     = [
   "subnet-0606b4c79397af066",
  "subnet-055ed29a53cc6f390",
  "subnet-05b5dcccb50e8fa7f"
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
      image_tag    = "v1.0.0"
      port         = 8080
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/user"
    }
    order-service = {
      image_tag    = "v1.0.0"
      port         = 8081
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/order"
    }
    payment-service = {
      image_tag    = "v1.0.0"
      port         = 8082
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/payment"
    }
    inventory-service = {
      image_tag    = "v1.0.0"
      port         = 8083
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/inventory"
    }
    notification-service = {
      image_tag    = "v1.0.0"
      port         = 8084
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/notification"
    }
    gateway-service = {
      image_tag    = "v1.0.0"
      port         = 8085
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/gateway"
    }
    report-service = {
      image_tag    = "v1.0.0"
      port         = 8086
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/report"
    }
    auth-service = {
      image_tag    = "v1.0.0"
      port         = 8087
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/auth"
    }
    analytics-service = {
      image_tag    = "v1.0.0"
      port         = 8088
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/analytics"
    }
    frontend-service = {
      image_tag    = "v1.0.0"
      port         = 8089
      replicas     = 2
      min_replicas = 2
      max_replicas = 6
      path         = "/"
    }
  }
}