###############################################################
# Módulo Lambda - Yahoo Finance → Kinesis Data Stream
# 
# O módulo empacota o handler.py direto da pasta src/
# sem precisar de null_resource ou build externo — usa apenas
# o archive_file do Terraform para zipar e fazer upload.
#
# LabRole do AWS Academy já tem permissões amplas, então
# não criamos IAM roles aqui (apenas reutilizamos kinesis_role_arn).
###############################################################

# ─── Empacota src/handler.py em zip ──────────────────────────

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.src_path
  output_path = "${path.module}/lambda_package.zip"
  excludes    = ["__pycache__", "*.pyc", "tests"]
}

# ─── Bucket S3 exclusivo para o pacote da Lambda ─────────────
# (o código .zip fica aqui; os dados de tickers ficam no SOR)

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

# Faz upload do zip para o S3 (permite versionamento do código)
resource "aws_s3_object" "lambda_zip" {
  bucket = aws_s3_bucket.lambda_code.id
  key    = "handler.zip"
  source = data.archive_file.lambda_zip.output_path
  etag   = data.archive_file.lambda_zip.output_md5
}

# ─── CloudWatch Log Group (criado antes da Lambda) ───────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-yahoo-to-kinesis"
  retention_in_days = 14
}

# ─── Dead Letter Queue ────────────────────────────────────────

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-lambda-yahoo-dlq"
  message_retention_seconds = 1209600 # 14 dias
}

# ─── Lambda Function ──────────────────────────────────────────

resource "aws_lambda_function" "yahoo_to_kinesis" {
  function_name = "${var.name_prefix}-yahoo-to-kinesis"
  description   = "Coleta cotações Yahoo Finance (todos ativos B3) e publica no Kinesis"

  # Código via S3 (mais estável que upload direto no Academy)
  s3_bucket        = aws_s3_bucket.lambda_code.id
  s3_key           = aws_s3_object.lambda_zip.key
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler     = "handler.lambda_handler"
  runtime     = "python3.12"
  role        = var.lambda_role_arn
  timeout     = 300   # 5 min — necessário para ~500 tickers em paralelo
  memory_size = 1024  # pandas + yfinance + 8 threads simultâneas

  # Dependências (yfinance, pandas, requests) são instaladas via Lambda Layer
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
    mode = "PassThrough" # X-Ray desativado no Academy (sem permissão)
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_s3_object.lambda_zip,
  ]
}

# ─── Lambda Layer — dependências Python ──────────────────────
# O layer é gerado com um script de build que roda via null_resource.
# Se estiver no CloudShell, o pip já está disponível.

resource "null_resource" "build_layer" {
  # Reconstrói a layer sempre que o requirements.txt mudar
  triggers = {
    requirements_hash = filemd5("${var.src_path}/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Instalando dependências da Lambda Layer..."
      rm -rf ${path.module}/_layer_build/python
      mkdir -p ${path.module}/_layer_build/python
      pip install \
        -r ${var.src_path}/requirements.txt \
        -t ${path.module}/_layer_build/python \
        --quiet \
        --platform manylinux2014_x86_64 \
        --only-binary=:all: \
        --python-version 3.12
      echo "Layer build concluído."
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

# ─── EventBridge — schedule de execução ──────────────────────

# Coleta a cada 5 minutos durante o pregão B3
# Horário do pregão: 10h–18h BRT = 13h–21h UTC (dias úteis)
resource "aws_cloudwatch_event_rule" "pregao" {
  name                = "${var.name_prefix}-coleta-pregao"
  description         = "Coleta cotações B3 a cada 5min durante pregão (10h-18h BRT)"
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

# Coleta extra na abertura do pregão (9h30 BRT = 12h30 UTC)
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

  dimensions = {
    FunctionName = aws_lambda_function.yahoo_to_kinesis.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_timeout_risk" {
  alarm_name          = "${var.name_prefix}-lambda-yahoo-duration"
  alarm_description   = "Lambda Yahoo Finance próxima do timeout (>240s)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Average"
  threshold           = 240000 # ms
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.yahoo_to_kinesis.function_name
  }
}
