###############################################################
# Módulo Athena - Consultas SQL sobre o Data Lake
# Query engine serverless sobre S3 via Glue Catalog
###############################################################

# ---- Athena Workgroup ----

resource "aws_athena_workgroup" "main" {
  name        = "${var.name_prefix}-workgroup"
  description = "Workgroup para análises B3 - carteiras e ativos"
  state       = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 1073741824 # 1 GB limite por query

    result_configuration {
      output_location = "s3://${var.s3_results_bucket}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# ---- Athena Database (referencia o Glue Catalog) ----

resource "aws_athena_database" "b3" {
  name   = replace("${var.name_prefix}_athena", "-", "_")
  bucket = var.s3_results_bucket
  comment = "Database Athena para análises B3"
}

# ---- Queries Salvas ----

resource "aws_athena_named_query" "acoes_por_ticker" {
  name      = "${var.name_prefix}-acoes-por-ticker"
  workgroup = aws_athena_workgroup.main.id
  database  = var.glue_database_name
  description = "Retorna preços históricos de um ativo específico"

  query = <<-EOT
    SELECT
      datpre,
      codneg AS ticker,
      nomres AS empresa,
      preabe AS preco_abertura,
      premax AS preco_maximo,
      premin AS preco_minimo,
      preult AS preco_fechamento,
      voltot AS volume_total,
      totneg AS total_negocios
    FROM b3_series_historicas_bronze
    WHERE codneg = 'PETR4'
      AND datpre BETWEEN '20230101' AND '20231231'
    ORDER BY datpre DESC
    LIMIT 100;
  EOT
}

resource "aws_athena_named_query" "top_volume_dia" {
  name      = "${var.name_prefix}-top-volume-dia"
  workgroup = aws_athena_workgroup.main.id
  database  = var.glue_database_name
  description = "Top 20 ativos por volume em um pregão"

  query = <<-EOT
    SELECT
      codneg AS ticker,
      nomres AS empresa,
      preult AS preco_fechamento,
      voltot AS volume_total,
      totneg AS total_negocios,
      ((preult - preabe) / NULLIF(preabe, 0)) * 100 AS variacao_pct
    FROM b3_series_historicas_bronze
    WHERE datpre = '20231229'
      AND tpmerc = '010'  -- mercado à vista
    ORDER BY voltot DESC
    LIMIT 20;
  EOT
}

resource "aws_athena_named_query" "retorno_carteira" {
  name      = "${var.name_prefix}-retorno-carteira"
  workgroup = aws_athena_workgroup.main.id
  database  = var.glue_database_name
  description = "Calcula retorno de uma carteira de ativos"

  query = <<-EOT
    WITH carteira AS (
      SELECT codneg, preult, datpre,
        LAG(preult) OVER (PARTITION BY codneg ORDER BY datpre) AS preult_anterior
      FROM b3_series_historicas_bronze
      WHERE codneg IN ('PETR4', 'VALE3', 'ITUB4', 'BBDC4', 'ABEV3')
        AND datpre BETWEEN '20230101' AND '20231231'
    )
    SELECT
      codneg AS ticker,
      datpre,
      preult,
      preult_anterior,
      ((preult - preult_anterior) / NULLIF(preult_anterior, 0)) * 100 AS retorno_diario_pct
    FROM carteira
    WHERE preult_anterior IS NOT NULL
    ORDER BY codneg, datpre;
  EOT
}

resource "aws_athena_named_query" "volatilidade_ativos" {
  name      = "${var.name_prefix}-volatilidade-ativos"
  workgroup = aws_athena_workgroup.main.id
  database  = var.glue_database_name
  description = "Calcula volatilidade histórica dos ativos (base para classificação de risco)"

  query = <<-EOT
    WITH retornos AS (
      SELECT
        codneg,
        datpre,
        preult,
        LAG(preult) OVER (PARTITION BY codneg ORDER BY datpre) AS preco_anterior
      FROM b3_series_historicas_bronze
      WHERE tpmerc = '010'
        AND datpre BETWEEN '20230101' AND '20231231'
    ),
    log_retornos AS (
      SELECT
        codneg,
        LN(preult / NULLIF(preco_anterior, 0)) AS retorno_log
      FROM retornos
      WHERE preco_anterior IS NOT NULL AND preco_anterior > 0
    )
    SELECT
      codneg AS ticker,
      COUNT(*) AS dias_negociados,
      AVG(retorno_log) AS retorno_medio_diario,
      STDDEV(retorno_log) AS volatilidade_diaria,
      STDDEV(retorno_log) * SQRT(252) AS volatilidade_anualizada,
      CASE
        WHEN STDDEV(retorno_log) * SQRT(252) < 0.20 THEN 'Conservador'
        WHEN STDDEV(retorno_log) * SQRT(252) < 0.40 THEN 'Moderado'
        WHEN STDDEV(retorno_log) * SQRT(252) < 0.60 THEN 'Arrojado'
        ELSE 'Agressivo'
      END AS perfil_risco
    FROM log_retornos
    GROUP BY codneg
    ORDER BY volatilidade_anualizada DESC;
  EOT
}
