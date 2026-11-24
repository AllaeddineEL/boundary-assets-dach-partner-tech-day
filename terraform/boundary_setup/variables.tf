###############################################################################
# Variables
###############################################################################

variable "boundary_cluster_admin_url" {
  type        = string
  description = "Was $BOUNDARY_ADDR"
}
variable "unique_name" {
  type        = string
  description = "Was $TF_VAR_unique_name"
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "tf_base" {
  type        = string
  description = "Was $TF_BASE – directory containing infra_setup/ and infra_output.json"
  default     = "/root/terraform"
}

variable "home_dir" {
  type        = string
  description = "Was $HOME"
  default     = "/root"
}

variable "win_rdp_password" {
  type      = string
  sensitive = true
  default   = "Passw0rd!"
}