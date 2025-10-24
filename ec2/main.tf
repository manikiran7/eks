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
# VARIABLES
###################################################
variable "vpc_id" {
  type        = string
  description = "VPC ID where EC2 will be launched"
  default     = "vpc-01445306434f31b95"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "List of public subnets for Jenkins EC2"
  default     = [
    "subnet-03ca852daae422e1c",
    "subnet-0d65a06dc480bb19f",
    "subnet-0f4db8d4112d46229"
  ]
}

###################################################
# SECURITY GROUP
###################################################
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-sg"
  description = "Allow SSH and Jenkins UI access"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Jenkins UI"
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
    Name = "jenkins-sg"
  }
}

###################################################
# IAM ROLE + INSTANCE PROFILE
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

# Full permissions for Jenkins to manage AWS (EKS, EC2, S3, etc.)
resource "aws_iam_role_policy_attachment" "jenkins_admin_policy" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "jenkins-instance-profile"
  role = aws_iam_role.jenkins_role.name
}

###################################################
# SINGLE EC2 INSTANCE (Jenkins + EKS Tools)
###################################################
resource "aws_instance" "jenkins_server" {
  ami                         = "ami-0c7217cdde317cfec" # Ubuntu 22.04 LTS
  instance_type               = "t2.medium"
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.jenkins_profile.name
  key_name                    = "mani"

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt update -y

    # Install essentials
    apt install -y fontconfig openjdk-21-jre git awscli unzip curl jq python3-pip gnupg software-properties-common

    # Install Jenkins
    apt install -y fontconfig openjdk-21-jre git awscli unzip
    mkdir -p /etc/apt/keyrings
    wget -O /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
    echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list
    apt update -y
    apt install -y jenkins
    systemctl enable jenkins
    systemctl start jenkins

    # Install kubectl
    curl -o kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.0/2024-07-18/bin/linux/amd64/kubectl
    chmod +x ./kubectl && mv ./kubectl /usr/local/bin/

    # Install eksctl
    curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
    mv /tmp/eksctl /usr/local/bin

    # Install Terraform
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
    apt update -y && apt install -y terraform

    echo "✅ Jenkins + Terraform + eksctl + kubectl installed successfully!"
  EOF

  tags = {
    Name = "Jenkins-EKS-Server"
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

output "ssh_command" {
  value = "ssh -i mani.pem ubuntu@${aws_instance.jenkins_server.public_ip}"
}
