#############################
# FETCH VPC REMOTE STATE
#############################
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

#############################
# BACKEND & PROVIDER
#############################
terraform {
  required_version = ">= 1.2.0"

  backend "s3" {
    bucket         = "my-terraform-state-prod-manikiran"
    key            = "ec2/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-lock-table"
    encrypt        = true
  }

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

#############################
# SECURITY GROUPS
#############################
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-eks-sg"
  description = "Allow outbound + control plane access"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "jenkins-eks-sg"
  }
}

#############################
# IAM ROLE FOR EC2
#############################
resource "aws_iam_role" "jenkins_role" {
  name = "jenkins-eks-role"

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

resource "aws_iam_role_policy_attachment" "jenkins_ssm_policy" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "jenkins-eks-profile"
  role = aws_iam_role.jenkins_role.name
}

#############################
# PRIVATE EC2 (Jenkins Controller)
#############################
resource "aws_instance" "jenkins_server" {
  ami                         = "ami-0c7217cdde317cfec"
  instance_type               = "t3.medium"
  subnet_id                   = local.private_subnet_ids[0]  # Use subnet from VPC output
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.jenkins_profile.name
  key_name                    = "mani"

  user_data = <<-EOF
  #!/bin/bash
  set -e
  apt update -y
  apt install -y openjdk-21-jre git unzip curl jq python3-pip gnupg software-properties-common snapd
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip awscliv2.zip && ./aws/install
  snap install amazon-ssm-agent --classic
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x kubectl && mv kubectl /usr/local/bin/
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
  mv /tmp/eksctl /usr/local/bin/
  wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
  apt update && apt install -y terraform
  EOF

  tags = {
    Name = "EKS-Controller"
  }
}

output "ssm_session_command" {
  value = "aws ssm start-session --target ${aws_instance.jenkins_server.id}"
}

#############################
# PUBLIC EC2 (Bastion + Jenkins)
#############################
resource "aws_security_group" "bastion_sg" {
  name        = "bastion-jenkins-sg"
  description = "Allow SSH and Jenkins access"
  vpc_id      = local.vpc_id

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
    Name = "bastion-jenkins-sg"
  }
}

# Allow SSH from Bastion → Private Jenkins
resource "aws_security_group_rule" "allow_ssh_from_bastion" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.jenkins_sg.id
  source_security_group_id = aws_security_group.bastion_sg.id
}

# Bastion Host EC2
resource "aws_instance" "bastion_jenkins" {
  ami                         = "ami-0c7217cdde317cfec"
  instance_type               = "t3.medium"
  subnet_id                   = local.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.jenkins_profile.name
  key_name                    = "mani"

  tags = {
    Name = "Public-Jenkins-Bastion"
  }
}

output "bastion_public_ip" {
  value = aws_instance.bastion_jenkins.public_ip
}

output "ssh_from_bastion_to_private" {
  value = "ssh ubuntu@${aws_instance.jenkins_server.private_ip}"
}
