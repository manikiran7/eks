###############################################
# 1. EKS Cluster (Private Only)
###############################################
resource "aws_iam_role" "eks_cluster_role" {
  name = "${var.name_prefix}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "eks.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}

resource "aws_eks_cluster" "eks" {
  name     = "${var.name_prefix}-eks"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_service_policy
  ]
}

#  Wait for the EKS control plane to become active before continuing
resource "null_resource" "wait_for_eks" {
  provisioner "local-exec" {
    command = "aws eks wait cluster-active --name ${aws_eks_cluster.eks.name} --region ${var.region}"
  }
  depends_on = [aws_eks_cluster.eks]
}


###############################################
# 1.2 AWS Auth ConfigMap (EKS IAM → RBAC)
###############################################
# 🧩 Try to read existing aws-auth ConfigMap
data "kubernetes_config_map" "aws_auth_existing" {
  provider = kubernetes.eks

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  # Some clusters may not have this yet, so ignore errors
  # Terraform will handle missing data gracefully in 'try()' below
}

# ✅ Create aws-auth only if it doesn’t already exist
resource "kubernetes_config_map" "aws_auth" {
  provider = kubernetes.eks

  # Skip creating if the data lookup above finds it
  count = length(try(data.kubernetes_config_map.aws_auth_existing.metadata[0].name, "")) > 0 ? 0 : 1

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode([
      {
        rolearn  = aws_iam_role.eks_cluster_role.arn
        username = "admin"
        groups   = ["system:masters"]
      },
      {
        rolearn  = aws_iam_role.fargate_exec_role.arn
        username = "fargate"
        groups   = ["system:bootstrappers", "system:nodes"]
      },
      {
        rolearn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/jenkins-eks-role"
        username = "jenkins"
        groups   = ["system:masters"]
      }
    ])
  }

  lifecycle {
    ignore_changes = [metadata, data]
  }

  depends_on = [
    aws_eks_cluster.eks,
    null_resource.wait_for_eks,
    null_resource.wait_for_api
  ]
}

###############################################
# 2. Fargate Pod Execution Role
###############################################
resource "aws_iam_role" "fargate_exec_role" {
  name = "${var.name_prefix}-fargate-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "eks-fargate-pods.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fargate_exec_attach" {
  role       = aws_iam_role.fargate_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

###############################################
# 3. Fargate Profiles
###############################################
resource "aws_eks_fargate_profile" "default" {
  cluster_name           = aws_eks_cluster.eks.name
  fargate_profile_name   = "${var.name_prefix}-default"
  pod_execution_role_arn = aws_iam_role.fargate_exec_role.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "default"
  labels    = {}
  }

  depends_on = [null_resource.wait_for_eks]
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_fargate_profile" "kube_system" {
  cluster_name           = aws_eks_cluster.eks.name
  fargate_profile_name   = "${var.name_prefix}-kube-system"
  pod_execution_role_arn = aws_iam_role.fargate_exec_role.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "kube-system"
    labels    = {}
  }

  depends_on = [null_resource.wait_for_eks]
  lifecycle {
    create_before_destroy = true
  }
}


###############################################
# 4. OIDC & ALB Controller IAM Role (Fixed)
###############################################

resource "aws_iam_openid_connect_provider" "eks" {
  url             = data.aws_eks_cluster.eks.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]

  # ✅ Pre-fetched thumbprint for us-east-1
  # You got this via `openssl s_client ...`
  thumbprint_list = ["d7d10ac1fd7e87f1a3787a9a8be9b0f8538ec059"]
}

# --------------------------------------------------------------------
# ALB Controller IAM Policy and Role
# --------------------------------------------------------------------
resource "aws_iam_policy" "alb_controller_policy_custom" {
  name        = "${var.name_prefix}-AWSLoadBalancerControllerPolicy"
  description = "Custom IAM policy for AWS Load Balancer Controller"
  policy      = file("${path.module}/iam-policies/aws-load-balancer-controller-policy.json")
}

resource "aws_iam_role" "alb_controller" {
  name = "${var.name_prefix}-alb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller_policy" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller_policy_custom.arn
}

# --------------------------------------------------------------------
# Kubernetes Service Account (AWS Load Balancer Controller)
# --------------------------------------------------------------------
resource "kubernetes_service_account" "alb_sa" {
  provider = kubernetes.eks

  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
    }
  }

  automount_service_account_token = true

  depends_on = [
    aws_iam_openid_connect_provider.eks,
    aws_iam_role.alb_controller,
    aws_iam_role_policy_attachment.alb_controller_policy,
    null_resource.wait_for_eks
  ]
}



################################################
# 6. Deploy Services (No Service Object)
###############################################
data "aws_caller_identity" "current" {}

