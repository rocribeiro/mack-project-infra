###############################################################
# Variáveis Globais - B3 Data Lake
###############################################################

# ---- Geral ----

variable "aws_region" {
  description = "Região AWS onde os recursos serão criados"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nome do projeto (usado como prefixo nos recursos)"
  type        = string
  default     = "b3-datalake"
}

variable "environment" {
  description = "Ambiente de deploy (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "O ambiente deve ser: dev, staging ou prod."
  }
}

# ---- IAM Roles (pré-existentes no AWS Academy) ----

variable "glue_role_arn" {
  description = "ARN da role IAM para AWS Glue"
  type        = string
  default     = "arn:aws:iam::202521707166:role/LabRole"
}

variable "kinesis_role_arn" {
  description = "ARN da LabRole — usada por Kinesis, Lambda, DMS"
  type        = string
  default     = "arn:aws:iam::202521707166:role/LabRole"
}

variable "sagemaker_role_arn" {
  description = "ARN da role IAM para Amazon SageMaker"
  type        = string
  default     = "arn:aws:iam::202521707166:role/LabRole"
}

variable "athena_role_arn" {
  description = "ARN da role IAM para Amazon Athena"
  type        = string
  default     = "arn:aws:iam::202521707166:role/LabRole"
}

# ---- Kinesis ----

variable "kinesis_stream_shard_count" {
  description = "Número de shards do Kinesis Data Stream"
  type        = number
  default     = 1
}

variable "kinesis_stream_retention_hours" {
  description = "Período de retenção dos dados no stream (horas)"
  type        = number
  default     = 24
}

variable "kinesis_firehose_buffer_size_mb" {
  description = "Tamanho do buffer do Firehose em MB (1-128)"
  type        = number
  default     = 64
}

variable "kinesis_firehose_buffer_interval_sec" {
  description = "Intervalo do buffer do Firehose em segundos (60-900)"
  type        = number
  default     = 300
}

# ---- AWS Glue ----

variable "glue_worker_type" {
  description = "Tipo de worker do Glue (Standard, G.1X, G.2X)"
  type        = string
  default     = "G.1X"
}

variable "glue_number_of_workers" {
  description = "Número de workers dos jobs Glue"
  type        = number
  default     = 2
}

variable "glue_max_retries" {
  description = "Número máximo de retentativas dos jobs Glue"
  type        = number
  default     = 1
}

# ---- SageMaker ----

variable "sagemaker_instance_type" {
  description = "Tipo de instância do SageMaker Notebook"
  type        = string
  default     = "ml.t3.medium"
}

# ---- S3 ----

variable "s3_lifecycle_bronze_days" {
  description = "Dias para mover dados Bronze para S3-IA"
  type        = number
  default     = 90
}

variable "s3_lifecycle_silver_days" {
  description = "Dias para mover dados Silver para S3-IA"
  type        = number
  default     = 180
}

# ---- Lambda Yahoo Finance ----

variable "lambda_fetch_period" {
  description = "Período de busca do yfinance (1d, 5d, 1mo)"
  type        = string
  default     = "1d"
}

variable "lambda_fetch_interval" {
  description = "Granularidade das candles (1m, 5m, 15m, 1h)"
  type        = string
  default     = "1m"
}

variable "lambda_yf_chunk_size" {
  description = "Tickers por chamada yfinance (recomendado: 50)"
  type        = number
  default     = 50
}

variable "lambda_yf_max_workers" {
  description = "Threads paralelas para download (recomendado: 8)"
  type        = number
  default     = 8
}

# ---- Lambda B3 Histórico ----

variable "anos_historico" {
  description = "Quantos anos de histórico B3 carregar na carga inicial"
  type        = number
  default     = 10
}
