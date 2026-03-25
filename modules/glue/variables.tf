variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "glue_role_arn" {
  type = string
}

variable "s3_bucket_sor" {
  type = string
}

variable "s3_bucket_sot" {
  type = string
}

variable "s3_bucket_spec" {
  type = string
}

variable "s3_scripts_bucket" {
  type = string
}

variable "glue_worker_type" {
  type    = string
  default = "G.1X"
}

variable "glue_number_of_workers_silver" {
  type    = number
  default = 2
}

variable "glue_number_of_workers_gold" {
  type    = number
  default = 10
}

variable "glue_max_retries" {
  type    = number
  default = 1
}
