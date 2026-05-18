provider "aws" {
  region = var.region
}

data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "mtp_iaas" {
  key_name   = "${var.project_name}-key"
  public_key = file("${var.key_path}.pub")

  tags = {
    Name  = "${var.project_name}-key"
    Phase = "phase1"
  }
}

resource "aws_instance" "iaas_vm" {
  ami                    = coalesce(var.ami_id, data.aws_ami.ubuntu_2204.id)
  instance_type          = var.instance_type
  key_name               = aws_key_pair.mtp_iaas.key_name
  source_dest_check      = false
  vpc_security_group_ids = [aws_security_group.iaas_sg.id]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name  = "${var.project_name}-vm-a"
    Phase = "phase1"
  }
}

resource "aws_eip" "iaas_eip" {
  domain   = "vpc"
  instance = aws_instance.iaas_vm.id

  depends_on = [terraform_data.iaas_nested_virtualization]

  tags = {
    Name  = "${var.project_name}-eip"
    Phase = "phase1"
  }
}

resource "terraform_data" "iaas_nested_virtualization" {
  triggers_replace = [
    aws_instance.iaas_vm.id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws ec2 stop-instances --region ${var.region} --instance-ids ${aws_instance.iaas_vm.id}
      aws ec2 wait instance-stopped --region ${var.region} --instance-ids ${aws_instance.iaas_vm.id}
      aws ec2 modify-instance-cpu-options --region ${var.region} --instance-id ${aws_instance.iaas_vm.id} --nested-virtualization enabled
      aws ec2 start-instances --region ${var.region} --instance-ids ${aws_instance.iaas_vm.id}
      aws ec2 wait instance-status-ok --region ${var.region} --instance-ids ${aws_instance.iaas_vm.id}
    EOT
  }
}

resource "terraform_data" "iaas_setup" {
  triggers_replace = [
    aws_instance.iaas_vm.id,
    aws_eip.iaas_eip.public_ip,
    terraform_data.iaas_nested_virtualization.id,
  ]

  depends_on = [terraform_data.iaas_nested_virtualization]

  provisioner "remote-exec" {
    inline = [
      "rm -rf /home/ubuntu/scripts /home/ubuntu/k8s",
      "mkdir -p /home/ubuntu"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = aws_eip.iaas_eip.public_ip
      timeout     = "10m"
    }
  }

  provisioner "file" {
    source      = "../scripts"
    destination = "/home/ubuntu/scripts"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = aws_eip.iaas_eip.public_ip
      timeout     = "10m"
    }
  }

  provisioner "file" {
    source      = "../k8s"
    destination = "/home/ubuntu/k8s"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = aws_eip.iaas_eip.public_ip
      timeout     = "10m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/ubuntu/scripts/*.sh",
      "bash -o pipefail -c 'bash /home/ubuntu/scripts/master_setup.sh 2>&1 | tee /home/ubuntu/setup.log'"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.key_path)
      host        = aws_eip.iaas_eip.public_ip
      timeout     = "10m"
    }
  }
}
