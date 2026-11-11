# Input variables of the module.
# Governance input of every module. Resource names arrive complete in names, so this module reads no code.
# tflint-ignore: terraform_unused_declarations
variable "client" {
  description = "Client code, used in names and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,10}$", var.client))
    error_message = "client must be 1 to 10 lowercase alphanumeric characters."
  }
}

variable "project" {
  description = "Project code, used in names and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,15}$", var.project))
    error_message = "project must be 1 to 15 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be dev, test or prod."
  }
}

variable "additional_tags" {
  description = "Tags added to the resources of this module, on top of the provider default tags."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for key in keys(var.additional_tags) : length(trimspace(key)) > 0])
    error_message = "additional_tags keys cannot be empty."
  }
}

variable "data_key_arn" {
  description = "ARN of the data key from the security module. It encrypts the tables, the queues and the log groups."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.data_key_arn))
    error_message = "data_key_arn must be the ARN of a KMS key."
  }
}

variable "objects_key_arn" {
  description = "ARN of the objects key from the security module. It encrypts the archive bucket."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.objects_key_arn))
    error_message = "objects_key_arn must be the ARN of a KMS key."
  }
}

variable "role_arns" {
  description = "ARNs of the roles from the security module, one per purpose of this module."
  type = object({
    ingestion_function       = string
    iot_rule                 = string
    firehose_delivery        = string
    delivery_status_function = string
    delivery_check_function  = string
    push_status_logs         = string
    sms_status_logs          = string
  })

  validation {
    condition     = alltrue([for arn in values(var.role_arns) : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", arn))])
    error_message = "Each value of role_arns must be the ARN of an IAM role."
  }
}

variable "names" {
  description = "Final names of the resources, built by the root with the naming convention. The IoT rule and the Glue names use underscores, since those services accept no hyphens."
  type = object({
    ingestion_queue             = string
    ingestion_dead_letter_queue = string
    delivery_queue              = string
    delivery_dead_letter_queue  = string
    readings_table              = string
    ranges_table                = string
    alerts_table                = string
    farms_table                 = string
    archive_bucket              = string
    archive_stream              = string
    archive_database            = string
    archive_table               = string
    telemetry_rule              = string
    iot_policy                  = string
    ingestion_function          = string
    status_function             = string
    check_function              = string
    push_application            = string
    sms_config_set              = string
    sms_status_logs             = string
  })

  validation {
    condition     = can(regex("^[a-zA-Z0-9_]{1,128}$", var.names.telemetry_rule))
    error_message = "names.telemetry_rule may hold only letters, digits and underscores."
  }

  validation {
    condition     = can(regex("^[a-z0-9_]{1,255}$", var.names.archive_database)) && can(regex("^[a-z0-9_]{1,255}$", var.names.archive_table))
    error_message = "names.archive_database and names.archive_table may hold only lowercase letters, digits and underscores."
  }

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.names.archive_bucket))
    error_message = "names.archive_bucket must be a valid S3 bucket name."
  }

  validation {
    condition = alltrue([
      for name in [var.names.ingestion_function, var.names.status_function, var.names.check_function] : can(regex("^[a-zA-Z0-9_-]{1,64}$", name))
    ])
    error_message = "Function names may hold up to 64 letters, digits, hyphens and underscores."
  }
}

variable "thing_groups" {
  description = "Thing group of each department, keyed by department code, with the final group name as value."
  type        = map(string)

  validation {
    condition     = length(var.thing_groups) > 0
    error_message = "thing_groups needs at least one department."
  }

  validation {
    condition     = alltrue([for department, name in var.thing_groups : can(regex("^[a-z0-9-]{1,32}$", department)) && can(regex("^[a-zA-Z0-9:_-]{1,128}$", name))])
    error_message = "Department codes use lowercase letters, digits and hyphens, and group names use letters, digits, colons, hyphens and underscores."
  }
}

variable "function_packages" {
  description = "Deployment package of each function, keyed ingestion, delivery_status and delivery_check. The module deploys the package and holds no function code."
  type = map(object({
    path    = string
    handler = optional(string, "main.handler")
    runtime = optional(string, "python3.13")
  }))

  validation {
    condition     = toset(keys(var.function_packages)) == toset(["ingestion", "delivery_status", "delivery_check"])
    error_message = "function_packages must hold exactly ingestion, delivery_status and delivery_check."
  }

  validation {
    condition     = alltrue([for package in values(var.function_packages) : endswith(package.path, ".zip")])
    error_message = "Each package path must point to a .zip file."
  }
}

variable "alert_ranges" {
  description = "Initial ranges, written once as version 1 of each zone type and variable. Later versions come from the platform API, and Terraform never overwrites an item it wrote."
  type = list(object({
    zone_type  = string
    variable   = string
    unit       = string
    valid_from = string
    reason     = string
    alert = optional(object({
      min          = optional(number)
      max          = optional(number)
      min_included = optional(bool, true)
      max_included = optional(bool, true)
    }))
    recommended = optional(object({
      min = number
      max = number
    }))
    reference = optional(object({
      target    = number
      tolerance = optional(number)
    }))
  }))

  validation {
    condition     = alltrue([for range in var.alert_ranges : contains(["cultivation", "drying"], range.zone_type)])
    error_message = "zone_type must be cultivation or drying."
  }

  validation {
    condition     = length(distinct([for range in var.alert_ranges : "${range.zone_type}/${range.variable}"])) == length(var.alert_ranges)
    error_message = "Each zone type and variable may appear once in alert_ranges."
  }

  validation {
    condition     = alltrue([for range in var.alert_ranges : can(regex("^[a-z][a-z0-9_]*$", range.variable)) && length(trimspace(range.unit)) > 0 && length(trimspace(range.reason)) > 0])
    error_message = "Each range needs a variable named like a message field, a unit and a reason."
  }

  validation {
    condition     = alltrue([for range in var.alert_ranges : can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", range.valid_from))])
    error_message = "valid_from must be a UTC time such as 2026-11-10T00:00:00Z."
  }

  validation {
    condition     = alltrue([for range in var.alert_ranges : range.alert != null || range.recommended != null || range.reference != null])
    error_message = "Each range needs an alert range, a recommended range or a reference."
  }

  validation {
    condition = alltrue([
      for range in var.alert_ranges :
      range.alert == null ? true : (
        (range.alert.min != null || range.alert.max != null) &&
        (range.alert.min == null || range.alert.max == null || try(range.alert.min < range.alert.max, false))
      )
    ])
    error_message = "An alert range needs a min or a max, and min must be below max."
  }

  validation {
    condition     = alltrue([for range in var.alert_ranges : range.recommended == null ? true : try(range.recommended.min < range.recommended.max, false)])
    error_message = "A recommended range needs min below max."
  }
}

variable "force_destroy_data" {
  description = "Lets a destroy remove tables and the archive while they hold data. Keep it false where data must survive."
  type        = bool
  default     = false
}
