###############################################################
# Módulo SageMaker - Modelagem Preditiva
# Notebook para desenvolvimento de modelos de:
# - Recomendação de carteira por perfil de risco
# - Predição de churn de investidores
###############################################################

# ---- SageMaker Notebook Instance ----

resource "aws_sagemaker_notebook_instance" "main" {
  name                    = "${var.name_prefix}-notebook"
  # role_arn                = var.sagemaker_role_arn
  instance_type           = var.instance_type
  volume_size             = 20 # GB
  direct_internet_access  = "Enabled"
  root_access             = "Enabled"

  default_code_repository = null

  lifecycle_config_name = aws_sagemaker_notebook_instance_lifecycle_configuration.main.name

  tags = {
    Name        = "${var.name_prefix}-notebook"
    Description = "Notebook SageMaker para modelagem preditiva B3"
  }
}

# ---- Lifecycle Config - auto-stop para economizar custo ----

resource "aws_sagemaker_notebook_instance_lifecycle_configuration" "main" {
  name = "${var.name_prefix}-lifecycle"

  # Script executado ao iniciar o notebook (instala libs)
  on_start = base64encode(<<-EOF
    #!/bin/bash
    set -e
    sudo -u ec2-user -i <<'SCRIPT'
    source activate python3
    pip install yfinance pandas-ta scikit-learn xgboost shap boto3 awswrangler plotly
    SCRIPT
  EOF
  )
}

# ---- SageMaker Domain (Studio) - opcional para equipes ----
# Descomente se quiser usar SageMaker Studio ao invés de Notebook Instance

# resource "aws_sagemaker_domain" "main" {
#   domain_name = "${var.name_prefix}-studio"
#   auth_mode   = "IAM"
#   vpc_id      = var.vpc_id
#   subnet_ids  = var.subnet_ids
#
#   default_user_settings {
#     execution_role = var.sagemaker_role_arn
#   }
# }

# ---- CloudWatch para monitorar uso do Notebook ----

resource "aws_cloudwatch_metric_alarm" "notebook_running" {
  alarm_name          = "${var.name_prefix}-sagemaker-notebook-running"
  alarm_description   = "Alerta: Notebook SageMaker está rodando (custo ativo)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/SageMaker"
  period              = 3600 # 1 hora
  statistic           = "Average"
  threshold           = 0

  dimensions = {
    NotebookInstanceName = aws_sagemaker_notebook_instance.main.name
  }
}
