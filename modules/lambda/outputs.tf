output "function_name" { value = aws_lambda_function.yahoo_to_kinesis.function_name }
output "function_arn" { value = aws_lambda_function.yahoo_to_kinesis.arn }
output "log_group" { value = aws_cloudwatch_log_group.lambda.name }
output "dlq_url" { value = aws_sqs_queue.dlq.url }
output "layer_arn" { value = aws_lambda_layer_version.deps.arn }
output "s3_code_bucket" { value = aws_s3_bucket.lambda_code.bucket }
