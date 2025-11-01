output "eks_login_command" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.eks.name} --region ${var.region}"
}
