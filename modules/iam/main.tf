###############################################################
# Módulo IAM - Roles e Policies para todos os serviços
###############################################################

# ---- Glue Role ----

resource "aws_iam_role" "glue" {
  name = "${var.name_prefix}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3" {
  name = "${var.name_prefix}-glue-s3-policy"
  role = aws_iam_role.glue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-*",
          "arn:aws:s3:::${var.name_prefix}-*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:${var.account_id}:log-group:/aws-glue/*"
      }
    ]
  })
}

# ---- Kinesis Firehose Role ----

resource "aws_iam_role" "kinesis" {
  name = "${var.name_prefix}-kinesis-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "kinesis_s3" {
  name = "${var.name_prefix}-kinesis-s3-policy"
  role = aws_iam_role.kinesis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload", "s3:GetBucketLocation",
          "s3:GetObject", "s3:ListBucket",
          "s3:ListBucketMultipartUploads", "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-sor",
          "arn:aws:s3:::${var.name_prefix}-sor/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kinesis:DescribeStream", "kinesis:GetShardIterator",
          "kinesis:GetRecords", "kinesis:ListShards"
        ]
        Resource = "arn:aws:kinesis:${var.region}:${var.account_id}:stream/${var.name_prefix}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/kinesisfirehose/*"
      }
    ]
  })
}

# ---- SageMaker Role ----

resource "aws_iam_role" "sagemaker" {
  name = "${var.name_prefix}-sagemaker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  role       = aws_iam_role.sagemaker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy" "sagemaker_s3" {
  name = "${var.name_prefix}-sagemaker-s3-policy"
  role = aws_iam_role.sagemaker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject", "s3:PutObject", "s3:ListBucket"
      ]
      Resource = [
        "arn:aws:s3:::${var.name_prefix}-*",
        "arn:aws:s3:::${var.name_prefix}-*/*"
      ]
    }]
  })
}

# ---- DMS Role ----

resource "aws_iam_role" "dms" {
  name = "${var.name_prefix}-dms-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dms.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "dms_s3" {
  name = "${var.name_prefix}-dms-s3-policy"
  role = aws_iam_role.dms.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
        "s3:GetObject", "s3:GetBucketLocation"
      ]
      Resource = [
        "arn:aws:s3:::${var.name_prefix}-sor",
        "arn:aws:s3:::${var.name_prefix}-sor/*"
      ]
    }]
  })
}

# ---- Athena Role (para acesso via aplicações) ----

resource "aws_iam_role" "athena" {
  name = "${var.name_prefix}-athena-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "athena.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "athena_access" {
  name = "${var.name_prefix}-athena-policy"
  role = aws_iam_role.athena.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:ListBucket", "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.name_prefix}-*",
          "arn:aws:s3:::${var.name_prefix}-*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetTable", "glue:GetPartitions",
          "glue:GetDatabases", "glue:GetTables"
        ]
        Resource = "*"
      }
    ]
  })
}
