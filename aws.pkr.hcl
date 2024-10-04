packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }

    amazon-ami-management = {
      version = "= 1.5.0"
      source = "github.com/wata727/amazon-ami-management"
    }
  }
}

variable "ami_name_prefix" {
  type    = string
  default = "spacelift-{{timestamp}}"
}

variable "ami_regions" {
  type = list(string)
  default = [
    "eu-central-2"
    # "ap-northeast-1",
    # "ap-northeast-2",
    # "ap-northeast-3",
    # "ap-southeast-1",
    # "ap-southeast-2",
    # "ap-south-1",
    # "ca-central-1",
    # "eu-central-1",
    # "eu-west-1",
    # "eu-west-2",
    # "eu-west-3",
    # "eu-north-1",
    # "sa-east-1",
    # "us-east-1",
    # "us-east-2",
    # "us-west-1",
    # "us-west-2",
  ]
}

variable "source_ami_architecture" {
  type = string
  default = "x86_64"
}

variable "source_ami_owners" {
  type    = list(string)
  default = ["084269151793"] # 137112412989 defaults to Amazon for Amazon Linux, see https://docs.aws.amazon.com/AmazonECR/latest/userguide/amazon_linux_container_image.html
}

variable "ami_users" {
  type    = list(string)
  default = null # account ids to share image
}

variable "ami_groups" {
  type    = list(string)
  default = null # ["all"] will share publicly
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "encrypt_boot" {
  type    = bool
  default = true
}

variable "shared_credentials_file" {
  type    = string
  default = null
}

variable "subnet_filter" {
  type    = map(string)
  default = { "tag:Name" : "*-public-*" }
}

variable "additional_tags" {
  type    = map(string)
  default = {}
}

variable "region" {
  type    = string
  default = "eu-central-2"
}

variable "vpc_filter" {
  type    = map(string)
  default = { "tag:Name" : "*-vpc" }
}

source "amazon-ebs" "spacelift" {
  source_ami_filter {
      filters = {
        virtualization-type = "hvm"
        name                = "al2023-ami-minimal-*-kernel-6.1-${var.source_ami_architecture}"
        root-device-type    = "ebs"
        architecture        = var.source_ami_architecture
      }
      owners      = var.source_ami_owners
      most_recent = true
  }

  ami_name    = "${var.ami_name_prefix}-${var.source_ami_architecture}"
  ami_regions = var.ami_regions
  ami_groups  = var.ami_groups
  ami_description = <<EOT
Spacelift AMI built for ${var.source_ami_architecture}-based private worker pools.
It contains all the neccessary tools to run Spacelift workers.
More information: https://docs.spacelift.io.
EOT

  shared_credentials_file = var.shared_credentials_file
  encrypt_boot            = var.encrypt_boot
  instance_type           = var.instance_type
  ssh_username            = "ec2-user"
  # ssh_username            = "ssm-user"
  # ssh_interface           = "session_manager"
  # communicator            = "ssh"

  # temporary_iam_instance_profile_policy_document {
  #   Version = "2012-10-17"
  #   Statement {
  #     Effect = "Allow"
  #     Action = [
  #       "ssm:DescribeAssociation",
  #       "ssm:GetDeployablePatchSnapshotForInstance",
  #       "ssm:GetDocument",
  #       "ssm:DescribeDocument",
  #       "ssm:GetManifest",
  #       "ssm:GetParameter",
  #       "ssm:GetParameters",
  #       "ssm:ListAssociations",
  #       "ssm:ListInstanceAssociations",
  #       "ssm:PutInventory",
  #       "ssm:PutComplianceItems",
  #       "ssm:PutConfigurePackageResult",
  #       "ssm:UpdateAssociationStatus",
  #       "ssm:UpdateInstanceAssociationStatus",
  #       "ssm:UpdateInstanceInformation"
  #     ]
  #     Resource = ["*"]
  #   }
  #   Statement {
  #     Effect = "Allow"
  #     Action = [
  #       "ssmmessages:CreateControlChannel",
  #       "ssmmessages:CreateDataChannel",
  #       "ssmmessages:OpenControlChannel",
  #       "ssmmessages:OpenDataChannel"
  #     ]
  #     Resource = ["*"]
  #   }
  #   Statement {
  #     Effect = "Allow"
  #     Action = [
  #       "ec2messages:AcknowledgeMessage",
  #       "ec2messages:DeleteMessage",
  #       "ec2messages:FailMessage",
  #       "ec2messages:GetEndpoint",
  #       "ec2messages:GetMessages",
  #       "ec2messages:SendReply"
  #     ]
  #     Resource = ["*"]
  #   }
  # }

  region = var.region

  deprecate_at = timeadd(timestamp(), "8736h") # 52 weeks (1 year)

  dynamic "vpc_filter" {
    for_each = var.vpc_filter == null ? [] : [1]
    content {
      filters = var.vpc_filter
    }
  }

  dynamic "subnet_filter" {
    for_each = var.subnet_filter == null ? [] : [1]
    content {
      filters   = var.subnet_filter
      most_free = true
      random    = false
    }
  }

  tags = merge(var.additional_tags, {
    Architecture = var.source_ami_architecture
    Name         = "Spacelift AMI"
    Purpose      = "Spacelift"
    BaseAMI      = "{{ .SourceAMI }}"
  })
}

build {
  sources = ["source.amazon-ebs.spacelift"]

  provisioner "file" {
    source      = "aws/configs/"
    destination = "/tmp"
  }

  provisioner "shell" {
    scripts = [
      "shared/scripts/data-directories.sh",
      "aws/scripts/dnf-update.sh",
      "aws/scripts/system-deps.sh",
      "aws/scripts/docker.sh",
      "shared/scripts/gvisor.sh",
      "aws/scripts/cloudwatch-agent.sh",
      "aws/scripts/ssm-agent.sh"
    ]
  }

  post-processor "amazon-ami-management" {
    # Deregister old AMIs, keep only the latest 5.
    regions = var.ami_regions
    tags = {
      Name = "Spacelift AMI"
    }
    keep_releases = 5
  }

  post-processor "manifest" {
    output = "manifest_aws_${var.source_ami_architecture}.json"
  }
}
