###############################################################
# Módulo Lambda - Yahoo Finance → Kinesis Data Stream
###############################################################

# ─── Empacota src/handler.py em zip ──────────────────────────

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.src_path
  output_path = "${path.module}/lambda_package.zip"
  excludes    = ["__pycache__", "*.pyc", "tests", "requirements.txt"]
}

# ─── Bucket S3 para o código da Lambda ───────────────────────

resource "aws_s3_bucket" "lambda_code" {
  bucket        = "${var.name_prefix}-lambda-code"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "lambda_code" {
  bucket                  = aws_s3_bucket.lambda_code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lambda_code" {
  bucket = aws_s3_bucket.lambda_code.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "lambda_zip" {
  bucket = aws_s3_bucket.lambda_code.id
  key    = "handler.zip"
  source = data.archive_file.lambda_zip.output_path
  etag   = data.archive_file.lambda_zip.output_md5
}

# ─── CloudWatch Log Group ─────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-yahoo-to-kinesis"
  retention_in_days = 14
}

# ─── Dead Letter Queue ────────────────────────────────────────

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-lambda-yahoo-dlq"
  message_retention_seconds = 1209600
}

# ─── Lambda Layer — build via null_resource (roda no apply) ──
#
# Usa null_resource + local-exec para instalar as dependências.
# O data "archive_file" tem depends_on no null_resource, garantindo
# que a pasta já existe quando o zip for criado.
# Isso resolve o problema do data "external" que rodava no plan
# sem acesso à rede.

resource "null_resource" "build_layer" {
  triggers = {
    requirements_hash = filemd5("${var.src_path}/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "=== Instalando dependencias da Layer Yahoo Finance ==="
      rm -rf "${path.module}/_layer_build"
      mkdir -p "${path.module}/_layer_build/python"
      pip3 install \
        -r "${var.src_path}/requirements.txt" \
        -t "${path.module}/_layer_build/python" \
        --platform manylinux2014_x86_64 \
        --only-binary=:all: \
        --python-version 3.12 \
        --upgrade \
        --no-cache-dir
      COUNT=$(find "${path.module}/_layer_build/python" -maxdepth 1 -mindepth 1 | wc -l)
      echo "Pacotes instalados: $COUNT"
      if [ "$COUNT" -eq "0" ]; then
        echo "ERRO: Layer vazia apos pip install!"
        exit 1
      fi
      echo "=== Layer build concluido ==="
    EOT
  }
}

data "archive_file" "layer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/_layer_build"
  output_path = "${path.module}/lambda_layer.zip"
  depends_on  = [null_resource.build_layer]
}

resource "aws_s3_object" "layer_zip" {
  bucket = aws_s3_bucket.lambda_code.id
  key    = "layer.zip"
  source = data.archive_file.layer_zip.output_path
  etag   = data.archive_file.layer_zip.output_md5

  depends_on = [null_resource.build_layer]
}

resource "aws_lambda_layer_version" "deps" {
  layer_name          = "${var.name_prefix}-yahoo-deps"
  description         = "yfinance + pandas + requests para coleta B3"
  compatible_runtimes = ["python3.12"]

  s3_bucket        = aws_s3_bucket.lambda_code.id
  s3_key           = aws_s3_object.layer_zip.key
  source_code_hash = data.archive_file.layer_zip.output_base64sha256

  depends_on = [aws_s3_object.layer_zip]
}

# ─── Lambda Function ──────────────────────────────────────────

resource "aws_lambda_function" "yahoo_to_kinesis" {
  function_name = "${var.name_prefix}-yahoo-to-kinesis"
  description   = "Coleta cotacoes Yahoo Finance (todos ativos B3) e publica no Kinesis"

  s3_bucket        = aws_s3_bucket.lambda_code.id
  s3_key           = aws_s3_object.lambda_zip.key
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler     = "handler.lambda_handler"
  runtime     = "python3.12"
  role        = var.lambda_role_arn
  timeout     = 300
  memory_size = 1024

  layers = [aws_lambda_layer_version.deps.arn]

  environment {
    variables = {
      KINESIS_STREAM_NAME = var.kinesis_stream_name
      AWS_REGION_NAME     = var.aws_region
      KINESIS_BATCH_SIZE  = "500"
      YF_CHUNK_SIZE       = tostring(var.yf_chunk_size)
      YF_MAX_WORKERS      = tostring(var.yf_max_workers)
      FETCH_PERIOD        = var.fetch_period
      FETCH_INTERVAL      = var.fetch_interval
      TICKERS_S3_BUCKET   = var.tickers_s3_bucket
      TICKERS_S3_KEY      = "config/tickers_b3.json"
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  tracing_config {
    mode = "PassThrough"
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_s3_object.lambda_zip,
    aws_lambda_layer_version.deps,
  ]
}

# ─── EventBridge ─────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "pregao" {
  name                = "${var.name_prefix}-coleta-pregao"
  description         = "Coleta cotacoes B3 a cada 5min durante pregao (10h-18h BRT)"
  schedule_expression = "cron(*/5 13-21 ? * MON-FRI *)"
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "pregao" {
  rule      = aws_cloudwatch_event_rule.pregao.name
  target_id = "LambdaYahooToKinesis"
  arn       = aws_lambda_function.yahoo_to_kinesis.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgePregao"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.yahoo_to_kinesis.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pregao.arn
}

resource "aws_cloudwatch_event_rule" "abertura" {
  name                = "${var.name_prefix}-coleta-abertura"
  description         = "Coleta snapshot de abertura B3 (9h30 BRT)"
  schedule_expression = "cron(30 12 ? * MON-FRI *)"
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "abertura" {
  rule      = aws_cloudwatch_event_rule.abertura.name
  target_id = "LambdaYahooAbertura"
  arn       = aws_lambda_function.yahoo_to_kinesis.arn
}

resource "aws_lambda_permission" "allow_eventbridge_abertura" {
  statement_id  = "AllowEventBridgeAbertura"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.yahoo_to_kinesis.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.abertura.arn
}

# ─── CloudWatch Alarmes ───────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.name_prefix}-lambda-yahoo-errors"
  alarm_description   = "Lambda Yahoo Finance com erros consecutivos"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.yahoo_to_kinesis.function_name }
}

resource "aws_cloudwatch_metric_alarm" "lambda_timeout_risk" {
  alarm_name          = "${var.name_prefix}-lambda-yahoo-duration"
  alarm_description   = "Lambda Yahoo Finance proxima do timeout (>240s)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Average"
  threshold           = 240000
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.yahoo_to_kinesis.function_name }
}
