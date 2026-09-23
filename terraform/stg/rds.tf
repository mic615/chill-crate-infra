# Postgres for the stg cluster. Moved out of the cluster so that a
# `terraform destroy` on EKS -- or a node group replacement -- stops being a
# data-loss event, and so backups exist at all.
#
# The API and Keycloak keep addressing the database as `postgres` via an
# ExternalName Service in overlays/stg, so neither the chart nor the Keycloak
# manifests need the RDS hostname baked in.

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

# A dedicated group for the database, rather than attaching the node group's
# own security group to RDS. The rule below is what grants access: the source
# is the node security group, so anything scheduled on those nodes can reach
# 5432 and nothing else in the VPC can.
resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds"
  description = "Postgres access from the EKS node group"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Project = "chill-crate"
    Name    = "${var.cluster_name}-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from EKS nodes"
  referenced_security_group_id = module.eks.node_security_group_id

  from_port   = 5432
  to_port     = 5432
  ip_protocol = "tcp"
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "7.2.1"

  identifier = "chill-crate-db"

  engine               = "postgres"
  engine_version       = "16"
  family               = "postgres16" # parameter group family
  major_engine_version = "16"
  instance_class       = "db.t4g.micro"

  # PostgreSQL on RDS does not use option groups at all; leaving this on makes
  # the module try to create one.
  create_db_option_group = false

  allocated_storage     = 20
  max_allocated_storage = 100 # storage autoscaling ceiling
  storage_type          = "gp3"
  storage_encrypted     = true

  # db_name matches DB_NAME in chill-crate-secret, and is what `make db-init` runs Keycloak's CREATE ROLE/DATABASE as.
  db_name  = "chillcrate"
  username = "ccadmin"
  port     = 5432

  # RDS generates the password, stores it in Secrets Manager and can rotate it,
  # so the credential never lands in Terraform state.
  manage_master_user_password = true

  create_db_subnet_group = true
  subnet_ids             = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false # stg: single AZ

  backup_retention_period = 7
  backup_window           = "09:00-10:00"
  maintenance_window      = "Mon:10:00-Mon:11:00"

  auto_minor_version_upgrade = true
  apply_immediately          = true

  # stg is disposable; without this every `terraform destroy` demands a
  # final_snapshot_identifier. Flip both for anything holding real data.
  skip_final_snapshot = true
  deletion_protection = false

  parameters = [
    {
      # The app connects with DB_SSL_MODE=require, so refuse plaintext.
      name  = "rds.force_ssl"
      value = "1"
    },
  ]

  tags = {
    Project = "chill-crate"
  }
}