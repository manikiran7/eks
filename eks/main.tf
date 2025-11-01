###############################################
# PULL VPC OUTPUTS FROM REMOTE STATE (ADDED)
###############################################
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "my-terraform-state-prod-manikiran"
    key    = "vpc/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  public_subnet_ids  = data.terraform_remote_state.vpc.outputs.public_subnet_ids
}
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
    subnet_ids              = local.private_subnet_ids
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
# 2 AWS Auth ConfigMap (EKS IAM → RBAC)
###############################################

resource "kubernetes_config_map" "aws_auth" {
  provider = kubernetes.eks


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
  null_resource.refresh_kubeconfig
]

}

###############################################
# 3. Fargate Pod Execution Role
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
# 4. Fargate Profiles
###############################################
resource "aws_eks_fargate_profile" "default" {
  cluster_name           = aws_eks_cluster.eks.name
  fargate_profile_name   = "${var.name_prefix}-default"
  pod_execution_role_arn = aws_iam_role.fargate_exec_role.arn
  subnet_ids             = local.private_subnet_ids

  selector {
    namespace = "default"
  }

  depends_on = [null_resource.wait_for_eks]

  tags = {
    Name        = "${var.name_prefix}-fargate-profile-default"
    Environment = var.name_prefix
    ManagedBy   = "Terraform"
  }
}

resource "aws_eks_fargate_profile" "kube_system" {
  cluster_name           = aws_eks_cluster.eks.name
  fargate_profile_name   = "${var.name_prefix}-kube-system"
  pod_execution_role_arn = aws_iam_role.fargate_exec_role.arn
  subnet_ids             = local.private_subnet_ids

  selector {
    namespace = "kube-system"
  }

  depends_on = [
    null_resource.wait_for_eks,
    aws_eks_fargate_profile.default 
  ]

  

  tags = {
    Name        = "${var.name_prefix}-fargate-profile-kube-system"
    Environment = var.name_prefix
    ManagedBy   = "Terraform"
  }
}




###############################################
# 5. OIDC & ALB Controller IAM Role (Fixed)
###############################################

resource "aws_iam_openid_connect_provider" "eks" {
  url             = data.aws_eks_cluster.eks.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["d7d10ac1fd7e87f1a3787a9a8be9b0f8538ec059"]
    
  depends_on = [
    null_resource.wait_for_api   # ✅ ensures cluster API is alive
  ]
}

# --------------------------------------------------------------------
# 6 ALB Controller IAM Policy and Role
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
# 7 Kubernetes Service Account (AWS Load Balancer Controller)
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
    aws_iam_openid_connect_provider.eks,      # OIDC must exist
    aws_iam_role.alb_controller,              # Role must exist
    aws_iam_role_policy_attachment.alb_controller_policy,
    null_resource.refresh_kubeconfig          # Ensure kubeconfig is ready
  ]
}


###############################################
# 8. AWS Load Balancer Controller (Helm)
###############################################
resource "helm_release" "alb_controller" {
  provider  = helm.eks
  name      = "aws-load-balancer-controller"
  namespace = "kube-system"

  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.9.2"

  set = [
    {
      name  = "clusterName"
      value = aws_eks_cluster.eks.name
    },
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account.alb_sa.metadata[0].name
    },
    {
      name  = "region"
      value = var.region
    },
    {
      name  = "vpcId"
      value = local.vpc_id
    }
  ]

  depends_on = [
    kubernetes_service_account.alb_sa,          # SA must exist
    aws_iam_role.alb_controller,                # IAM role exists
    aws_iam_role_policy_attachment.alb_controller_policy,
    null_resource.refresh_kubeconfig            
  ]
}


################################################
# 9. Deploy Services (No Service Object)
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
# 10 Deployments
###############################################
#  Deploy Kubernetes resources safely to EKS
resource "kubectl_manifest" "deployments" {
  provider  = kubectl.eks
  for_each  = local.rendered_deployments
  yaml_body = each.value

  wait            = true
  force_conflicts = true

  depends_on = [
    null_resource.refresh_kubeconfig,  # Kubeconfig + API ready
    kubernetes_config_map.aws_auth,    # aws-auth RBAC applied
    null_resource.wait_for_fargate     #  (or node group) ensure nodes exist
  ]
}




###############################################
# 11 Ingress (create only if missing)
###############################################

# Detect existing Ingress resources
# Detect existing ingress resources
data "kubernetes_ingress" "existing" {
  for_each = local.rendered_ingress

  metadata {
    name      = each.key
    namespace = "default"
  }

  provider = kubernetes.eks
}

# Create Ingress only if not already present
resource "kubectl_manifest" "ingress" {
  provider  = kubectl.eks

  for_each = {
    for k, v in local.rendered_ingress :
    k => v if !contains(keys(data.kubernetes_ingress.existing), k)
  }

  yaml_body = each.value
  wait      = true
  force_conflicts = true

  depends_on = [
    null_resource.refresh_kubeconfig,    #  kubeconfig + API ready
    kubernetes_config_map.aws_auth,      #  node auth working
    kubectl_manifest.deployments,        #  ensure deployments exist
    null_resource.wait_for_pods,         #  ensure pods are running
    null_resource.wait_for_fargate       #  only if using Fargate
  ]
}



###############################################
# 12 Metrics Server + HPA
###############################################

data "external" "check_metrics_server" {
  program = ["bash", "-c", <<EOT
if helm status metrics-server -n kube-system >/dev/null 2>&1; then
  echo '{"exists":"true"}'
else
  echo '{"exists":"false"}'
fi
EOT
  ]
}

