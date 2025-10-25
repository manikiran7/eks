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
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true

      public_access_cidrs     = [
    "98.89.215.51",
    "3.81.152.207",
    "54.85.203.73"
  ]
  
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_service_policy
  ]
}

# ✅ Wait for the EKS control plane to become active before continuing
resource "null_resource" "wait_for_eks" {
  provisioner "local-exec" {
    command = "aws eks wait cluster-active --name ${aws_eks_cluster.eks.name} --region ${var.region}"
  }
  depends_on = [aws_eks_cluster.eks]
}

###############################################
# 1.1 EKS Cluster Auth (for providers)
###############################################
data "aws_eks_cluster" "eks" {
  name = aws_eks_cluster.eks.name
  depends_on = [null_resource.wait_for_eks]
}

data "aws_eks_cluster_auth" "eks" {
  name = aws_eks_cluster.eks.name
  depends_on = [null_resource.wait_for_eks]
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
  }

  depends_on = [null_resource.wait_for_eks]
}

resource "aws_eks_fargate_profile" "kube_system" {
  cluster_name           = aws_eks_cluster.eks.name
  fargate_profile_name   = "${var.name_prefix}-kube-system"
  pod_execution_role_arn = aws_iam_role.fargate_exec_role.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "kube-system"
  }

  depends_on = [null_resource.wait_for_eks]
}

###############################################
# 4. OIDC & ALB Controller IAM Role (Fixed)
###############################################
data "tls_certificate" "eks_oidc" {
  url = data.aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = data.aws_eks_cluster.eks.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

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

###############################################
# 5. Deploy AWS ALB Controller via Helm
###############################################
resource "helm_release" "alb_controller" {
  provider   = helm.eks
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  timeout          = 600
  cleanup_on_fail  = true
  replace        = true
force_update   = true


  set = [
    { name = "clusterName", value = aws_eks_cluster.eks.name },
    { name = "serviceAccount.create", value = "false" },
    { name = "serviceAccount.name", value = kubernetes_service_account.alb_sa.metadata[0].name }
  ]

  depends_on = [
    kubernetes_service_account.alb_sa,
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
resource "kubectl_manifest" "deployments" {
  provider  = kubectl.eks
  for_each  = local.rendered_deployments
  yaml_body = each.value
  wait      = true

  depends_on = [
    aws_eks_fargate_profile.default,
    helm_release.alb_controller,
    null_resource.wait_for_eks
  ]
}

###############################################
# Ingress (direct to pods via IP targets)
###############################################
resource "kubectl_manifest" "ingress" {
  provider  = kubectl.eks
  for_each  = local.rendered_ingress
  yaml_body = each.value
  wait      = true

  depends_on = [
    kubectl_manifest.deployments,
    helm_release.alb_controller,
    null_resource.wait_for_eks
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

  set_list = [{
    name  = "args"
    value = ["--kubelet-insecure-tls"]
  }]

  depends_on = [
    aws_eks_cluster.eks,
    null_resource.wait_for_eks
  ]
}

resource "kubectl_manifest" "hpa" {
  provider  = kubectl.eks
  for_each  = local.rendered_hpa
  yaml_body = each.value
  wait      = true

  depends_on = [
    helm_release.metrics_server,
    kubectl_manifest.deployments,
    null_resource.wait_for_eks
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
  provider   = helm.eks
  name       = "aws-cloudwatch-observability"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-cloudwatch-metrics"
  namespace  = "amazon-cloudwatch"
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
    aws_iam_role.cloudwatch_agent_role,
    helm_release.metrics_server,
    aws_eks_fargate_profile.default,
    null_resource.wait_for_eks
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
