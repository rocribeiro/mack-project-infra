###############################################################
# Outputs - B3 Data Lake
###############################################################

# ── Geral ─────────────────────────────────────────────────────
output "account_id" {
  value = local.account_id
}
output "region" {
  value = local.region
}

# ── S3 ────────────────────────────────────────────────────────
output "s3_bucket_sor" {
  description = "Bucket Bronze - dados brutos"
  value       = module.s3.bucket_sor_name
}
output "s3_bucket_sot" {
  description = "Bucket Silver - dados tratados"
  value       = module.s3.bucket_sot_name
}
output "s3_bucket_spec" {
  description = "Bucket Gold - dados analíticos"
  value       = module.s3.bucket_spec_name
}
output "s3_bucket_scripts" {
  description = "Bucket Scripts Glue"
  value       = module.s3.bucket_scripts_name
}
output "s3_bucket_athena_results" {
  description = "Bucket resultados Athena"
  value       = module.s3.bucket_athena_results_name
}

# ── Glue ──────────────────────────────────────────────────────
output "glue_database_name" {
  value = module.glue.database_name
}
output "glue_workflow_name" {
  value = module.glue.workflow_name
}
output "glue_job_bronze_to_silver" {
  value = module.glue.job_bronze_to_silver_name
}
output "glue_job_silver_to_gold" {
  value = module.glue.job_silver_to_gold_name
}

# ── Kinesis ───────────────────────────────────────────────────
output "kinesis_stream_name" {
  description = "Kinesis Data Stream - cotações ao vivo"
  value       = module.kinesis.stream_name
}
output "kinesis_firehose_name" {
  value = module.kinesis.firehose_name
}

# ── Athena ────────────────────────────────────────────────────
output "athena_workgroup" {
  value = module.athena.workgroup_name
}

# ── SageMaker ─────────────────────────────────────────────────
output "sagemaker_notebook_name" {
  value = module.sagemaker.notebook_name
}
output "sagemaker_notebook_url" {
  value = module.sagemaker.notebook_url
}

# ── Lambda Yahoo Finance ──────────────────────────────────────
output "lambda_yahoo_function_name" {
  description = "Lambda Yahoo Finance → Kinesis"
  value       = module.lambda_yahoo.function_name
}
output "lambda_yahoo_log_group" {
  value = module.lambda_yahoo.log_group
}

# ── Lambda B3 Histórico ───────────────────────────────────────
output "lambda_b3_historico_function_name" {
  description = "Lambda carga histórica B3 (10 anos)"
  value       = module.lambda_b3.historico_function_name
}
output "lambda_b3_historico_log_group" {
  value = module.lambda_b3.historico_log_group
}

# ── Lambda B3 Fechamento Diário ───────────────────────────────
output "lambda_b3_fechamento_function_name" {
  description = "Lambda fechamento diário B3"
  value       = module.lambda_b3.fechamento_function_name
}
output "lambda_b3_fechamento_log_group" {
  value = module.lambda_b3.fechamento_log_group
}
# ── Banco relacional RDS ───────────────────────────────
output "endereco_do_banco_spec" {
  value = module.rds.db_endpoint
}