#  Create only if missing
resource "helm_release" "metrics_server" {
  count      = data.external.check_metrics_server.result.exists == "false" ? 1 : 0
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

  depends_on = [
    null_resource.refresh_kubeconfig
  ]
}


###############################################
# 13 HPA
###############################################
resource "kubectl_manifest" "hpa" {
  provider  = kubectl.eks
  for_each  = local.rendered_hpa
  yaml_body = each.value
  wait      = true

  depends_on = [
    null_resource.refresh_kubeconfig,      #  kubeconfig + API ready
    kubectl_manifest.deployments,          #  target deployments exist
    kubectl_manifest.ingress,              #  ingress is ready (optional but okay)
    null_resource.wait_for_fargate,        #  Fargate workloads deployed
    helm_release.metrics_server            #  Metrics server installed → required for HPA
  ]
}


###############################################
# 14. Enable CloudWatch Container Insights
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
# 15. CloudWatch Agent (Metrics + Logs)
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
    null_resource.refresh_kubeconfig,    #  Kubeconfig & API ready
    kubectl_manifest.deployments,        #  Deployments exist
    kubectl_manifest.ingress,            #  Ingress created (optional, fine)
    null_resource.wait_for_fargate       #  If you're using Fargate nodes
  ]
}





###############################################
# 16. CloudWatch Dashboard (CPU + Memory + Pods)
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
# 17. Security Group Rule — Allow HTTPS to EKS
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



# 18 Wait for the EKS API to become active and reachable
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

echo " Waiting for EKS API at $endpoint..."
for i in $(seq 1 10); do
  if curl -sk --connect-timeout 5 "$endpoint"/version > /dev/null; then
    echo " EKS API reachable."
    exit 0
  fi
  echo " Waiting... ($i/5)"
  sleep 10
done

echo " ERROR: EKS API not reachable after retries!" >&2
exit 1
EOT
  }
  depends_on = [aws_eks_cluster.eks,null_resource.wait_for_eks]
}

#  19 Verify EKS connectivity (runs right after wait_for_api)
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

echo " Checking EKS endpoint: $endpoint"
for i in $(seq 1 5); do
  if curl -sk --connect-timeout 5 "$endpoint"/version > /dev/null; then
    echo " EKS API is reachable."
    exit 0
  fi
  echo " Waiting for EKS API... ($i/5)"
  sleep 10
done

echo " EKS API not reachable after retries." >&2
exit 1
EOT
  }

  depends_on = [null_resource.wait_for_api,null_resource.wait_for_eks]
}

# 20 aws auth check 
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
echo " Updating kubeconfig for EKS cluster..."
aws eks update-kubeconfig --name ${aws_eks_cluster.eks.name} --region ${var.region}
kubectl get nodes || echo " Cluster not ready yet, continuing..."
EOT
  }

  depends_on = [
    aws_eks_cluster.eks,
    null_resource.wait_for_api,
    null_resource.verify_eks_connection
  ]
}

# 21 waiting for pods deploy 
resource "null_resource" "wait_for_pods" {
  # Run only when deployments change (prevents unnecessary re-runs)
  triggers = {
    deployments_hash = sha1(join(",", keys(kubectl_manifest.deployments)))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<EOT
set -euo pipefail
echo " Waiting for all pods in 'default' namespace to be Ready..."

for i in $(seq 1 12); do   # 12 attempts = 2 minutes (12 * 10s)
  # Get pods which are NOT in Running or Completed state
  not_ready=$(kubectl get pods -n default --no-headers | grep -Ev 'Running|Completed' || true)

  if [ -z "$not_ready" ]; then
    echo " All pods in 'default' namespace are Ready."
    exit 0
  fi

  echo " Still waiting... ($i/12)"
  sleep 10
done

echo " Timeout: Some pods are not Ready after waiting." >&2
kubectl get pods -n default
exit 1
EOT
  }

  depends_on = [
    null_resource.refresh_kubeconfig, #  Ensure kubeconfig + API is ready
    kubectl_manifest.deployments      #  Deployments must be applied first
  ]
}

#22 deploying the pods
resource "null_resource" "apply_image_update" {
  for_each = var.services

  triggers = {
    image_tag = each.value.image_tag  # re-runs only when image changes
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<EOT
set -euo pipefail

svc="${each.key}"
image_tag="${each.value.image_tag}"
account_id=$(aws sts get-caller-identity --query "Account" --output text)
region="${var.region}"
image_repo="$${account_id}.dkr.ecr.$${region}.amazonaws.com/$${svc}:$${image_tag}"

echo " Starting rolling update for $${svc} → $${image_repo}"

# Make sure kubeconfig is updated (idempotent)
aws eks update-kubeconfig --name ${aws_eks_cluster.eks.name} --region ${var.region}

# Ensure deployment exists before trying to update
if ! kubectl get deployment/$${svc} -n default >/dev/null 2>&1; then
  echo " Deployment $${svc} does not exist in cluster — skipping."
  exit 0
fi

# Apply rolling update
kubectl -n default set image deployment/$${svc} $${svc}=$${image_repo} --record

# Wait for rollout to finish
if ! kubectl -n default rollout status deployment/$${svc} --timeout=180s; then
  echo " Rollout failed for $${svc}. Rolling back..."
  kubectl -n default rollout undo deployment/$${svc}
  exit 1
fi

echo " Rollout succeeded for $${svc}"
EOT
  }

  depends_on = [
    null_resource.refresh_kubeconfig,   #  kubeconfig & API ready
    kubectl_manifest.deployments        #  workloads exist first
    # Optionally add:
    # kubectl_manifest.ingress,          #  ingress available
    # helm_release.metrics_server        #  metrics ready for HPA
  ]
}
