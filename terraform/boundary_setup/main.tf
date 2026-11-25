###############################################################################
# Boundary demo setup – Terraform conversion of the CLI script
# Requires: boundary provider >= 1.3 (alias + rdp targets, password creds),
#           aws provider, hashicorp/external, hashicorp/null (terraform_data is built in)
###############################################################################

terraform {
  required_providers {
    boundary = {
      source  = "hashicorp/boundary"
      version = ">= 1.3.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.14"
    }
  }
}



###############################################################################
# Providers
###############################################################################

provider "aws" {
  region = var.aws_region
}

provider "boundary" {
  addr = var.boundary_cluster_admin_url
}

###############################################################################
# Inputs from the infra_setup state / infra_output.json
###############################################################################

data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${var.tf_base}/infra_setup/terraform.tfstate"
  }
}

locals {
  infra_output = jsondecode(file("${var.tf_base}/infra_output.json"))

  aws_s3_bucket        = data.terraform_remote_state.infra.outputs.aws_bucket_name
  windows_ip           = data.terraform_remote_state.infra.outputs.domain_controller
  boundary_worker_addr = local.infra_output.boundary_worker_dns_private.value
  vault_server_addr    = local.infra_output.vault_server.value

  egress_vm_filter  = "\"${var.unique_name}-vm\" in \"/tags/unique_name\""
  egress_k8s_filter = "\"${var.unique_name}-k8s\" in \"/tags/unique_name\""

  ssh_key_dir = "${var.home_dir}/terraform/infra_setup/gen_files/ssh_keys"
}

###############################################################################
# Session recording storage bucket
###############################################################################

resource "boundary_storage_bucket" "recordings" {
  name        = "session-recordings"
  scope_id    = "global"
  plugin_name = "aws"
  bucket_name = local.aws_s3_bucket
  worker_filter = "\"public_instance\" in \"/tags/type\""

  attributes_json = jsonencode({
    region                      = "us-west-2"
    disable_credential_rotation = true
  })
}

###############################################################################
# Scopes
###############################################################################

resource "boundary_scope" "org" {
  name                     = "${var.unique_name} Inc."
  scope_id                 = "global"
  auto_create_admin_role   = true
  auto_create_default_role = true
}

resource "boundary_scope" "project" {
  name                     = "Demo web application"
  scope_id                 = boundary_scope.org.id
  auto_create_admin_role   = true
  auto_create_default_role = true
}

# The provider has no alias-suffix argument on boundary_scope, so use the CLI.
# resource "terraform_data" "org_alias_suffix" {
#   triggers_replace = [boundary_scope.org.id]

#   provisioner "local-exec" {
#     command = "boundary scopes set-alias-suffix -keyring-type=none -token env://BOUNDARY_TOKEN -id ${boundary_scope.org.id} -alias-suffix local"
#     environment = {
#       BOUNDARY_ADDR  = var.boundary_addr
#       BOUNDARY_TOKEN = var.boundary_token
#     }
#   }
# }
resource "boundary_scope_alias_suffix" "org" {
  scope_id     = boundary_scope.org.id
  alias_suffix = "local"
}

# resource "terraform_data" "project_alias_suffix" {
#   triggers_replace = [boundary_scope.project.id]

#   provisioner "local-exec" {
#     command = "boundary scopes set-alias-suffix -keyring-type=none -token env://BOUNDARY_TOKEN -id ${boundary_scope.project.id} -alias-suffix hashidemos"
#     environment = {
#       BOUNDARY_ADDR  = var.boundary_addr
#       BOUNDARY_TOKEN = var.boundary_token
#     }
#   }
# }

resource "boundary_scope_alias_suffix" "project" {
  scope_id     = boundary_scope.project.id
  alias_suffix = "hashidemos"
}
###############################################################################
# Static host catalog – Boundary worker VM
###############################################################################

resource "boundary_host_catalog_static" "workers" {
  name        = "boundary_workers"
  description = "Boundary worker VMs"
  scope_id    = boundary_scope.project.id
}

resource "boundary_host_static" "worker_vm" {
  name            = "${var.unique_name}-vm"
  address         = local.boundary_worker_addr
  host_catalog_id = boundary_host_catalog_static.workers.id
}

