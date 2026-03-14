###############################################################
# Módulo Lambda B3 - Carga Histórica + Fechamento Diário
###############################################################

# ─── Bucket S3 para código das Lambdas B3 ────────────────────

resource "aws_s3_bucket" "lambda_b3_code" {
  bucket        = "${var.name_prefix}-lambda-b3-code"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "lambda_b3_code" {
  bucket                  = aws_s3_bucket.lambda_b3_code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lambda_b3_code" {
  bucket = aws_s3_bucket.lambda_b3_code.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# ─── Layer B3 — build via null_resource (roda no apply) ──────
#
# Mesmo fix do módulo lambda: usa null_resource + local-exec
# em vez de data "external" que rodava no plan sem rede.

resource "null_resource" "build_b3_layer" {
  triggers = {
    req_historico  = filemd5("${var.src_historico_path}/requirements.txt")
    req_fechamento = filemd5("${var.src_fechamento_path}/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "=== Instalando dependencias da Layer B3 ==="
      rm -rf "${path.module}/_layer_b3"
      mkdir -p "${path.module}/_layer_b3/python"
      pip3 install \
        -r "${var.src_historico_path}/requirements.txt" \
        -t "${path.module}/_layer_b3/python" \
        --platform manylinux2014_x86_64 \
        --only-binary=:all: \
        --python-version 3.12 \
        --upgrade \
        --no-cache-dir
      COUNT=$(find "${path.module}/_layer_b3/python" -maxdepth 1 -mindepth 1 | wc -l)
      echo "Pacotes instalados: $COUNT"
      if [ "$COUNT" -eq "0" ]; then
        echo "ERRO: Layer B3 vazia apos pip install!"
        exit 1
      fi
      echo "=== Layer B3 build concluido ==="
    EOT
  }
}

data "archive_file" "b3_layer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/_layer_b3"
  output_path = "${path.module}/b3_layer.zip"
  depends_on  = [null_resource.build_b3_layer]
}

resource "aws_s3_object" "b3_layer_zip" {
  bucket = aws_s3_bucket.lambda_b3_code.id
  key    = "b3_layer.zip"
  source = data.archive_file.b3_layer_zip.output_path
  etag   = data.archive_file.b3_layer_zip.output_md5

  depends_on = [null_resource.build_b3_layer]
}

resource "aws_lambda_layer_version" "b3_deps" {
  layer_name          = "${var.name_prefix}-b3-deps"
  description         = "requests + boto3 para ingestao B3"
  compatible_runtimes = ["python3.12"]

  s3_bucket        = aws_s3_bucket.lambda_b3_code.id
  s3_key           = aws_s3_object.b3_layer_zip.key
  source_code_hash = data.archive_file.b3_layer_zip.output_base64sha256

  depends_on = [aws_s3_object.b3_layer_zip]
}

# ═══════════════════════════════════════════════════════════════
# LAMBDA 1 — CARGA HISTÓRICA (10 anos)
# ═══════════════════════════════════════════════════════════════

data "archive_file" "historico_zip" {
  type        = "zip"
  source_dir  = var.src_historico_path
  output_path = "${path.module}/b3_historico.zip"
  excludes    = ["__pycache__", "*.pyc", "requirements.txt"]
}

resource "aws_s3_object" "historico_zip" {
  bucket = aws_s3_bucket.lambda_b3_code.id
  key    = "b3_historico.zip"
  source = data.archive_file.historico_zip.output_path
  etag   = data.archive_file.historico_zip.output_md5
}

resource "aws_cloudwatch_log_group" "historico" {
  name              = "/aws/lambda/${var.name_prefix}-b3-historico"
  retention_in_days = 14
}

resource "aws_sqs_queue" "historico_dlq" {
  name                      = "${var.name_prefix}-b3-historico-dlq"
  message_retention_seconds = 1209600
}

resource "aws_lambda_function" "b3_historico" {
  function_name    = "${var.name_prefix}-b3-historico"
  description      = "Carga historica B3: baixa COTAHIST dos ultimos ${var.anos_historico} anos para o S3 SOR"
  s3_bucket        = aws_s3_bucket.lambda_b3_code.id
  s3_key           = aws_s3_object.historico_zip.key
  source_code_hash = data.archive_file.historico_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  role             = var.lambda_role_arn
  timeout          = 900
  memory_size      = 1024

  layers = [aws_lambda_layer_version.b3_deps.arn]

  environment {
    variables = {
      S3_BUCKET_SOR  = var.s3_bucket_sor_name
      S3_PREFIX      = "b3-series-historicas"
      ANOS_HISTORICO = tostring(var.anos_historico)
      MAX_WORKERS    = "4"
      FORCE_DOWNLOAD = "false"
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.historico_dlq.arn
  }

  tracing_config { mode = "PassThrough" }

  depends_on = [aws_cloudwatch_log_group.historico]
}

# Dispara a carga histórica automaticamente no primeiro apply
resource "null_resource" "trigger_carga_historica" {
  triggers = {
    handler_hash = data.archive_file.historico_zip.output_md5
    anos         = var.anos_historico
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Disparando carga historica B3 (${var.anos_historico} anos) em background..."
      aws lambda invoke \
        --function-name ${aws_lambda_function.b3_historico.function_name} \
        --invocation-type Event \
        --region ${var.aws_region} \
        /dev/null
      echo "Carga historica disparada. Acompanhe em CloudWatch Logs."
    EOT
  }

  depends_on = [aws_lambda_function.b3_historico]
}

# ═══════════════════════════════════════════════════════════════
# LAMBDA 2 — FECHAMENTO DIÁRIO (ano corrente)
# ═══════════════════════════════════════════════════════════════

data "archive_file" "fechamento_zip" {
  type        = "zip"
  source_dir  = var.src_fechamento_path
  output_path = "${path.module}/b3_fechamento.zip"
  excludes    = ["__pycache__", "*.pyc", "requirements.txt"]
}

resource "aws_s3_object" "fechamento_zip" {
  bucket = aws_s3_bucket.lambda_b3_code.id
  key    = "b3_fechamento.zip"
  source = data.archive_file.fechamento_zip.output_path
  etag   = data.archive_file.fechamento_zip.output_md5
}

resource "aws_cloudwatch_log_group" "fechamento" {
  name              = "/aws/lambda/${var.name_prefix}-b3-fechamento-diario"
  retention_in_days = 14
}

resource "aws_sqs_queue" "fechamento_dlq" {
  name                      = "${var.name_prefix}-b3-fechamento-dlq"
  message_retention_seconds = 1209600
}

resource "aws_lambda_function" "b3_fechamento_diario" {
  function_name    = "${var.name_prefix}-b3-fechamento-diario"
  description      = "Atualizacao diaria B3: baixa COTAHIST do ano corrente apos fechamento do pregao"
  s3_bucket        = aws_s3_bucket.lambda_b3_code.id
  s3_key           = aws_s3_object.fechamento_zip.key
  source_code_hash = data.archive_file.fechamento_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  role             = var.lambda_role_arn
  timeout          = 600
  memory_size      = 512

  layers = [aws_lambda_layer_version.b3_deps.arn]

  environment {
    variables = {
      S3_BUCKET_SOR = var.s3_bucket_sor_name
      S3_PREFIX     = "b3-series-historicas"
      GLUE_WORKFLOW = var.glue_workflow_name
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.fechamento_dlq.arn
  }

  tracing_config { mode = "PassThrough" }

  depends_on = [aws_cloudwatch_log_group.fechamento]
}

resource "aws_cloudwatch_event_rule" "fechamento_diario" {
  name                = "${var.name_prefix}-b3-fechamento-diario"
  description         = "Atualizacao B3 apos fechamento do pregao (19h BRT / 22h UTC)"
  schedule_expression = "cron(0 22 ? * MON-FRI *)"
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "fechamento_diario" {
  rule      = aws_cloudwatch_event_rule.fechamento_diario.name
  target_id = "LambdaB3FechamentoDiario"
  arn       = aws_lambda_function.b3_fechamento_diario.arn
}

resource "aws_lambda_permission" "allow_eventbridge_fechamento" {
  statement_id  = "AllowEventBridgeFechamento"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.b3_fechamento_diario.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.fechamento_diario.arn
}

# ─── CloudWatch Alarmes ───────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "historico_errors" {
  alarm_name          = "${var.name_prefix}-b3-historico-errors"
  alarm_description   = "Lambda carga historica B3 com erros"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 900
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.b3_historico.function_name }
}

resource "aws_cloudwatch_metric_alarm" "fechamento_errors" {
  alarm_name          = "${var.name_prefix}-b3-fechamento-errors"
  alarm_description   = "Lambda fechamento diario B3 com erros"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.b3_fechamento_diario.function_name }
}
