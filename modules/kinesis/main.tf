###############################################################
# Módulo Kinesis - Streaming de Cotações ao Vivo
# Fonte: API Yahoo Finance
# Kinesis Data Stream → Kinesis Firehose → S3 SOR
###############################################################

# ---- Kinesis Data Stream ----
# Recebe cotações em tempo real da API Yahoo Finance

resource "aws_kinesis_stream" "cotacoes" {
  name             = "${var.name_prefix}-cotacoes-stream"
  shard_count      = var.shard_count
  retention_period = var.retention_hours

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  encryption_type = "KMS"
  kms_key_id      = "alias/aws/kinesis"

  tags = {
    Name        = "${var.name_prefix}-cotacoes-stream"
    Description = "Stream de cotações ao vivo - API Yahoo Finance"
  }
}

# ---- CloudWatch Log Group para Firehose ----

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.name_prefix}-firehose"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "firehose_s3" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

# ---- Kinesis Data Firehose ----
# Entrega dados do stream para o S3 (camada Bronze/SOR)

resource "aws_kinesis_firehose_delivery_stream" "to_s3" {
  name        = "${var.name_prefix}-firehose"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.cotacoes.arn
    # role_arn           = var.kinesis_role_arn
  }

  extended_s3_configuration {
    # role_arn            = var.kinesis_role_arn
    bucket_arn          = var.s3_bucket_sor_arn
    prefix              = "cotacoes-live/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "cotacoes-live-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/"
    buffering_size      = var.firehose_buffer_size_mb
    buffering_interval  = var.firehose_buffer_interval_sec
    compression_format  = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_s3.name
    }

    # Converte para Parquet via Glue (otimiza queries Athena)
    # Descomente após ter tabela Glue configurada:
    # data_format_conversion_configuration {
    #   input_format_configuration {
    #     deserializer {
    #       hive_json_ser_de {}
    #     }
    #   }
    #   output_format_configuration {
    #     serializer {
    #       parquet_ser_de {
    #         compression = "SNAPPY"
    #       }
    #     }
    #   }
    #   schema_configuration {
    #     database_name = var.glue_database_name
    #     table_name    = "cotacoes_live"
    #     role_arn      = var.kinesis_role_arn
    #   }
    # }
  }

  tags = {
    Name = "${var.name_prefix}-firehose"
  }
}

# ---- CloudWatch Alarmes para monitoramento ----

resource "aws_cloudwatch_metric_alarm" "stream_put_records_failed" {
  alarm_name          = "${var.name_prefix}-kinesis-put-failed"
  alarm_description   = "Falhas ao gravar no Kinesis Stream"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "PutRecord.Success"
  namespace           = "AWS/Kinesis"
  period              = 300
  statistic           = "Average"
  threshold           = 0.95
  treat_missing_data  = "notBreaching"

  dimensions = {
    StreamName = aws_kinesis_stream.cotacoes.name
  }
}
