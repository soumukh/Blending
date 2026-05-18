variable "region" {
  description = "AWS region used for the Phase 1 IaaS-only VM."
  type        = string
  default     = "us-east-1"
}

variable "ami_id" {
  description = "Optional Ubuntu 22.04 AMI override. When null, Terraform resolves the latest Canonical Jammy amd64 AMI for the selected region."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type for the DevStack host. Needs nested virtualization support."
  type        = string
  default     = "c8i.4xlarge"
}

variable "key_path" {
  description = "Path to the private SSH key used by Terraform. The .pub file is registered as an AWS key pair."
  type        = string
  default     = "../../iaas.pem"
}

variable "project_name" {
  description = "Prefix used for Phase 1 AWS resource names."
  type        = string
  default     = "mtp-iaas"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 100
}
