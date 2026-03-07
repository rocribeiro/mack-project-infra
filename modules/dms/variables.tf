variable "name_prefix"               { type = string }
variable "environment"                { type = string }
variable "dms_role_arn"               { type = string }
variable "s3_bucket_sor_arn"          { type = string }
variable "s3_bucket_sor_name"         { type = string }
variable "replication_instance_class" {
  type    = string
  default = "dms.t3.micro"
}
