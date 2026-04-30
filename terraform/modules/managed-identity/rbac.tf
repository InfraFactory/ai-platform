resource "azurerm_role_assignment" "this" {
  for_each = {
    for idx, ra in var.role_assignments :
    "${var.name}-${replace(ra.role_definition_name, " ", "-")}-${idx}" => ra
    # Skip assignments where scope is empty — resource not yet provisioned
    if ra.scope != ""
  }

  principal_id         = azurerm_user_assigned_identity.this.principal_id
  role_definition_name = each.value.role_definition_name
  scope                = each.value.scope

  depends_on = [azurerm_user_assigned_identity.this]
}