resource "boundary_host_set_static" "workers" {
  name            = "boundary_workers"
  host_catalog_id = boundary_host_catalog_static.workers.id
  host_ids        = [boundary_host_static.worker_vm.id]
}

###############################################################################
# AWS plugin host catalog (IAM user + policy for ec2:DescribeInstances)
###############################################################################

resource "aws_iam_policy" "boundary_describe_instances" {
  name   = "boundary-ec2-describe-instances"
  policy = file("${var.home_dir}/files/aws-boundary-iam-policy.json")
}

resource "aws_iam_user" "boundary_host_catalog" {
  name = "boundary-host-catalog"
}

resource "aws_iam_user_policy_attachment" "boundary_host_catalog" {
  user       = aws_iam_user.boundary_host_catalog.name
  policy_arn = aws_iam_policy.boundary_describe_instances.arn
}

resource "aws_iam_access_key" "boundary_host_catalog" {
  user = aws_iam_user.boundary_host_catalog.name
}
resource "time_sleep" "wait_for_iam" {
  depends_on      = [aws_iam_user_policy_attachment.boundary_host_catalog]
  create_duration = "10s"
}
resource "boundary_host_catalog_plugin" "app_infra" {
  name        = "app_infra"
  description = "App infrastructure hosts"
  scope_id    = boundary_scope.project.id
  plugin_name = "aws"

  attributes_json = jsonencode({
    region                      = var.aws_region
    disable_credential_rotation = true
  })

  secrets_json = jsonencode({
    access_key_id     = aws_iam_access_key.boundary_host_catalog.id
    secret_access_key = aws_iam_access_key.boundary_host_catalog.secret
  })

  depends_on = [time_sleep.wait_for_iam]
}

resource "boundary_host_set_plugin" "vault_servers" {
  name                  = "vault_servers"
  host_catalog_id       = boundary_host_catalog_plugin.app_infra.id
  attributes_json       = jsonencode({ filters = ["tag:app=vault"] })
  sync_interval_seconds = 5
}

resource "boundary_host_set_plugin" "kubernetes_nodes" {
  name                  = "kubernetes_nodes"
  host_catalog_id       = boundary_host_catalog_plugin.app_infra.id
  attributes_json       = jsonencode({ filters = ["tag:app=kubernetes"] })
  sync_interval_seconds = 5
}

resource "boundary_host_set_plugin" "postgres_servers" {
  name                  = "postgres_servers"
  host_catalog_id       = boundary_host_catalog_plugin.app_infra.id
  attributes_json       = jsonencode({ filters = ["tag:app=postgres"] })
  sync_interval_seconds = 5
}

###############################################################################
# Static credential store – SSH private keys
###############################################################################

resource "boundary_credential_store_static" "ssh_keys" {
  name     = "ssh_keys"
  scope_id = boundary_scope.project.id
}

resource "boundary_credential_ssh_private_key" "app_ssh_key" {
  name                = "app_ssh_key"
  credential_store_id = boundary_credential_store_static.ssh_keys.id
  username            = "ubuntu"
  private_key         = file("${local.ssh_key_dir}/app_infra")
}

resource "boundary_credential_ssh_private_key" "boundary_ssh_key" {
  name                = "boundary_ssh_key"
  credential_store_id = boundary_credential_store_static.ssh_keys.id
  username            = "ubuntu"
  private_key         = file("${local.ssh_key_dir}/boundary_infra")
}

###############################################################################
# Vault SSH target (injected credentials, session recording)
###############################################################################

resource "boundary_target" "vault_server_ssh" {
  type                     = "ssh"
  name                     = "vault_server_ssh"
  scope_id                 = boundary_scope.project.id
  default_port             = 22
  egress_worker_filter     = local.egress_vm_filter
  storage_bucket_id        = boundary_storage_bucket.recordings.id
  enable_session_recording = true

  host_source_ids                       = [boundary_host_set_plugin.vault_servers.id]
  injected_application_credential_source_ids = [boundary_credential_ssh_private_key.app_ssh_key.id]
}

resource "boundary_alias_target" "vault_server_ssh" {
  name           = "vault_server_ssh"
  scope_id       = "global"
  value          = "vault-ssh.hashidemos.local"
  destination_id = boundary_target.vault_server_ssh.id
}

