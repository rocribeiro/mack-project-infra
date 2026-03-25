# modules/rds/variables.tf

variable "vpc_id" {
  description = "ID da VPC principal"
  type        = string
}

variable "db_subnet_group_name" {
  description = "Nome do subnet group do banco de dados"
  type        = string
}