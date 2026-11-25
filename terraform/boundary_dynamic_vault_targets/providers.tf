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
  addr = var.boundary_cluster_admin_url
}

provider "vault" {
  address   = "http://localhost:8200"
  token     = local.vault_root_token
}