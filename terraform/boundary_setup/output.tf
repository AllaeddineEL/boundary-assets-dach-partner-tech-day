output "project_id" {
  description = "The project ID of the Boundary project created for the demo."
  value       = boundary_scope.project.id
}
output "vault_root_token" {
  description = "The root token for the Vault instance created for the demo."
  value       = data.external.vault_root_token.result.token
}