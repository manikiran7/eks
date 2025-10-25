terraform {
  backend "s3" {
    bucket         = "my-terraform-state-prod-manikiran"
    key            = "vpc/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-lock-table"
    encrypt        = true
  }
}

terraform {
  required_version = ">= 1.2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

#########################
# Variables
#########################
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.100.0.0/16"
}

variable "az_count" {
  type    = number
  default = 3
}

variable "enable_vpc_endpoints" {
  type    = bool
  default = false
  description = "Enable private VPC endpoints for AWS services (optional security enhancement)"
}

provider "aws" {
  region = var.region
}

#########################
# Data
#########################
data "aws_availability_zones" "available" {
  state = "available"
}


#########################
# VPC
#########################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

###############################################
# Fix DNS attributes for existing VPC (provider ≥5.0)
###############################################
resource "null_resource" "enable_vpc_dns" {
  depends_on = [aws_vpc.main]

  provisioner "local-exec" {
    command = <<EOT
      aws ec2 modify-vpc-attribute --vpc-id ${aws_vpc.main.id} --enable-dns-support
      aws ec2 modify-vpc-attribute --vpc-id ${aws_vpc.main.id} --enable-dns-hostnames
    EOT
  }
}


#########################
# Internet Gateway
#########################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

#########################
# Public Subnets
#########################
resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 100)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                     = "${var.name_prefix}-public-${count.index}"
    "kubernetes.io/role/elb"                 = "1"
    "kubernetes.io/cluster/${var.name_prefix}-eks" = "shared"
  }
}

#########################
# Private Subnets
#########################
resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                      = "${var.name_prefix}-private-${count.index}"
    "kubernetes.io/role/internal-elb"         = "1"
    "kubernetes.io/cluster/${var.name_prefix}-eks" = "shared"
  }
}

#########################
# NAT Gateways (one per AZ)
#########################
resource "aws_eip" "nat" {
  count      = var.az_count
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "${var.name_prefix}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "nat" {
  count         = var.az_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "${var.name_prefix}-nat-${count.index}" }
}

#########################
# Route Tables
#########################
# Public Route Table (shared)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Route Tables (one per AZ -> its NAT)
resource "aws_route_table" "private" {
  count  = length(aws_subnet.private)
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }
  tags = { Name = "${var.name_prefix}-private-rt-${count.index}" }
}

resource "aws_route_table_association" "private_assoc" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

#########################
# (Optional) VPC Interface Endpoints
#########################
resource "aws_vpc_endpoint" "ecr_api" {
  count             = var.enable_vpc_endpoints ? 1 : 0
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type = "Interface"
  subnet_ids        = aws_subnet.private[*].id
  private_dns_enabled = true
  tags = { Name = "${var.name_prefix}-ecr-api-endpoint" }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  count             = var.enable_vpc_endpoints ? 1 : 0
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type = "Interface"
  subnet_ids        = aws_subnet.private[*].id
  private_dns_enabled = true
  tags = { Name = "${var.name_prefix}-ecr-dkr-endpoint" }
}

resource "aws_vpc_endpoint" "s3" {
  count             = var.enable_vpc_endpoints ? 1 : 0
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags = { Name = "${var.name_prefix}-s3-endpoint" }
}

#########################
# Outputs
#########################
output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID"
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "Public subnet IDs"
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "Private subnet IDs"
}

output "nat_gateway_ids" {
  value       = aws_nat_gateway.nat[*].id
  description = "NAT gateway IDs"
}

output "nat_eip_public_ips" {
  value       = aws_eip.nat[*].public_ip
  description = "Public Elastic IPs for NAT gateways (for whitelisting EKS or Jenkins)"
}