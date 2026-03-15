###############################################################
# Módulo AWS Glue - ETL e Data Catalog
# Jobs: Bronze→Silver e Silver→Gold
###############################################################

# ---- Glue Data Catalog Database ----

resource "aws_glue_catalog_database" "main" {
  name        = replace("${var.name_prefix}_catalog", "-", "_")
  description = "Catálogo de dados B3 - Séries Históricas e Cotações"
}

# ---- Crawlers para catalogar os dados ----

resource "aws_glue_crawler" "bronze" {
  database_name = aws_glue_catalog_database.main.name
  name          = "${var.name_prefix}-crawler-bronze"
  role          = var.glue_role_arn
  description   = "Crawler para camada Bronze (SOR) - dados brutos B3"

  s3_target {
    path = "s3://${var.s3_bucket_sor}/b3-series-historicas/"
  }

  s3_target {
    path = "s3://${var.s3_bucket_sor}/cotacoes-live/"
  }

  schedule = "cron(0 6 * * ? *)" # Executa diariamente às 6h UTC

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })
}

resource "aws_glue_crawler" "silver" {
  database_name = aws_glue_catalog_database.main.name
  name          = "${var.name_prefix}-crawler-silver"
  role          = var.glue_role_arn
  description   = "Crawler para camada Silver (SOT) - dados tratados"

  s3_target {
    path = "s3://${var.s3_bucket_sot}/"
  }

  schedule = "cron(0 8 * * ? *)" # Executa após job bronze→silver
}

resource "aws_glue_crawler" "gold" {
  database_name = aws_glue_catalog_database.main.name
  name          = "${var.name_prefix}-crawler-gold"
  role          = var.glue_role_arn
  description   = "Crawler para camada Gold (SPEC) - dados analíticos"

  s3_target {
    path = "s3://${var.s3_bucket_spec}/"
  }

  schedule = "cron(0 10 * * ? *)" # Executa após job silver→gold
}

# ---- Job Glue: Bronze → Silver ----
# Limpeza, padronização e tratamento dos dados B3

resource "aws_glue_job" "bronze_to_silver" {
  name              = "${var.name_prefix}-bronze-to-silver"
  role_arn          = var.glue_role_arn
  description       = "ETL: dados brutos B3 (Bronze/SOR) → dados tratados (Silver/SOT)"
  glue_version      = "4.0"
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  max_retries       = var.glue_max_retries
  timeout           = 60 # minutos

  command {
    name            = "glueetl"
    script_location = "s3://${var.s3_scripts_bucket}/scripts/bronze_to_silver.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${var.s3_scripts_bucket}/spark-logs/"
    "--SOURCE_BUCKET"                    = var.s3_bucket_sor
    "--TARGET_BUCKET"                    = var.s3_bucket_sot
    "--DATABASE_NAME"                    = aws_glue_catalog_database.main.name
    "--TempDir"                          = "s3://${var.s3_scripts_bucket}/temp/"
  }

  execution_property {
    max_concurrent_runs = 1
  }
}

# ---- Job Glue: Silver → Gold ----
# Agregações, indicadores, features para ML

resource "aws_glue_job" "silver_to_gold" {
  name              = "${var.name_prefix}-silver-to-gold"
  role_arn          = var.glue_role_arn
  description       = "ETL: dados tratados (Silver/SOT) → dados analíticos e features (Gold/SPEC)"
  glue_version      = "4.0"
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  max_retries       = var.glue_max_retries
  timeout           = 90 # minutos

  command {
    name            = "glueetl"
    script_location = "s3://${var.s3_scripts_bucket}/scripts/silver_to_gold.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--SOURCE_BUCKET"                    = var.s3_bucket_sot
    "--TARGET_BUCKET"                    = var.s3_bucket_spec
    "--DATABASE_NAME"                    = aws_glue_catalog_database.main.name
    "--TempDir"                          = "s3://${var.s3_scripts_bucket}/temp/"
  }

  execution_property {
    max_concurrent_runs = 1
  }
}

# ---- Glue Workflow (Orquestração dos Jobs) ----

