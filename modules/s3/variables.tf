variable "name_prefix" {
  type = string
}
variable "environment" {
  type = string
}
variable "account_id" {
  type = string
}
variable "lifecycle_bronze_days" {
  type    = number
  default = 90
}
variable "lifecycle_silver_days" {
  type    = number
  default = 180
}
