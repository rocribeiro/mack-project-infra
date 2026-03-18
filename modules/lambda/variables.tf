variable "name_prefix" {
  type        = string
  description = "Prefixo para nomear os recursos (ex: b3-datalake-dev)"
}

variable "environment" {
  type        = string
  description = "Ambiente (dev, staging, prod)"
}

variable "lambda_role_arn" {
  type        = string
  description = "ARN da role IAM para a Lambda (LabRole no AWS Academy)"
}

variable "kinesis_stream_name" {
  type        = string
  description = "Nome do Kinesis Data Stream — output de module.kinesis.stream_name"
}

variable "kinesis_stream_arn" {
  type        = string
  description = "ARN do Kinesis Data Stream — output de module.kinesis.stream_arn"
}

variable "tickers_s3_bucket" {
  type        = string
  description = "Bucket S3 para cache de tickers (usa o SOR) — module.s3.bucket_sor_name"
}

variable "src_path" {
  type        = string
  description = "Caminho absoluto para a pasta src/ com handler.py e requirements.txt"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "fetch_period" {
  type    = string
  default = "1d"
}

variable "fetch_interval" {
  type    = string
  default = "1m"
}

variable "yf_chunk_size" {
  type    = number
  default = 50
}

variable "yf_max_workers" {
  type    = number
  default = 8
}
