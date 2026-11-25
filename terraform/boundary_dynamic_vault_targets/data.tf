data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${var.tf_base}/infra_setup/terraform.tfstate"
  }
}
data "terraform_remote_state" "boundary_setup" {
  backend = "local"
  config = {
    path = "${var.tf_base}/boundary_setup/terraform.tfstate"
  }
}
locals {
  infra_output = jsondecode(file("${var.tf_base}/infra_output.json"))

  aws_s3_bucket        = data.terraform_remote_state.infra.outputs.aws_bucket_name
  windows_ip           = data.terraform_remote_state.infra.outputs.domain_controller
  boundary_worker_addr = local.infra_output.boundary_worker_dns_private.value
  vault_server_addr    = local.infra_output.vault_server.value
  vault_root_token     = data.terraform_remote_state.boundary_setup.outputs.vault_root_token
  egress_vm_filter  = "\"${var.unique_name}-vm\" in \"/tags/unique_name\""
}