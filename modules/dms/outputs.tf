output "replication_instance_arn" { value = aws_dms_replication_instance.main.replication_instance_arn }
output "replication_task_arn"     { value = aws_dms_replication_task.b3_to_sor.replication_task_arn }
