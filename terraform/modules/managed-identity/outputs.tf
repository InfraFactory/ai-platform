output "client_id" {
  description = "Client ID of the managed identity. Used in Kubernetes ServiceAccount annotations."
  value       = azurerm_user_assigned_identity.this.client_id
}

output "principal_id" {
  description = "Object ID of the managed identity. Used in role assignments by downstream modules."
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "id" {
  description = "Full resource ID of the managed identity."
  value       = azurerm_user_assigned_identity.this.id
}

output "name" {
  description = "Name of the managed identity."
  value       = azurerm_user_assigned_identity.this.name
}
