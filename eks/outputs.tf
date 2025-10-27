###############################################
# EKS Login Command
###############################################
output "eks_login_command" {
  description = "Command to authenticate your local kubectl with the EKS cluster"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.eks.name} --region ${var.region}"
}