locals {
  rendered_deployments = {
    for svc, meta in var.services :
    svc => templatefile("${path.module}/services/${svc}/deployment.yaml.tpl", {
      service_name = svc
      image_tag    = meta.image_tag
      port         = meta.port
      replicas     = meta.replicas
      account_id   = data.aws_caller_identity.current.account_id
      region       = var.region
    })
  }

  rendered_hpa = {
    for svc, meta in var.services :
    svc => templatefile("${path.module}/services/${svc}/hpa.yaml.tpl", {
      service_name = svc
      replicas     = meta.replicas
    })
  }

  rendered_ingress = {
    for svc, meta in var.services :
    svc => templatefile("${path.module}/services/${svc}/ingress.yaml.tpl", {
      service_name = svc
      port         = meta.port
      path         = meta.path
      name_prefix  = var.name_prefix
    })
  }
}

###############################################
# Deployments
###############################################
# ✅ Deploy Kubernetes resources safely to EKS
resource "kubectl_manifest" "deployments" {
  provider  = kubectl.eks
  for_each  = local.rendered_deployments
  yaml_body = each.value

  # Wait for deployments to be ready before continuing
  wait = true
  force_conflicts = true


  depends_on = [
    null_resource.refresh_kubeconfig,   
    aws_eks_cluster.eks,                
    aws_eks_fargate_profile.default,    
    null_resource.wait_for_fargate,    
    kubernetes_config_map.aws_auth      
  ]
}

###############################################
# Ingress (direct to pods via IP targets)
###############################################
# ✅ Deploy ingress manifests only after deployments are ready
resource "kubectl_manifest" "ingress" {
  provider  = kubectl.eks
  for_each  = local.rendered_ingress
  yaml_body = each.value

  # Wait until ingress objects are ready
  wait = true
  force_conflicts = true

  depends_on = [
    null_resource.refresh_kubeconfig, 
    kubectl_manifest.deployments,      
    null_resource.wait_for_pods,      
    aws_eks_fargate_profile.default,
    null_resource.wait_for_fargate,
    kubernetes_config_map.aws_auth
  ]
}



###############################################
# Metrics Server + HPA
###############################################
resource "helm_release" "metrics_server" {
  provider   = helm.eks
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 300

  set_list = [{
    name  = "args"
     value = ["--kubelet-insecure-tls", "--metric-resolution=15s"]
  }]

  lifecycle {
    ignore_changes = [set, namespace]
  }

  depends_on = [
    aws_eks_cluster.eks,
    null_resource.wait_for_eks
  ]
}

###############################################
# HPA
###############################################
resource "kubectl_manifest" "hpa" {
  provider  = kubectl.eks
  for_each  = local.rendered_hpa
  yaml_body = each.value
  wait      = true

  depends_on = [
  null_resource.wait_for_pods,
  kubectl_manifest.ingress,
  null_resource.wait_for_fargate
]


}

###############################################
# 7. Enable CloudWatch Container Insights
###############################################
resource "aws_cloudwatch_log_group" "eks_container_insights" {
  name              = "/aws/containerinsights/${aws_eks_cluster.eks.name}/performance"
  retention_in_days = 30
}

resource "aws_iam_policy" "cloudwatch_agent_policy" {
  name        = "${var.name_prefix}-CloudWatchAgentPolicy"
  description = "Allows CloudWatch agent to push metrics and logs"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = [
        "logs:PutLogEvents",
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:CreateLogGroup",
        "logs:DescribeLogGroups",
        "cloudwatch:PutMetricData"
      ],
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "cloudwatch_agent_role" {
  name = "${var.name_prefix}-cloudwatch-agent-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "eks-fargate-pods.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent_attach" {
  role       = aws_iam_role.cloudwatch_agent_role.name
  policy_arn = aws_iam_policy.cloudwatch_agent_policy.arn
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent_managed_policy" {
  role       = aws_iam_role.cloudwatch_agent_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

###############################################
# 8. CloudWatch Agent (Metrics + Logs)
###############################################
resource "helm_release" "cloudwatch_container_insights" {
  provider         = helm.eks
  name             = "aws-cloudwatch-observability"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-cloudwatch-metrics"
  namespace        = "amazon-cloudwatch"
  create_namespace = true

  set = [
    { name = "clusterName", value = aws_eks_cluster.eks.name },
    { name = "region", value = var.region },
    { name = "serviceAccount.create", value = "true" },
    { name = "serviceAccount.name", value = "cloudwatch-agent" },
    { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn", value = aws_iam_role.cloudwatch_agent_role.arn },
    { name = "metricsCollectionInterval", value = "60" },
    { name = "logs.enabled", value = "true" }
  ]

 depends_on = [
  kubectl_manifest.deployments,
  kubectl_manifest.ingress,
  null_resource.wait_for_fargate
]

}




###############################################
# 9. CloudWatch Dashboard (CPU + Memory + Pods)
###############################################
resource "aws_cloudwatch_dashboard" "eks_services_dashboard" {
  dashboard_name = "${var.name_prefix}-eks-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric",
        x = 0,
        y = 0,
        width = 24,
        height = 6,
        properties = {
          title = "CPU Utilization per Service",
          view  = "timeSeries",
          region = var.region,
          metrics = [
            [ "ContainerInsights/Pod", "cpu_usage_total", "ClusterName", aws_eks_cluster.eks.name ]
          ]
        }
      },
      {
        type = "metric",
        x = 0,
        y = 7,
        width = 24,
        height = 6,
        properties = {
          title = "Memory Usage per Service",
          view  = "timeSeries",
          region = var.region,
          metrics = [
            [ "ContainerInsights/Pod", "memory_working_set", "ClusterName", aws_eks_cluster.eks.name ]
          ]
        }
      },
      {
        type = "metric",
        x = 0,
        y = 14,
        width = 24,
        height = 6,
        properties = {
          title = "Pod Count per Service",
          view  = "timeSeries",
          region = var.region,
          metrics = [
            [ "ContainerInsights/Service", "pod_number_of_running_pods", "ClusterName", aws_eks_cluster.eks.name ]
          ]
        }
      }
    ]
  })
}

