output "database_name_sot" { value = aws_glue_catalog_database.sot.name }
output "database_name_spec" { value = aws_glue_catalog_database.spec.name }
output "job_bronze_to_silver_name" { value = aws_glue_job.bronze_to_silver.name }
output "job_silver_to_gold_name" { value = aws_glue_job.silver_to_gold.name }
output "workflow_name" { value = aws_glue_workflow.pipeline.name }
output "crawler_bronze_name" { value = aws_glue_crawler.bronze.name }
output "crawler_silver_name" { value = aws_glue_crawler.silver.name }
output "crawler_gold_name" { value = aws_glue_crawler.gold.name }
