output "vm_b_public_ip" {
  description = "Public Elastic IP of the Phase 3 hybrid EC2 host."
  value       = aws_eip.hybrid_eip.public_ip
}

output "grafana_url" {
  description = "Grafana URL exposed through EC2 to the Nova VM."
  value       = "http://${aws_eip.hybrid_eip.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus URL exposed through EC2 to the Nova VM."
  value       = "http://${aws_eip.hybrid_eip.public_ip}:9090"
}

output "openfaas_url" {
  description = "OpenFaaS gateway URL exposed through EC2 to the Nova VM."
  value       = "http://${aws_eip.hybrid_eip.public_ip}:8080"
}

output "registry_url" {
  description = "Local Docker registry URL exposed through EC2 to the Nova VM."
  value       = "${aws_eip.hybrid_eip.public_ip}:30500"
}

output "gob_frontend_url" {
  description = "Online Boutique frontend URL exposed through EC2 to the Nova VM."
  value       = "http://${aws_eip.hybrid_eip.public_ip}:30080"
}

output "ssh_command" {
  description = "SSH command for the Phase 3 EC2 host."
  value       = "ssh -i ${var.key_path} ubuntu@${aws_eip.hybrid_eip.public_ip}"
}

