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

  # Descomente para usar backend remoto (S3 + DynamoDB para state locking)
  # backend "s3" {
  #   bucket         = "meu-terraform-state-bucket"
  #   key            = "b3-datalake/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
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
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  name_prefix = "${var.project_name}-${var.environment}"
}

###############################################################
# MÓDULOS
###############################################################

# Módulo IAM comentado - usando roles pré-existentes do lab
# module "iam" {
#   source      = "./modules/iam"
#   name_prefix = local.name_prefix
#   account_id  = local.account_id
#   region      = local.region
#   project_name = var.project_name
#   environment  = var.environment
# }

module "s3" {
  source      = "./modules/s3"
  name_prefix = local.name_prefix
  environment = var.environment
  account_id  = local.account_id
}

module "glue" {
  source             = "./modules/glue"
  name_prefix        = local.name_prefix
  environment        = var.environment
  glue_role_arn      = var.glue_role_arn
  s3_bucket_sor      = module.s3.bucket_sor_name
  s3_bucket_sot      = module.s3.bucket_sot_name
  s3_bucket_spec     = module.s3.bucket_spec_name
  s3_scripts_bucket  = module.s3.bucket_scripts_name
}

module "kinesis" {
  source      = "./modules/kinesis"
  name_prefix = local.name_prefix
  environment = var.environment
  kinesis_role_arn   = var.kinesis_role_arn
  s3_bucket_sor_arn  = module.s3.bucket_sor_arn
  s3_bucket_sor_name = module.s3.bucket_sor_name
}

module "athena" {
  source             = "./modules/athena"
  name_prefix        = local.name_prefix
  environment        = var.environment
  s3_results_bucket  = module.s3.bucket_athena_results_name
  glue_database_name = module.glue.database_name
}

module "sagemaker" {
  source            = "./modules/sagemaker"
  name_prefix       = local.name_prefix
  environment       = var.environment
  sagemaker_role_arn = var.sagemaker_role_arn
  s3_bucket_spec    = module.s3.bucket_spec_name
}

module "dms" {
  source       = "./modules/dms"
  name_prefix  = local.name_prefix
  environment  = var.environment
  dms_role_arn = var.dms_role_arn
  s3_bucket_sor_arn  = module.s3.bucket_sor_arn
  s3_bucket_sor_name = module.s3.bucket_sor_name
}
