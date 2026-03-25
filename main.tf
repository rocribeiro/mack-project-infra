###############################################################
# Projeto: Solução de Consulta Financeira - B3 Data Lake
# MBA Engenharia de Dados - Universidade Presbiteriana Mackenzie
# Arquitetura: Data Lake Medallion (Bronze/Silver/Gold) na AWS
###############################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "B3-DataLake"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Team        = "MBA-Mackenzie"
    }
  }
}

###############################################################
# DATA SOURCES
###############################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "${var.project_name}-${var.environment}"
}

###############################################################
# S3 - Buckets Medallion
###############################################################

module "s3" {
  source                = "./modules/s3"
  name_prefix           = local.name_prefix
  environment           = var.environment
  account_id            = local.account_id
  lifecycle_bronze_days = var.s3_lifecycle_bronze_days
  lifecycle_silver_days = var.s3_lifecycle_silver_days
}

###############################################################
# GLUE - ETL + Data Catalog
###############################################################

module "glue" {
  source                 = "./modules/glue"
  name_prefix            = local.name_prefix
  environment            = var.environment
  glue_role_arn          = var.glue_role_arn
  s3_bucket_sor          = module.s3.bucket_sor_name
  s3_bucket_sot          = module.s3.bucket_sot_name
  s3_bucket_spec         = module.s3.bucket_spec_name
  s3_scripts_bucket      = module.s3.bucket_scripts_name
  glue_worker_type       = var.glue_worker_type
  glue_number_of_workers_silver = var.glue_number_of_workers_silver
  glue_number_of_workers_gold = var.glue_number_of_workers_gold
  glue_max_retries       = var.glue_max_retries
}

###############################################################
# KINESIS - Streaming cotações ao vivo
###############################################################

module "kinesis" {
  source                       = "./modules/kinesis"
  name_prefix                  = local.name_prefix
  environment                  = var.environment
  kinesis_role_arn             = var.kinesis_role_arn
  s3_bucket_sor_arn            = module.s3.bucket_sor_arn
  s3_bucket_sor_name           = module.s3.bucket_sor_name
  shard_count                  = var.kinesis_stream_shard_count
  retention_hours              = var.kinesis_stream_retention_hours
  firehose_buffer_size_mb      = var.kinesis_firehose_buffer_size_mb
  firehose_buffer_interval_sec = var.kinesis_firehose_buffer_interval_sec
}

###############################################################
# ATHENA - Query engine serverless
###############################################################

module "athena" {
  source             = "./modules/athena"
  name_prefix        = local.name_prefix
  environment        = var.environment
  s3_results_bucket  = module.s3.bucket_athena_results_name
  # Trocamos o nome da variável velha pela nova do SPEC:
  glue_database_name = module.glue.database_name_spec 
}
###############################################################
# SAGEMAKER - Modelagem preditiva
###############################################################

module "sagemaker" {
  source             = "./modules/sagemaker"
  name_prefix        = local.name_prefix
  environment        = var.environment
  sagemaker_role_arn = var.sagemaker_role_arn
  s3_bucket_spec     = module.s3.bucket_spec_name
  instance_type      = var.sagemaker_instance_type
}

###############################################################
# LAMBDA 1 - Yahoo Finance → Kinesis Data Stream
# Coleta todos os ~400-500 ativos ativos da B3 a cada 5min
###############################################################

module "lambda_yahoo" {
  source = "./modules/lambda"

  name_prefix         = local.name_prefix
  environment         = var.environment
  lambda_role_arn     = var.kinesis_role_arn
  kinesis_stream_name = module.kinesis.stream_name
  kinesis_stream_arn  = module.kinesis.stream_arn
  tickers_s3_bucket   = module.s3.bucket_sor_name
  src_path            = "${path.module}/src"
  aws_region          = var.aws_region
  fetch_period        = var.lambda_fetch_period
  fetch_interval      = var.lambda_fetch_interval
  yf_chunk_size       = var.lambda_yf_chunk_size
  yf_max_workers      = var.lambda_yf_max_workers
}

###############################################################
# LAMBDA 2 - Carga Histórica B3 (10 anos)
# Baixa COTAHIST_A{YYYY}.ZIP dos últimos N anos → S3 SOR
# Roda uma vez automaticamente no terraform apply
###############################################################

module "lambda_b3" {
  source = "./modules/lambda_b3"

  name_prefix         = local.name_prefix
  environment         = var.environment
  lambda_role_arn     = var.kinesis_role_arn
  s3_bucket_sor_name  = module.s3.bucket_sor_name
  s3_bucket_sor_arn   = module.s3.bucket_sor_arn
  glue_workflow_name  = module.glue.workflow_name
  src_historico_path  = "${path.module}/src_b3_historico"
  src_fechamento_path = "${path.module}/src_b3_fechamento"
  anos_historico      = var.anos_historico
  aws_region          = var.aws_region
}

# Banco relacional

# module "rds" {
#   source = "./modules/rds"

#   # Passando as variáveis da rede para o banco de dados
#   vpc_id               = module.vpc.vpc_id
#   db_subnet_group_name = module.vpc.database_subnet_group_name
# }

# 1. Pede para a AWS a VPC Padrão da conta
data "aws_vpc" "default" {
  default = true
}

# 2. Pede para a AWS as Subnets (redes menores) dentro dessa VPC Padrão
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# 3. Cria o Grupo de Subnets que o RDS exige
resource "aws_db_subnet_group" "default" {
  name       = "b3-datalake-dev-subnet-group"
  subnet_ids = data.aws_subnets.default.ids
}

# 4. Agora sim, chama o módulo do Banco de Dados passando os dados corretos!
module "rds" {
  source = "./modules/rds"

  vpc_id               = data.aws_vpc.default.id
  db_subnet_group_name = aws_db_subnet_group.default.name
}