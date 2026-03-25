###############################################################
# Módulo S3 - Buckets para Arquitetura Medallion
# Bronze (SOR) → Silver (SOT) → Gold (SPEC)
###############################################################

# ---- Bucket Bronze - SOR (System of Record) - Dados Brutos ----

resource "aws_s3_bucket" "sor" {
  bucket        = "${var.name_prefix}-sor"
  force_destroy = var.environment == "dev" ? true : false
}

resource "aws_s3_bucket_versioning" "sor" {
  bucket = aws_s3_bucket.sor.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sor" {
  bucket = aws_s3_bucket.sor.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "sor" {
  bucket                  = aws_s3_bucket.sor.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "sor" {
  bucket = aws_s3_bucket.sor.id
  rule {
    id     = "transition-to-ia"
    status = "Enabled"
    filter {}
    transition {
      days          = var.lifecycle_bronze_days
      storage_class = "STANDARD_IA"
    }
  }
}

# Estrutura de pastas SOR
resource "aws_s3_object" "sor_b3_historico" {
  bucket  = aws_s3_bucket.sor.id
  key     = "b3-series-historicas/"
  content = ""
}

resource "aws_s3_object" "sor_cotacoes_live" {
  bucket  = aws_s3_bucket.sor.id
  key     = "cotacoes-live/"
  content = ""
}

resource "aws_s3_object" "sor_b3_dimensoes" {
  bucket  = aws_s3_bucket.sor.id
  key     = "b3-dimensoes/"
  content = ""
}

resource "aws_s3_object" "clusters_brasil" {
  bucket  = aws_s3_bucket.sor.id
  key     = "clusters_brasil/"
  content = ""
}

# ---- Bucket Silver - SOT (Source of Truth) - Dados Tratados ----

resource "aws_s3_bucket" "sot" {
  bucket        = "${var.name_prefix}-sot"
  force_destroy = var.environment == "dev" ? true : false
}

resource "aws_s3_bucket_versioning" "sot" {
  bucket = aws_s3_bucket.sot.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sot" {
  bucket = aws_s3_bucket.sot.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "sot" {
  bucket                  = aws_s3_bucket.sot.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "sot" {
  bucket = aws_s3_bucket.sot.id
  rule {
    id     = "transition-to-ia"
    status = "Enabled"
    filter {}
    transition {
      days          = var.lifecycle_silver_days
      storage_class = "STANDARD_IA"
    }
  }
}

# Estrutura de pastas SOT
resource "aws_s3_object" "sot_acoes" {
  bucket  = aws_s3_bucket.sot.id
  key     = "b3-series/"
  content = ""
}

resource "aws_s3_object" "sot_indices" {
  bucket  = aws_s3_bucket.sot.id
  key     = "cotacoes-live/"
  content = ""
}

resource "aws_s3_object" "sot_b3_dimensoes" {
  bucket  = aws_s3_bucket.sot.id
  key     = "b3-dimensoes/"
  content = ""
}

resource "aws_s3_object" "clusters_brasil" {
  bucket  = aws_s3_bucket.sot.id
  key     = "clusters_brasil/"
  content = ""
}
# ---- Bucket Gold - SPEC (Single Point of Entry for Consumers) ----

resource "aws_s3_bucket" "spec" {
  bucket        = "${var.name_prefix}-spec"
  force_destroy = var.environment == "dev" ? true : false
}

resource "aws_s3_bucket_versioning" "spec" {
  bucket = aws_s3_bucket.spec.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "spec" {
  bucket = aws_s3_bucket.spec.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "spec" {
  bucket                  = aws_s3_bucket.spec.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Estrutura de pastas SPEC
resource "aws_s3_object" "spec_carteiras" {
  bucket  = aws_s3_bucket.spec.id
  key     = "carteiras-otimizadas/"
  content = ""
}

resource "aws_s3_object" "spec_recomendacoes" {
  bucket  = aws_s3_bucket.spec.id
  key     = "recomendacoes/"
  content = ""
}

resource "aws_s3_object" "datamart_ml" {
  bucket  = aws_s3_bucket.spec.id
  key     = "datamart_ml/"
  content = ""
}

resource "aws_s3_object" "spec_b3_dimensoes" {
  bucket  = aws_s3_bucket.spec.id
  key     = "b3-dimensoes/"
  content = ""
}

resource "aws_s3_object" "spec_cotacoes_live" {
  bucket  = aws_s3_bucket.spec.id
  key     = "cotacoes-live/"
  content = ""
}

# ---- Bucket para Scripts Glue ----

resource "aws_s3_bucket" "scripts" {
  bucket        = "${var.name_prefix}-glue-scripts"
  force_destroy = var.environment == "dev" ? true : false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scripts" {
  bucket = aws_s3_bucket.scripts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  bucket                  = aws_s3_bucket.scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---- Bucket para Resultados Athena ----

resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.name_prefix}-athena-results"
  force_destroy = var.environment == "dev" ? true : false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "cleanup-old-results"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
  }
}

# ---- Bucket para SageMaker ----

resource "aws_s3_bucket" "sagemaker" {
  bucket        = "${var.name_prefix}-sagemaker"
  force_destroy = var.environment == "dev" ? true : false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sagemaker" {
  bucket = aws_s3_bucket.sagemaker.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "sagemaker" {
  bucket                  = aws_s3_bucket.sagemaker.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
