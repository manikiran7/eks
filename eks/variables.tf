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

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.29" 
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
      replicas     = 1
      min_replicas = 2
      max_replicas = 3
      path         = "/user"
    }
    order-service = {
      image_tag    = "v1.0.1"
      port         = 8081
      replicas     = 1
      min_replicas = 2
      max_replicas = 3
      path         = "/order"
    }
    payment-service = {
      image_tag    = "v1.0.1"
      port         = 8082
      replicas     = 1
      min_replicas = 2
      max_replicas = 3
      path         = "/payment"
    }
    inventory-service = {
      image_tag    = "v1.0.1"
      port         = 8083
      replicas     = 1
      min_replicas = 2
      max_replicas = 3
      path         = "/inventory"
    }
    notification-service = {
      image_tag    = "v1.0.1"
      port         = 8084
      replicas     = 1
      min_replicas = 2
      max_replicas = 3
      path         = "/notification"
    }
    gateway-service = {
      image_tag    = "v1.0.1"
      port         = 8085
      replicas     = 2
      min_replicas = 2
      max_replicas = 3
      path         = "/gateway"
    }
    report-service = {
      image_tag    = "v1.0.1"
      port         = 8086
      replicas     = 1
      min_replicas = 2
      max_replicas = 3
      path         = "/report"
    }
    auth-service = {
      image_tag    = "v1.0.1"
      port         = 8087
      replicas     = 1
      min_replicas = 2
      max_replicas = 3
      path         = "/auth"
    }
    analytics-service = {
      image_tag    = "v1.0.1"
      port         = 8088
      replicas     = 1
      min_replicas = 2
      max_replicas = 3
      path         = "/analytics"
    }
    frontend-service = {
      image_tag    = "v1.0.1"
      port         = 8089
      replicas     = 1
      min_replicas = 2
      max_replicas = 3
      path         = "/"
    }
  }
}
