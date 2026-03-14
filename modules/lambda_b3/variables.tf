variable "name_prefix" {
  type        = string
  description = "Prefixo para nomear recursos (ex: b3-datalake-dev)"
}

variable "environment" {
  type        = string
  description = "Ambiente (dev, staging, prod)"
}

variable "lambda_role_arn" {
  type        = string
  description = "ARN da role IAM para as Lambdas (LabRole no AWS Academy)"
}

variable "s3_bucket_sor_name" {
  type        = string
  description = "Nome do bucket SOR (Bronze) — module.s3.bucket_sor_name"
}

variable "s3_bucket_sor_arn" {
  type        = string
  description = "ARN do bucket SOR — module.s3.bucket_sor_arn"
}

variable "glue_workflow_name" {
  type        = string
  description = "Nome do Glue Workflow a disparar após fechamento — module.glue.workflow_name"
}

variable "src_historico_path" {
  type        = string
  description = "Caminho absoluto para src_b3_historico/ com handler.py e requirements.txt"
}

variable "src_fechamento_path" {
  type        = string
  description = "Caminho absoluto para src_b3_fechamento/ com handler.py e requirements.txt"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "anos_historico" {
  type        = number
  default     = 10
  description = "Quantos anos de histórico carregar (a partir do ano atual - 1)"
}
