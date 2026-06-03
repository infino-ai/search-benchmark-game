terraform {
  required_version = ">= 1.5"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    tls   = { source = "hashicorp/tls", version = "~> 4.0" }
    http  = { source = "hashicorp/http", version = "~> 3.0" }
    local = { source = "hashicorp/local", version = "~> 2.0" }
  }
}

provider "aws" {
  region = var.region

  # Applied to every taggable resource (instance, key pair, security group).
  default_tags {
    tags = {
      Environment = "staging"
    }
  }
}

# --- variables -------------------------------------------------------------

variable "region" {
  description = "us-east-1 matches turbopuffer's published environment."
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Match turbopuffer's published box."
  default     = "c7i.2xlarge" # 8 vCPU, 16 GiB
}

variable "volume_size_gb" {
  description = "Root disk: corpus (~8 GB) + 3 engine indexes + scratch."
  default     = 120
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH. Empty => auto-detect your current public IP."
  default     = ""
}

# --- lookups ---------------------------------------------------------------

# Latest Amazon Linux 2023 x86_64 AMI (c7i is x86_64).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Auto-detect the caller's public IP unless ssh_cidr is set.
data "http" "myip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  ssh_cidr = var.ssh_cidr != "" ? var.ssh_cidr : "${chomp(data.http.myip.response_body)}/32"
}

# --- generated SSH key -----------------------------------------------------

resource "tls_private_key" "bench" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "bench" {
  key_name_prefix = "sbg-bench-"
  public_key      = tls_private_key.bench.public_key_openssh
}

resource "local_sensitive_file" "pem" {
  content         = tls_private_key.bench.private_key_openssh
  filename        = "${path.module}/sbg-bench-key.pem"
  file_permission = "0400"
}

# --- network ---------------------------------------------------------------

resource "aws_security_group" "bench" {
  name_prefix = "sbg-bench-"
  description = "search-benchmark-game bench box (SSH only)"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- instance --------------------------------------------------------------

resource "aws_instance" "bench" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.bench.key_name
  vpc_security_group_ids      = [aws_security_group.bench.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.volume_size_gb
    volume_type = "gp3"
  }

  # Pre-install system build deps on boot. Rust + JDK are installed per-user
  # by scripts/setup-aws.sh after you SSH in.
  user_data = <<-EOF
    #!/bin/bash
    dnf install -y git make gcc gcc-c++ cmake clang bzip2 python3 unzip
  EOF

  tags = { Name = "sbg-bench" }
}

# --- outputs ---------------------------------------------------------------

output "public_ip" {
  value = aws_instance.bench.public_ip
}

output "ssh" {
  value = "ssh -i ${local_sensitive_file.pem.filename} ec2-user@${aws_instance.bench.public_ip}"
}