###############################################
# 10. Security Group Rule — Allow HTTPS to EKS
###############################################
resource "aws_security_group_rule" "allow_https_to_eks" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
 source_security_group_id = "sg-099263263e2326f88" 
 security_group_id        = aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
 description              = "Allow HTTPS from Jenkins EC2 SG to EKS Control Plane"
 depends_on               = [aws_eks_cluster.eks]
}

resource "null_resource" "wait_for_fargate" {
  provisioner "local-exec" {
    command = "echo 'Waiting 120s for Fargate/OIDC propagation...' && sleep 120"
  }
  depends_on = [
    aws_eks_fargate_profile.kube_system,
    aws_eks_fargate_profile.default,
    aws_iam_openid_connect_provider.eks
  ]
}

# wait a bit for Fargate pods to start and stabilize after deployments
resource "null_resource" "wait_for_pods" {
  provisioner "local-exec" {
    command = "echo 'Waiting 90s for pods to stabilize...' && sleep 90"
  }

  depends_on = [
    kubectl_manifest.deployments
  ]
}

# ✅ Wait for the EKS API to become active and reachable
resource "null_resource" "wait_for_api" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<EOT
set -e
endpoint=$(aws eks describe-cluster \
  --name ${aws_eks_cluster.eks.name} \
  --region ${var.region} \
  --query "cluster.endpoint" \
  --output text)

echo "🔍 Waiting for EKS API at $endpoint..."
for i in $(seq 1 10); do
  if curl -sk --connect-timeout 5 "$endpoint"/version > /dev/null; then
    echo "✅ EKS API reachable."
    exit 0
  fi
  echo "⏳ Waiting... ($i/10)"
  sleep 10
done

echo "❌ ERROR: EKS API not reachable after retries!" >&2
exit 1
EOT
  }
  depends_on = [aws_eks_cluster.eks]
}

# ✅ Verify EKS connectivity (runs right after wait_for_api)
resource "null_resource" "verify_eks_connection" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<EOT
set -e
endpoint=$(aws eks describe-cluster \
  --name ${aws_eks_cluster.eks.name} \
  --region ${var.region} \
  --query "cluster.endpoint" \
  --output text)

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

  depends_on = [null_resource.wait_for_api]
}


resource "null_resource" "aws_auth_check" {
  provisioner "local-exec" {
    command = "echo 'aws-auth already exists, skipping creation...'"
  }

  count = length(try(data.kubernetes_config_map.aws_auth_existing.metadata[0].name, "")) > 0 ? 1 : 0
}


resource "null_resource" "refresh_kubeconfig" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<EOT
set -e
echo "🔄 Updating kubeconfig for EKS cluster..."
aws eks update-kubeconfig --name ${aws_eks_cluster.eks.name} --region ${var.region}
kubectl get nodes || echo "⚠️ Cluster not ready yet, continuing..."
EOT
  }

  depends_on = [
    aws_eks_cluster.eks,
    null_resource.wait_for_api,
    null_resource.verify_eks_connection
  ]
}

# ✅ Wait for all pods to become Ready before proceeding
resource "null_resource" "wait_for_pods" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<EOT
set -e
echo "⏳ Waiting for all pods to be Ready..."
for i in $(seq 1 30); do
  not_ready=$(kubectl get pods -A --no-headers | grep -v Running || true)
  if [ -z "$not_ready" ]; then
    echo "✅ All pods are Ready."
    exit 0
  fi
  echo "⌛ Still waiting... ($i/30)"
  sleep 10
done
echo "❌ Timeout waiting for pods." >&2
exit 1
EOT
  }

  depends_on = [
    kubectl_manifest.deployments,
    null_resource.refresh_kubeconfig
  ]
}
