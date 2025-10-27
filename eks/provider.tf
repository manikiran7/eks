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
# Wait for EKS readiness and verify connectivity before initializing providers
# --------------------------------------------------------------------
resource "null_resource" "verify_eks_connection" {
  provisioner "local-exec" {
    command = <<EOT
endpoint=$(aws eks describe-cluster --name ${var.name_prefix}-eks --region ${var.region} --query "cluster.endpoint" --output text)
echo "🔍 Checking EKS endpoint: $endpoint"
for i in $(seq 1 10); do
  if curl -sk --connect-timeout 5 "$endpoint"/version > /dev/null; then
    echo "✅ EKS API is reachable."
    exit 0
  fi
  echo "⏳ Waiting for EKS API... ($i/10)"
  sleep 10
done
echo "❌ EKS API not reachable after retries." >&2
exit 1
EOT
  }

  depends_on = [aws_eks_cluster.eks, null_resource.wait_for_eks]
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
