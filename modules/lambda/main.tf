###############################################################
# Módulo Lambda - Yahoo Finance → Kinesis Data Stream
###############################################################

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.src_path
  output_path = "${path.module}/lambda_package.zip"
  excludes    = ["__pycache__", "*.pyc", "tests", "requirements.txt"]
}

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
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_object" "lambda_zip" {
  bucket = aws_s3_bucket.lambda_code.id
  key    = "handler.zip"
  source = data.archive_file.lambda_zip.output_path
  etag   = data.archive_file.lambda_zip.output_md5
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-yahoo-to-kinesis"
  retention_in_days = 14
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-lambda-yahoo-dlq"
  message_retention_seconds = 1209600
}

# ─── Lambda Layer ─────────────────────────────────────────────
# Usa /tmp para o build — tem mais espaço que o home do Cloud Shell.
# yfinance puxa pandas automaticamente (~150MB descompactado),
# por isso o build precisa de espaço temporário fora do home (1GB).

resource "null_resource" "build_yahoo_layer" {
  triggers = {
    req_hash = filemd5("${var.src_path}/requirements.txt")
    bucket   = aws_s3_bucket.lambda_code.bucket
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e

      SRC_DIR="$(realpath "${var.src_path}")"
      BUILD="/tmp/yahoo_layer_build_$$"
      ZIP="/tmp/yahoo_layer_$$.zip"
      BUCKET="${aws_s3_bucket.lambda_code.bucket}"

      echo ">> Build dir: $BUILD"
      echo ">> Espaco /tmp:"
      df -h /tmp

      rm -rf "$BUILD"
      mkdir -p "$BUILD/python"

      echo ">> Instalando pacotes Yahoo Finance..."
      pip3 install \
        -r "$SRC_DIR/requirements.txt" \
        -t "$BUILD/python" \
        --platform manylinux2014_x86_64 \
        --only-binary=:all: \
        --python-version 3.12 \
        --upgrade \
        --no-cache-dir

      N=$(ls "$BUILD/python" | wc -l)
      echo ">> $N pacotes instalados"
      [ "$N" -gt 0 ] || { echo "ERRO: layer vazia!"; rm -rf "$BUILD"; exit 1; }

      echo ">> Criando zip..."
      (cd "$BUILD" && zip -r "$ZIP" python/ -q)
      echo ">> Zip: $(du -sh $ZIP | cut -f1)"

      echo ">> Upload para s3://$BUCKET/layer.zip"
      aws s3 cp "$ZIP" "s3://$BUCKET/layer.zip"

      echo ">> Limpando /tmp..."
      rm -rf "$BUILD" "$ZIP"
      echo ">> Concluido"
    EOT
  }

  depends_on = [aws_s3_bucket.lambda_code]
}

resource "aws_lambda_layer_version" "deps" {
  layer_name          = "${var.name_prefix}-yahoo-deps"
  description         = "yfinance + requests + boto3"
  compatible_runtimes = ["python3.12"]
  s3_bucket           = aws_s3_bucket.lambda_code.bucket
  s3_key              = "layer.zip"
  depends_on          = [null_resource.build_yahoo_layer]
}

resource "aws_lambda_function" "yahoo_to_kinesis" {
  function_name    = "${var.name_prefix}-yahoo-to-kinesis"
  description      = "Coleta cotacoes Yahoo Finance e publica no Kinesis"
  s3_bucket        = aws_s3_bucket.lambda_code.id
  s3_key           = aws_s3_object.lambda_zip.key
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  role             = var.lambda_role_arn
  timeout          = 300
  memory_size      = 1024
  layers           = [aws_lambda_layer_version.deps.arn]

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

  dead_letter_config { target_arn = aws_sqs_queue.dlq.arn }
  tracing_config { mode = "PassThrough" }
  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_lambda_layer_version.deps,
  ]
}

resource "aws_cloudwatch_event_rule" "pregao" {
  name                = "${var.name_prefix}-coleta-pregao"
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

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.name_prefix}-lambda-yahoo-errors"
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
