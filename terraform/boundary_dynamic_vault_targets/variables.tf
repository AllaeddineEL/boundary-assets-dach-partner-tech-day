
variable "admin_pass" {
  type        = string
  default     = "LongPassword12345!"
  description = "The password to set on the windows and linux targets for the admin user"
}

variable "tf_base" {
  type        = string
  description = "Was $TF_BASE – directory containing infra_setup/ and infra_output.json"
  default     = "/root/terraform"
}
variable "boundary_cluster_admin_url" {
  type        = string
  description = "Was $BOUNDARY_ADDR"
}
variable "unique_name" {
  type        = string
  description = "Was $TF_VAR_unique_name"
}