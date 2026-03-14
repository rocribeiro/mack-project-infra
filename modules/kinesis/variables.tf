variable "name_prefix"              { type = string }
variable "environment"               { type = string }
variable "kinesis_role_arn"          { type = string }
variable "s3_bucket_sor_arn"         { type = string }
variable "s3_bucket_sor_name"        { type = string }
variable "shard_count"               { type = number; default = 1 }
variable "retention_hours"           { type = number; default = 24 }
variable "firehose_buffer_size_mb"   { type = number; default = 64 }
variable "firehose_buffer_interval_sec" { type = number; default = 300 }