###############################################################################
# Fetch Vault tokens by SSHing through Boundary (replaces `boundary connect ssh`)
###############################################################################

# Orphan periodic token for Boundary's Vault credential store
data "external" "boundary_vault_token" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    TOKEN=$(boundary connect ssh -keyring-type=none -token env://BOUNDARY_TOKEN \
      -target-name vault_server_ssh -target-scope-name "Demo web application" \
      -remote-command="source /home/ubuntu/.bash_profile && vault token create -orphan -renewable -period 60m -policy boundary-token -policy boundary-database-secrets -format json" \
      | jq -r '.auth.client_token')
    jq -n --arg token "$TOKEN" '{token: $token}'
  EOT
  ]

  # BOUNDARY_ADDR / BOUNDARY_TOKEN must be exported in the shell running terraform
  depends_on = [
    boundary_target.vault_server_ssh,
    boundary_host_set_plugin.vault_servers,
  ]
}

# Vault root token (used as brokered password for the Vault UI target)
data "external" "vault_root_token" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    TOKEN=$(boundary connect ssh -keyring-type=none -token env://BOUNDARY_TOKEN \
      -target-name vault_server_ssh -target-scope-name "Demo web application" \
      -remote-command="cat /etc/vault.d/vault.env" \
      | grep VAULT_TOKEN | sed -n 's/^VAULT_TOKEN="\(.*\)"$/\1/p')
    jq -n --arg token "$TOKEN" '{token: $token}'
  EOT
  ]

  depends_on = [
    boundary_target.vault_server_ssh,
    boundary_host_set_plugin.vault_servers,
  ]
}

###############################################################################
# Vault credential store + libraries (dynamic Postgres creds)
###############################################################################

resource "boundary_credential_store_vault" "postgres_credentials" {
  name          = "postgres_credentials"
  scope_id      = boundary_scope.project.id
  address       = "http://${local.vault_server_addr}:8200"
  token         = data.external.boundary_vault_token.result.token
  worker_filter = local.egress_vm_filter
}

resource "boundary_credential_library_vault" "product_api_readonly" {
  name                = "product_api_readonly"
  credential_store_id = boundary_credential_store_vault.postgres_credentials.id
  path                = "postgres/creds/product-api-readonly"
  credential_type     = "username_password"
}

resource "boundary_credential_library_vault" "product_api_admin" {
  name                = "product_api_admin"
  credential_store_id = boundary_credential_store_vault.postgres_credentials.id
  path                = "postgres/creds/product-api-admin"
  credential_type     = "username_password"
}

###############################################################################
# Vault web target (brokered root token)
###############################################################################

resource "boundary_credential_store_static" "vault_root_token" {
  name     = "vault_root_token"
  scope_id = boundary_scope.project.id
}

resource "boundary_credential_password" "vault_root_token" {
  name                = "vault_root_token"
  credential_store_id = boundary_credential_store_static.vault_root_token.id
  password            = data.external.vault_root_token.result.token
}

resource "boundary_target" "vault_server_web" {
  type                 = "tcp"
  name                 = "vault_server_web"
  scope_id             = boundary_scope.project.id
  default_port         = 8200
  egress_worker_filter = local.egress_vm_filter

  host_source_ids                     = [boundary_host_set_plugin.vault_servers.id]
  brokered_credential_source_ids = [boundary_credential_password.vault_root_token.id]
}

resource "boundary_alias_target" "vault_server_web" {
  name           = "vault_server_web"
  scope_id       = "global"
  value          = "vault.hashidemos.local"
  destination_id = boundary_target.vault_server_web.id
}

###############################################################################
# Boundary worker SSH target
###############################################################################

resource "boundary_target" "boundary_worker_ssh" {
  type                     = "ssh"
  name                     = "boundary_worker_ssh"
  scope_id                 = boundary_scope.project.id
  default_port             = 22
  egress_worker_filter     = local.egress_vm_filter
  storage_bucket_id        = boundary_storage_bucket.recordings.id
  enable_session_recording = true

  host_source_ids                            = [boundary_host_set_static.workers.id]
  injected_application_credential_source_ids = [boundary_credential_ssh_private_key.app_ssh_key.id]
}

