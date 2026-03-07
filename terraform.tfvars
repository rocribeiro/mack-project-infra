###############################################################
# Valores de Variáveis - Ambiente DEV
# Ajuste conforme seu ambiente
###############################################################

aws_region   = "us-east-1"
project_name = "b3-datalake"
environment  = "dev"

# Kinesis - menor custo para dev
kinesis_stream_shard_count           = 1
kinesis_stream_retention_hours       = 24
kinesis_firehose_buffer_size_mb      = 64
kinesis_firehose_buffer_interval_sec = 300

# Glue - menor custo para dev
glue_worker_type       = "G.1X"
glue_number_of_workers = 2
glue_max_retries       = 1

# SageMaker
sagemaker_instance_type = "ml.t3.medium"

# DMS
dms_replication_instance_class = "dms.t3.micro"

# S3 Lifecycle
s3_lifecycle_bronze_days = 90
s3_lifecycle_silver_days = 180
