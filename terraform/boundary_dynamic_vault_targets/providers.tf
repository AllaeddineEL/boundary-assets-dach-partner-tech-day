terraform {
  required_providers {
   
    boundary = {
      source  = "hashicorp/boundary"
      version = ">= 1.1.9"
    }
    
    vault = {
      version = ">= 3.20.1"
      source  = "hashicorp/vault"
    }
  }
}



provider "boundary" {
  addr                   = data.tfe_outputs.boundary_demo_init.values.boundary_url
  auth_method_id         = data.tfe_outputs.boundary_demo_init.values.boundary_admin_auth_method
  auth_method_login_name = var.boundary_user
  auth_method_password   = var.boundary_password
}

provider "vault" {
  address   = "http://localhost:8200"
  token     = local.vault_root_token
}