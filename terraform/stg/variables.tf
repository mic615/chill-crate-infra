variable "aws_region" {
  type        = string
  description = "AWS region to use for resources."
  default     = "us-west-2"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name."
  default     = "chill-crate-stg"
}

variable "vpc_name" {
  type        = string
  description = "VPC name."
  default     = "chill-crate-stg-vpc"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block"
  default     = "10.123.0.0/16"
}

variable "vpc_azs" {
  type        = list(string)
  description = "List of availability zones where resources will be deployed."
  default     = ["us-west-2a", "us-west-2b"]
}

variable "public_subnets" {
  type        = list(string)
  description = "List of public subnets."
  default     = ["10.123.1.0/24", "10.123.2.0/24"]
}

variable "private_subnets" {
  type        = list(string)
  description = "List of private subnets."
  default     = ["10.123.3.0/24", "10.123.4.0/24"]
}
