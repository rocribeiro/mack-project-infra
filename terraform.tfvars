###############################################################
# Valores - Ambiente DEV
###############################################################

aws_region   = "us-east-1"
project_name = "b3-datalake"
environment  = "dev"

# IAM Roles (AWS Academy)
glue_role_arn      = "arn:aws:iam::202521707166:role/LabRole"
kinesis_role_arn   = "arn:aws:iam::202521707166:role/LabRole"
sagemaker_role_arn = "arn:aws:iam::202521707166:role/LabRole"
athena_role_arn    = "arn:aws:iam::202521707166:role/LabRole"

# Kinesis
kinesis_stream_shard_count           = 1
kinesis_stream_retention_hours       = 24
kinesis_firehose_buffer_size_mb      = 64
kinesis_firehose_buffer_interval_sec = 300

# Glue
glue_worker_type       = "G.1X"
glue_number_of_workers = 2
glue_max_retries       = 1

# SageMaker
sagemaker_instance_type = "ml.t3.medium"

# S3 Lifecycle
s3_lifecycle_bronze_days = 90
s3_lifecycle_silver_days = 180

# Lambda Yahoo Finance
lambda_fetch_period   = "1d"
lambda_fetch_interval = "1m"
lambda_yf_chunk_size  = 50
lambda_yf_max_workers = 8

# Lambda B3 Histórico
anos_historico = 10
