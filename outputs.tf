###############################################################
# Outputs - B3 Data Lake
###############################################################

output "s3_bucket_sor" {
  description = "Bucket S3 - Camada Bronze (SOR - System of Record)"
  value       = module.s3.bucket_sor_name
}

output "s3_bucket_sot" {
  description = "Bucket S3 - Camada Silver (SOT - Source of Truth)"
  value       = module.s3.bucket_sot_name
}

output "s3_bucket_spec" {
  description = "Bucket S3 - Camada Gold (SPEC - Single Point of Entry for Consumers)"
  value       = module.s3.bucket_spec_name
}

output "s3_bucket_scripts" {
  description = "Bucket S3 - Scripts Glue"
  value       = module.s3.bucket_scripts_name
}

output "s3_bucket_athena_results" {
  description = "Bucket S3 - Resultados Athena"
  value       = module.s3.bucket_athena_results_name
}

output "glue_database_name" {
  description = "Nome do banco de dados no Glue Data Catalog"
  value       = module.glue.database_name
}

output "glue_job_bronze_to_silver" {
  description = "Nome do Job Glue - Bronze para Silver"
  value       = module.glue.job_bronze_to_silver_name
}

output "glue_job_silver_to_gold" {
  description = "Nome do Job Glue - Silver para Gold"
  value       = module.glue.job_silver_to_gold_name
}

output "kinesis_stream_name" {
  description = "Nome do Kinesis Data Stream (cotações ao vivo)"
  value       = module.kinesis.stream_name
}

output "kinesis_firehose_name" {
  description = "Nome do Kinesis Firehose"
  value       = module.kinesis.firehose_name
}

output "athena_workgroup" {
  description = "Nome do Workgroup Athena"
  value       = module.athena.workgroup_name
}

output "sagemaker_notebook_name" {
  description = "Nome do SageMaker Notebook Instance"
  value       = module.sagemaker.notebook_name
}

output "dms_replication_instance_arn" {
  description = "ARN da instância de replicação DMS"
  value       = module.dms.replication_instance_arn
}

output "account_id" {
  description = "AWS Account ID"
  value       = local.account_id
}

output "region" {
  description = "Região AWS utilizada"
  value       = local.region
}
