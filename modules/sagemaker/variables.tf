variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "sagemaker_role_arn" {
  type = string
}

variable "s3_bucket_spec" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "ml.t3.medium"
}
