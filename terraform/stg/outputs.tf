output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this, then kubectl talks to the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "db_address" {
  description = "RDS hostname with no port. This is the externalName for the postgres Service in overlays/stg."
  value       = module.db.db_instance_address
}

output "db_endpoint" {
  description = "RDS host:port."
  value       = module.db.db_instance_endpoint
}

output "db_rds_secret_arn" {
  description = "Secrets Manager ARN holding {username, password}, created and rotated by RDS."
  value       = module.db.db_instance_master_user_secret_arn
}

output "db_password_command" {
  description = "Prints the master password, for pasting into chill-crate-secret and keycloak-secret."
  value       = "aws secretsmanager get-secret-value --secret-id ${module.db.db_instance_master_user_secret_arn} --query SecretString --output text"
}
