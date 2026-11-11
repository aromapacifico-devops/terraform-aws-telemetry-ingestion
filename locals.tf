# Local values and transformations of the module.
locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # Each environment listens only to its own prefix, since environments share the account and its broker.
  topic_prefix = "${var.project}/${var.environment}/farm"
  streams      = ["crop", "drying"]

  rule_sql = "SELECT *, topic(4) AS topic_node_id, 'cellular' AS link, parse_time(\"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'\", timestamp()) AS received_at FROM '${local.topic_prefix}/+/+'"

  # IoT policy variable, escaped so that Terraform leaves it to IoT Core.
  thing = "$${iot:Connection.Thing.ThingName}"

  iot_arn = "arn:${local.partition}:iot:${local.region}:${local.account_id}"

  node_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["iot:Connect"]
        Resource  = ["${local.iot_arn}:client/${local.thing}"]
        Condition = { Bool = { "iot:Connection.Thing.IsAttached" = "true" } }
      },
      {
        Effect = "Allow"
        Action = ["iot:Publish"]
        Resource = concat(
          [for stream in local.streams : "${local.iot_arn}:topic/${local.topic_prefix}/${local.thing}/${stream}"],
          ["${local.iot_arn}:topic/$aws/things/${local.thing}/shadow/get", "${local.iot_arn}:topic/$aws/things/${local.thing}/shadow/update"]
        )
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Subscribe"]
        Resource = ["${local.iot_arn}:topicfilter/$aws/things/${local.thing}/shadow/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Receive"]
        Resource = ["${local.iot_arn}:topic/$aws/things/${local.thing}/shadow/*"]
      },
    ]
  }

  # SNS names the delivery status log groups of a platform application after the application.
  push_log_group = "sns/${local.region}/${local.account_id}/app/GCM/${var.names.push_application}"

  log_groups = {
    ingestion       = "/aws/lambda/${var.names.ingestion_function}"
    delivery_status = "/aws/lambda/${var.names.status_function}"
    delivery_check  = "/aws/lambda/${var.names.check_function}"
    push_success    = local.push_log_group
    push_failure    = "${local.push_log_group}/Failure"
    sms_status      = var.names.sms_status_logs
  }

  # Status logs feed the delivery status function.
  status_log_groups = toset(["push_success", "push_failure", "sms_status"])

  push_message_index = "push_message_id"

  functions = {
    ingestion = {
      name     = var.names.ingestion_function
      role_arn = var.role_arns.ingestion_function
      environment = {
        ENVIRONMENT          = var.environment
        READINGS_TABLE       = var.names.readings_table
        READINGS_TTL_DAYS    = "90"
        RANGES_TABLE         = var.names.ranges_table
        ALERTS_TABLE         = var.names.alerts_table
        FARMS_TABLE          = var.names.farms_table
        DELIVERY_QUEUE_URL   = aws_sqs_queue.delivery.url
        PUSH_APPLICATION_ARN = aws_sns_platform_application.fcm.arn
      }
    }
    delivery_status = {
      name     = var.names.status_function
      role_arn = var.role_arns.delivery_status_function
      environment = {
        ENVIRONMENT        = var.environment
        ALERTS_TABLE       = var.names.alerts_table
        PUSH_MESSAGE_INDEX = local.push_message_index
      }
    }
    delivery_check = {
      name     = var.names.check_function
      role_arn = var.role_arns.delivery_check_function
      environment = {
        ENVIRONMENT           = var.environment
        ALERTS_TABLE          = var.names.alerts_table
        FARMS_TABLE           = var.names.farms_table
        SMS_CONFIGURATION_SET = var.names.sms_config_set
      }
    }
  }

  # Queues that trigger a function, with the function they trigger.
  queue_triggers = {
    ingestion      = aws_sqs_queue.ingestion.arn
    delivery_check = aws_sqs_queue.delivery.arn
  }

  # Version 1 of each initial range, in DynamoDB JSON. Every kind of one variable lives in one item.
  range_items = {
    for range in var.alert_ranges : "${range.zone_type}/${range.variable}" => jsonencode(merge(
      {
        zone_type             = { S = range.zone_type }
        "variable#valid_from" = { S = "${range.variable}#${range.valid_from}" }
        unit                  = { S = range.unit }
        version               = { N = "1" }
        reason                = { S = range.reason }
        published_by          = { S = "terraform" }
        published_at          = { S = range.valid_from }
        reverts_to            = { NULL = true }
      },
      range.alert == null ? {} : {
        alert = { M = merge(
          range.alert.min == null ? {} : { min = { N = tostring(range.alert.min) } },
          range.alert.max == null ? {} : { max = { N = tostring(range.alert.max) } },
          { min_included = { BOOL = range.alert.min_included }, max_included = { BOOL = range.alert.max_included } }
        ) }
      },
      range.recommended == null ? {} : {
        recommended = { M = { min = { N = tostring(range.recommended.min) }, max = { N = tostring(range.recommended.max) } } }
      },
      range.reference == null ? {} : {
        reference = { M = merge(
          { target = { N = tostring(range.reference.target) } },
          range.reference.tolerance == null ? {} : { tolerance = { N = tostring(range.reference.tolerance) } }
        ) }
      }
    ))
  }

  # Columns of the archive. The stream travels in the path, so it is a partition and not a column.
  archive_columns = {
    schema        = "int"
    node_id       = "string"
    seq           = "bigint"
    measured_at   = "string"
    received_at   = "string"
    topic_node_id = "string"
    link          = "string"
    buffered      = "boolean"
    dropped_total = "bigint"
    values        = "struct<n_mg_kg:double,p_mg_kg:double,k_mg_kg:double,ph:double,soil_humidity_pct:double,soil_temp_c:double,air_humidity_pct:double,air_temp_c:double,grain_temp_c:double,grain_humidity_pct:double>"
  }

  archive_prefix = "!{partitionKeyFromQuery:stream}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
  error_prefix   = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

  # Five years plus a leap day.
  archive_retention_days = 1826
}
