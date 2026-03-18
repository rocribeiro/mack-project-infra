output "historico_function_name" { value = aws_lambda_function.b3_historico.function_name }
output "historico_function_arn" { value = aws_lambda_function.b3_historico.arn }
output "historico_log_group" { value = aws_cloudwatch_log_group.historico.name }
output "historico_dlq_url" { value = aws_sqs_queue.historico_dlq.url }

output "fechamento_function_name" { value = aws_lambda_function.b3_fechamento_diario.function_name }
output "fechamento_function_arn" { value = aws_lambda_function.b3_fechamento_diario.arn }
output "fechamento_log_group" { value = aws_cloudwatch_log_group.fechamento.name }
output "fechamento_dlq_url" { value = aws_sqs_queue.fechamento_dlq.url }

output "s3_code_bucket" { value = aws_s3_bucket.lambda_b3_code.bucket }
output "layer_arn" { value = aws_lambda_layer_version.b3_deps.arn }
