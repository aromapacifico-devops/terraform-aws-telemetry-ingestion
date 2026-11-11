# Calls the module from the parent directory.
module "this" {
  source = "../"

  providers = {
    aws.project = aws.principal
  }

  client      = var.client
  project     = var.project
  environment = var.environment

  data_key_arn    = data.aws_kms_alias.keys["data"].target_key_arn
  objects_key_arn = data.aws_kms_alias.keys["objects"].target_key_arn
  role_arns       = { for purpose, role in data.aws_iam_role.roles : purpose => role.arn }

  names             = local.names
  thing_groups      = local.thing_groups
  function_packages = local.function_packages
  alert_ranges      = var.alert_ranges

  force_destroy_data = true
}
