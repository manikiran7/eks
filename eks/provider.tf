terraform {
  backend "s3" {
    bucket         = "my-terraform-state-prod-manikiran"
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-lock-table"
    encrypt        = true
  }

  required_version = ">= 1.2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.11"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.11"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
}

# --------------------------------------------------------------------
# AWS Provider
# --------------------------------------------------------------------
provider "aws" {
  region = var.region
}

# --------------------------------------------------------------------
# EKS Cluster Data Sources (used by Kubernetes / Helm / Kubectl providers)
# --------------------------------------------------------------------
data "aws_eks_cluster" "eks" {
  name       = "${var.name_prefix}-eks"
  depends_on = [null_resource.wait_for_eks, null_resource.verify_eks_connection]
}

data "aws_eks_cluster_auth" "eks" {
  name       = data.aws_eks_cluster.eks.name
  depends_on = [null_resource.wait_for_eks, null_resource.verify_eks_connection]
}

# --------------------------------------------------------------------
# Kubernetes Provider
# --------------------------------------------------------------------
provider "kubernetes" {
  alias                  = "eks"
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

# --------------------------------------------------------------------
# Helm Provider
# --------------------------------------------------------------------
provider "helm" {
  alias = "eks"
  kubernetes = {
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.eks.token
  }
}

# --------------------------------------------------------------------
# Kubectl Provider
# --------------------------------------------------------------------
provider "kubectl" {
  alias                  = "eks"
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}