resource "boundary_alias_target" "boundary_worker_ssh" {
  name           = "boundary_worker_ssh"
  scope_id       = "global"
  value          = "worker-ssh.hashidemos.local"
  destination_id = boundary_target.boundary_worker_ssh.id
}

###############################################################################
# Postgres targets
###############################################################################

resource "boundary_target" "postgres_server_ssh" {
  type                     = "ssh"
  name                     = "postgres_server_ssh"
  scope_id                 = boundary_scope.project.id
  default_port             = 22
  egress_worker_filter     = local.egress_vm_filter
  storage_bucket_id        = boundary_storage_bucket.recordings.id
  enable_session_recording = true

  host_source_ids                            = [boundary_host_set_plugin.postgres_servers.id]
  injected_application_credential_source_ids = [boundary_credential_ssh_private_key.app_ssh_key.id]
}

resource "boundary_alias_target" "postgres_server_ssh" {
  name           = "postgres_server_ssh"
  scope_id       = "global"
  value          = "pg-ssh.hashidemos.local"
  destination_id = boundary_target.postgres_server_ssh.id
}

resource "boundary_target" "postgres_server_admin" {
  type                 = "tcp"
  name                 = "postgres_server_admin"
  scope_id             = boundary_scope.project.id
  default_port         = 5432
  egress_worker_filter = local.egress_vm_filter

  host_source_ids                = [boundary_host_set_plugin.postgres_servers.id]
  brokered_credential_source_ids = [boundary_credential_library_vault.product_api_admin.id]
}

resource "boundary_alias_target" "postgres_server_admin" {
  name           = "postgres_server_admin"
  scope_id       = "global"
  value          = "pg-admin.hashidemos.local"
  destination_id = boundary_target.postgres_server_admin.id
}

resource "boundary_target" "postgres_server_readonly" {
  type                 = "tcp"
  name                 = "postgres_server_readonly"
  scope_id             = boundary_scope.project.id
  default_port         = 5432
  egress_worker_filter = local.egress_vm_filter

  host_source_ids                = [boundary_host_set_plugin.postgres_servers.id]
  brokered_credential_source_ids = [boundary_credential_library_vault.product_api_readonly.id]
}

resource "boundary_alias_target" "postgres_server_readonly" {
  name           = "postgres_server_readonly"
  scope_id       = "global"
  value          = "pg-readonly.hashidemos.local"
  destination_id = boundary_target.postgres_server_readonly.id
}

###############################################################################
# Windows RDP target
###############################################################################

resource "boundary_credential_store_static" "windows_rdp_creds" {
  name     = "windows_rdp_creds"
  scope_id = boundary_scope.project.id
}

resource "boundary_credential_username_password" "windows_rdp_creds" {
  name                = "windows_rdp_creds"
  credential_store_id = boundary_credential_store_static.windows_rdp_creds.id
  username            = "Administrator"
  password            = var.win_rdp_password
}

resource "boundary_target" "windows_rdp" {
  type                 = "rdp"
  name                 = "windows_rdp"
  scope_id             = boundary_scope.project.id
  address              = local.windows_ip
  default_port         = 3389
  egress_worker_filter = local.egress_vm_filter

  injected_application_credential_source_ids = [boundary_credential_username_password.windows_rdp_creds.id]
}

resource "boundary_alias_target" "windows_rdp" {
  name           = "windows_rdp"
  scope_id       = "global"
  value          = "windows.hashidemos.local"
  destination_id = boundary_target.windows_rdp.id
}

###############################################################################
# Kubernetes Postgres target
###############################################################################

resource "boundary_target" "postgres_kube" {
  type                 = "tcp"
  name                 = "postgres_kube"
  scope_id             = boundary_scope.project.id
  address              = "k8s-postgres-postgresql.default.svc"
  default_port         = 5432
  egress_worker_filter = local.egress_k8s_filter
}

resource "boundary_alias_target" "postgres_kube" {
  name           = "postgres_kube"
  scope_id       = "global"
  value          = "k8s-pg.hashidemos.local"
  destination_id = boundary_target.postgres_kube.id
}