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
  default     = "vpc-0b479c1e5676f0f2b"
}

variable "private_subnet_ids" {
  type        = list(string)
  default     = [
    "subnet-0dad95981ac569cbe",
  "subnet-0e8ceeb56e7a5dc51",
  "subnet-0e2f77ad18bcf72ca"
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

    # Update system packages
    apt update -y
    apt install -y openjdk-21-jre git unzip curl jq python3-pip gnupg software-properties-common snapd

    # --- Install AWS CLI v2 ---
    echo "🔹 Installing AWS CLI v2..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
    aws --version

    # --- Install SSM Agent ---
    echo "🔹 Installing AWS SSM Agent..."
    snap install amazon-ssm-agent --classic
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
    systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client

# Download the official Helm install script
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify the installation
sudo mv /usr/local/bin/helm /usr/bin/helm
sudo chmod +x /usr/bin/helm



    # --- Install eksctl ---
    echo "🔹 Installing eksctl..."
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
    mv /tmp/eksctl /usr/local/bin/

    # --- Install Terraform ---
    echo "🔹 Installing Terraform..."
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
    apt update -y && apt install -y terraform

    echo "✅ Jenkins, Terraform, eksctl, kubectl, AWS CLI v2, and SSM Agent installed successfully!"

  EOF

  tags = {
    Name = "EKS-Controller"
  }
}

###################################################
# OUTPUTS
###################################################
output "ssm_session_command" {
  value = "aws ssm start-session --target ${aws_instance.jenkins_server.id}"
}


###################################################
# ADDITIONAL PUBLIC EC2 (Bastion + Jenkins + AWS CLI)
###################################################

# Public subnet variable
variable "public_subnet_id" {
  type    = string
  default = "subnet-0fe58376d1fc5f12b"
}


# Security group for Bastion (allow SSH + Jenkins access)
resource "aws_security_group" "bastion_sg" {
  name        = "bastion-jenkins-sg"
  description = "Allow SSH and Jenkins web access"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow SSH from your local IP (replace 0.0.0.0/0 for security)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow Jenkins Web UI"
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

# Allow SSH access from Bastion to Private EC2
resource "aws_security_group_rule" "allow_ssh_from_bastion" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.jenkins_sg.id
  source_security_group_id = aws_security_group.bastion_sg.id
  description              = "Allow SSH from Bastion to Private EC2"
}

# Public EC2 with Jenkins + AWS CLI v2
resource "aws_instance" "bastion_jenkins" {
  ami                         = "ami-0c7217cdde317cfec" # Ubuntu 22.04
  instance_type               = "t3.medium"
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.jenkins_profile.name
  key_name                    = "mani"

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt update -y
    apt install -y openjdk-21-jre git unzip curl jq python3-pip gnupg software-properties-common snapd

    # --- Install AWS CLI v2 ---
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
    aws --version

    # --- Install Jenkins ---
    wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list
    apt update -y && apt install -y jenkins
    systemctl enable jenkins && systemctl start jenkins

    echo "✅ Bastion Jenkins + AWS CLI ready. Use it to SSH into Private EC2."
  EOF

  tags = {
    Name = "Public-Jenkins-Bastion"
  }
}

###################################################
# OUTPUTS
###################################################
output "bastion_public_ip" {
  value = aws_instance.bastion_jenkins.public_ip
}

output "ssh_from_bastion_to_private" {
  value = "ssh ubuntu@${aws_instance.jenkins_server.private_ip}"
}
