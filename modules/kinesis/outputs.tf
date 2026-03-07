output "stream_name"    { value = aws_kinesis_stream.cotacoes.name }
output "stream_arn"     { value = aws_kinesis_stream.cotacoes.arn }
output "firehose_name"  { value = aws_kinesis_firehose_delivery_stream.to_s3.name }
output "firehose_arn"   { value = aws_kinesis_firehose_delivery_stream.to_s3.arn }
