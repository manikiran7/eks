terraform {
  required_version = ">= 1.2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

###################################################
# VARIABLES (with defaults)
###################################################
variable "vpc_id" {
  description = "VPC ID to deploy resources into"
  type        = string
  default     = "vpc-0ddd4652ed3ab0f93"
}

variable "public_subnet_ids" {
  description = "List of public subnets used for Jenkins"
  type        = list(string)
  default     = [
    "subnet-05b21b389824313c9",
    "subnet-00d638cb30a394d23",
    "subnet-0e8da55dcbd31c37a"
  ]
}

variable "private_subnet_ids" {
  description = "List of private subnets used for EKS admin node"
  type        = list(string)
  default     = [
    "subnet-0606b4c79397af066",
    "subnet-055ed29a53cc6f390",
    "subnet-05b5dcccb50e8fa7f"
  ]
}

###################################################
# SECURITY GROUPS
###################################################
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-public-sg"
  description = "Allow SSH and Jenkins UI"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "jenkins-public-sg"
  }
}

resource "aws_security_group" "eks_admin_sg" {
  name        = "eks-admin-private-sg"
  description = "Allow SSH from Jenkins and access to EKS"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow SSH from Jenkins"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-admin-sg"
  }
}

###################################################
# IAM ROLES AND INSTANCE PROFILES
###################################################
resource "aws_iam_role" "jenkins_role" {
  name = "jenkins-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_admin_policy" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "jenkins-instance-profile"
  role = aws_iam_role.jenkins_role.name
}

resource "aws_iam_role" "eks_admin_role" {
  name = "eks-admin-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

# Grant full AWS admin access (includes ECR, EKS, Terraform S3, etc.)
resource "aws_iam_role_policy_attachment" "eks_admin_policy" {
  role       = aws_iam_role.eks_admin_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "eks_admin_profile" {
  name = "eks-admin-instance-profile"
  role = aws_iam_role.eks_admin_role.name
}

###################################################
# PUBLIC EC2 - JENKINS SERVER
###################################################
resource "aws_instance" "jenkins_server" {
  ami                         = "ami-0c7217cdde317cfec" # Ubuntu 22.04
  instance_type               = "t2.medium"
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.jenkins_profile.name
  key_name                    = "mani"   # Use existing AWS key pair

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt update -y
    apt install -y fontconfig openjdk-21-jre git awscli unzip
    mkdir -p /etc/apt/keyrings
    wget -O /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
    echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list
    apt update -y
    apt install -y jenkins
    systemctl enable jenkins
    systemctl start jenkins
  EOF

  tags = {
    Name = "Jenkins-Public-EC2"
  }
}

###################################################
# PRIVATE EC2 - EKS ADMIN NODE
###################################################
resource "aws_instance" "eks_admin_server" {
  ami                    = "ami-0c7217cdde317cfec" # Ubuntu 22.04
  instance_type          = "t2.medium"
  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.eks_admin_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.eks_admin_profile.name
  key_name               = "mani"
  associate_public_ip_address = false

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt update -y
    apt install -y curl unzip python3-pip jq git
    pip install awscli --upgrade

    # Install kubectl
    curl -o kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-07-18/bin/linux/amd64/kubectl
    chmod +x ./kubectl && mv ./kubectl /usr/local/bin/

    # Install eksctl
    curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
    mv /tmp/eksctl /usr/local/bin

    # Install Terraform
    apt install -y gnupg software-properties-common
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
    apt update -y && apt install -y terraform

    # Verify installations
    aws --version
    kubectl version --client
    eksctl version
    terraform version
    echo "✅ Installed awscli, kubectl, eksctl, terraform"
  EOF

  tags = {
    Name = "Private-EKS-Admin-EC2"
  }
}

###################################################
# OUTPUTS
###################################################
output "jenkins_public_ip" {
  value = aws_instance.jenkins_server.public_ip
}

output "jenkins_url" {
  value = "http://${aws_instance.jenkins_server.public_dns}:8080"
}

output "private_eks_admin_ip" {
  value = aws_instance.eks_admin_server.private_ip
}

output "ssh_from_jenkins_to_private" {
  value = "ssh -i mani.pem ubuntu@${aws_instance.eks_admin_server.private_ip}"
}
