# Input variables of the sample.
variable "client" {
  description = "Client code."
  type        = string
}

variable "project" {
  description = "Project code."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "region" {
  description = "AWS Region of the sample."
  type        = string
}

variable "deploy_role_arn" {
  description = "Role to assume. Leave empty to use the local credentials."
  type        = string
  default     = ""
}

variable "common_tags" {
  description = "Tags applied to every resource through the provider."
  type        = map(string)
}

variable "departments" {
  description = "Departments that get a thing group."
  type        = set(string)
}

variable "function_package_path" {
  description = "Package deployed to the three functions of the sample."
  type        = string
}

variable "alert_ranges" {
  description = "Initial ranges, written as version 1."
  type        = any
}