resource "aws_glue_workflow" "pipeline" {
  name        = "${var.name_prefix}-pipeline"
  description = "Pipeline completo: Ingestão → Bronze → Silver → Gold"
}

resource "aws_glue_trigger" "start_crawl_bronze" {
  name          = "${var.name_prefix}-trigger-crawl-bronze"
  type          = "SCHEDULED"
  schedule      = "cron(0 5 * * ? *)"
  workflow_name = aws_glue_workflow.pipeline.name

  actions {
    crawler_name = aws_glue_crawler.bronze.name
  }
}

resource "aws_glue_trigger" "bronze_to_silver_trigger" {
  name          = "${var.name_prefix}-trigger-bronze-silver"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.pipeline.name

  predicate {
    conditions {
      crawler_name = aws_glue_crawler.bronze.name
      crawl_state  = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.bronze_to_silver.name
  }
}

resource "aws_glue_trigger" "silver_to_gold_trigger" {
  name          = "${var.name_prefix}-trigger-silver-gold"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.pipeline.name

  predicate {
    conditions {
      job_name = aws_glue_job.bronze_to_silver.name
      state    = "SUCCEEDED"
    }
  }

  actions {
    job_name = aws_glue_job.silver_to_gold.name
  }
}

# ---- Tabelas no Glue Catalog para dados B3 ----

resource "aws_glue_catalog_table" "b3_series_historicas" {
  name          = "b3_series_historicas_bronze"
  database_name = aws_glue_catalog_database.main.name
  description   = "Séries históricas B3 - Camada Bronze (SOR)"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"         = "csv"
    "skip.header.line.count" = "1"
    "delimiter"              = ";"
  }

  storage_descriptor {
    location      = "s3://${var.s3_bucket_sor}/b3-series-historicas/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
      parameters = {
        "field.delim" = ";"
      }
    }

    # Campos do layout B3 (série histórica)
    columns {
      name    = "tipo_registro"
      type    = "string"
      comment = "Tipo de registro (01=cabeçalho, 02=detalhe, 99=trailer)"
    }
    columns {
      name    = "datpre"
      type    = "string"
      comment = "Data do pregão (YYYYMMDD)"
    }
    columns {
      name    = "codbdi"
      type    = "string"
      comment = "Código BDI"
    }
    columns {
      name    = "codneg"
      type    = "string"
      comment = "Código de negociação (ticker)"
    }
    columns {
      name    = "tpmerc"
      type    = "string"
      comment = "Tipo de mercado"
    }
    columns {
      name    = "nomres"
      type    = "string"
      comment = "Nome resumido da empresa"
    }
    columns {
      name    = "especi"
      type    = "string"
      comment = "Especificação do papel"
    }
    columns {
      name    = "prazot"
      type    = "string"
      comment = "Prazo em dias do mercado a termo"
    }
    columns {
      name    = "modref"
      type    = "string"
      comment = "Moeda de referência"
    }
    columns {
      name    = "preabe"
      type    = "double"
      comment = "Preço de abertura"
    }
    columns {
      name    = "premax"
      type    = "double"
      comment = "Preço máximo"
    }
    columns {
      name    = "premin"
      type    = "double"
      comment = "Preço mínimo"
    }
    columns {
      name    = "premed"
      type    = "double"
      comment = "Preço médio"
    }
    columns {
      name    = "preult"
      type    = "double"
      comment = "Preço de fechamento"
    }
    columns {
      name    = "preofc"
      type    = "double"
      comment = "Preço da melhor oferta de compra"
    }
    columns {
      name    = "preofv"
      type    = "double"
      comment = "Preço da melhor oferta de venda"
    }
    columns {
      name    = "totneg"
      type    = "bigint"
      comment = "Total de negócios efetuados"
    }
    columns {
      name    = "quatot"
      type    = "bigint"
      comment = "Quantidade total de títulos negociados"
    }
    columns {
      name    = "voltot"
      type    = "double"
      comment = "Volume total de títulos negociados"
    }
    columns {
      name    = "codisi"
      type    = "string"
      comment = "Código ISIN"
    }
    columns {
      name    = "dismes"
      type    = "string"
      comment = "Número de distribuição"
    }
  }
}
