###############################################################
# Módulo AWS DMS - Database Migration Service
# Ingestão das Séries Históricas B3 para o S3 (Bronze/SOR)
# Nota: Para dados B3, o DMS é usado para migrar de uma fonte
#       relacional (ex: RDS/PostgreSQL) para S3
###############################################################

# ---- Subnet Group para DMS (usa subnets padrão) ----

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_dms_replication_subnet_group" "main" {
  replication_subnet_group_id          = "${var.name_prefix}-dms-subnet-group"
  replication_subnet_group_description = "Subnet group para replicação DMS - B3 DataLake"
  subnet_ids                           = data.aws_subnets.default.ids
}

# ---- Replication Instance ----

resource "aws_dms_replication_instance" "main" {
  replication_instance_id     = "${var.name_prefix}-dms"
  replication_instance_class  = var.replication_instance_class
  allocated_storage           = 20 # GB
  publicly_accessible         = false
  multi_az                    = false
  auto_minor_version_upgrade  = true

  replication_subnet_group_id = aws_dms_replication_subnet_group.main.id

  tags = {
    Name = "${var.name_prefix}-dms-instance"
  }
}

# ---- Endpoint de Origem (S3 - para migração de arquivos CSV) ----
# Usado para ingerir os arquivos .ZIP das Séries Históricas B3
# que são baixados manualmente e colocados num bucket staging

resource "aws_dms_s3_endpoint" "source" {
  endpoint_id             = "${var.name_prefix}-dms-source-s3"
  endpoint_type           = "source"
  bucket_name             = "${var.name_prefix}-staging"
  service_access_role_arn = var.dms_role_arn

  csv_delimiter  = ";"
  csv_row_delimiter = "\n"
  ignore_headers_row = 1

  tags = {
    Name = "DMS Source - B3 CSV Files"
  }
}

# ---- Endpoint de Destino (S3 SOR - Bronze) ----

resource "aws_dms_s3_endpoint" "target" {
  endpoint_id             = "${var.name_prefix}-dms-target-s3"
  endpoint_type           = "target"
  bucket_name             = var.s3_bucket_sor_name
  bucket_folder           = "b3-series-historicas"
  service_access_role_arn = var.dms_role_arn

  # Salva em Parquet para otimizar queries
  data_format          = "parquet"
  parquet_version      = "parquet-2-0"
  compression_type     = "GZIP"
  enable_statistics    = true
  include_op_for_full_load = false

  tags = {
    Name = "DMS Target - S3 SOR (Bronze)"
  }
}

# ---- Replication Task ----

resource "aws_dms_replication_task" "b3_to_sor" {
  replication_task_id       = "${var.name_prefix}-b3-to-sor"
  replication_instance_arn  = aws_dms_replication_instance.main.replication_instance_arn
  source_endpoint_arn       = aws_dms_s3_endpoint.source.endpoint_arn
  target_endpoint_arn       = aws_dms_s3_endpoint.target.endpoint_arn
  migration_type            = "full-load"

  table_mappings = jsonencode({
    rules = [
      {
        rule-type = "selection"
        rule-id   = "1"
        rule-name = "include-all"
        object-locator = {
          schema-name = "%"
          table-name  = "%"
        }
        rule-action = "include"
      }
    ]
  })

  replication_task_settings = jsonencode({
    TargetMetadata = {
      TargetSchema       = ""
      SupportLobs        = true
      FullLobMode        = false
      LobChunkSize       = 64
      LimitedSizeLobMode = true
      LobMaxSize         = 32
    }
    FullLoadSettings = {
      TargetTablePrepMode       = "DROP_AND_CREATE"
      CreatePkAfterFullLoad     = false
      StopTaskCachedChangesApplied = false
      StopTaskCachedChangesNotApplied = false
      MaxFullLoadSubTasks       = 8
      TransactionConsistencyTimeout = 600
      CommitRate                = 50000
    }
    Logging = {
      EnableLogging = true
    }
  })

  tags = {
    Name = "B3 Séries Históricas → S3 SOR"
  }
}
