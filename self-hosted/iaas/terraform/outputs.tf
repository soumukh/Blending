output "vm_a_public_ip" {
  description = "Public Elastic IP of the Phase 1 IaaS-only EC2 host."
  value       = aws_eip.iaas_eip.public_ip
}

output "grafana_url" {
  description = "Grafana URL exposed through EC2 to the Nova VM."
  value       = "http://${aws_eip.iaas_eip.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus URL exposed through EC2 to the Nova VM."
  value       = "http://${aws_eip.iaas_eip.public_ip}:9090"
}

output "gob_frontend_url" {
  description = "Online Boutique frontend URL exposed through EC2 to the Nova VM."
  value       = "http://${aws_eip.iaas_eip.public_ip}:30080"
}

output "ssh_command" {
  description = "SSH command for the Phase 1 EC2 host."
  value       = "ssh -i ${var.key_path} ubuntu@${aws_eip.iaas_eip.public_ip}"
}

