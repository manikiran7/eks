###################################################
# TERRAFORM BACKEND + PROVIDER
###################################################
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

###################################################
# VARIABLES
###################################################
variable "vpc_id" {
  type        = string
  default     = "vpc-02b7ace48d47abcea"
}

variable "private_subnet_ids" {
  type        = list(string)
  default     = [
    "subnet-09e40f0c28deae1e2",
    "subnet-0b3c79932e6d1487d",
    "subnet-0decf83a78f55d8bd"
  ]
}

###################################################
# SECURITY GROUP
###################################################
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-eks-sg"
  description = "Allow Jenkins EC2 outbound access and EKS communication"
  vpc_id      = var.vpc_id

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

###################################################
# IAM ROLE + INSTANCE PROFILE (SSM + Admin)
###################################################
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

###################################################
# EC2 INSTANCE (Private, via NAT)
###################################################
resource "aws_instance" "jenkins_server" {
  ami                         = "ami-0c7217cdde317cfec" # Ubuntu 22.04 LTS
  instance_type               = "t3.medium"
  subnet_id                   = var.private_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.jenkins_profile.name
  key_name                    = "mani"

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt update -y
    apt install -y openjdk-21-jre git awscli unzip curl jq python3-pip gnupg software-properties-common snapd

    # Install SSM Agent
    snap install amazon-ssm-agent --classic
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
    systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

    # Install Jenkins
    wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list
    apt update -y && apt install -y jenkins
    systemctl enable jenkins && systemctl start jenkins

    # Install kubectl
    curl -o /usr/local/bin/kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-07-18/bin/linux/amd64/kubectl
    chmod +x /usr/local/bin/kubectl

    # Install eksctl
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
    mv /tmp/eksctl /usr/local/bin/

    # Install Terraform
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
    apt update -y && apt install -y terraform

    echo "✅ Jenkins, Terraform, eksctl, kubectl, and SSM Agent installed successfully!"
  EOF

  tags = {
    Name = "Jenkins-EKS-Controller"
  }
}

###################################################
# OUTPUTS
###################################################
output "ssm_session_command" {
  value = "aws ssm start-session --target ${aws_instance.jenkins_server.id}"
}
