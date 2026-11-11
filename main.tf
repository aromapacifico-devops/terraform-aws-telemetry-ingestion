# Resources of the module. Every resource sets provider = aws.project.

# Node identity shared by every farm: policy and department groups. The farm module attaches them.
resource "aws_iot_policy" "node" {
  provider = aws.project

  name   = var.names.iot_policy
  policy = jsonencode(local.node_policy)

  tags = merge(var.additional_tags, { Name = var.names.iot_policy })
}

resource "aws_iot_thing_group" "departments" {
  for_each = var.thing_groups
  provider = aws.project

  name = each.value

  properties {
    description = "Farm nodes of department ${each.key}"

    attribute_payload {
      attributes = { department = each.key }
    }
  }

  tags = merge(var.additional_tags, { Name = each.value })
}

# Rule of this environment. It adds the arrival time and sends one copy to the queue and one to the archive.
resource "aws_iot_topic_rule" "telemetry" {
  provider = aws.project

  name        = var.names.telemetry_rule
  description = "Telemetry of the ${var.environment} farm nodes"
  enabled     = true
  sql         = local.rule_sql
  sql_version = "2016-03-23"

  sqs {
    queue_url  = aws_sqs_queue.ingestion.url
    role_arn   = var.role_arns.iot_rule
    use_base64 = false
  }

  firehose {
    delivery_stream_name = aws_kinesis_firehose_delivery_stream.archive.name
    role_arn             = var.role_arns.iot_rule
    batch_mode           = false
  }

  tags = merge(var.additional_tags, { Name = var.names.telemetry_rule })
}

# Queues. A message moves to its dead letter queue after the first receive and three retries.
resource "aws_sqs_queue" "ingestion_dead_letter" {
  provider = aws.project

  name                              = var.names.ingestion_dead_letter_queue
  message_retention_seconds         = 1209600
  kms_master_key_id                 = var.data_key_arn
  kms_data_key_reuse_period_seconds = 300

  tags = merge(var.additional_tags, { Name = var.names.ingestion_dead_letter_queue })
}

resource "aws_sqs_queue" "ingestion" {
  provider = aws.project

  name                              = var.names.ingestion_queue
  visibility_timeout_seconds        = 180
  kms_master_key_id                 = var.data_key_arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingestion_dead_letter.arn
    maxReceiveCount     = 4
  })

  tags = merge(var.additional_tags, { Name = var.names.ingestion_queue })
}

resource "aws_sqs_queue" "delivery_dead_letter" {
  provider = aws.project

  name                              = var.names.delivery_dead_letter_queue
  message_retention_seconds         = 1209600
  kms_master_key_id                 = var.data_key_arn
  kms_data_key_reuse_period_seconds = 300

  tags = merge(var.additional_tags, { Name = var.names.delivery_dead_letter_queue })
}

# Each alert waits here 5 minutes before its delivery check.
resource "aws_sqs_queue" "delivery" {
  provider = aws.project

  name                              = var.names.delivery_queue
  delay_seconds                     = 300
  visibility_timeout_seconds        = 180
  kms_master_key_id                 = var.data_key_arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.delivery_dead_letter.arn
    maxReceiveCount     = 4
  })

  tags = merge(var.additional_tags, { Name = var.names.delivery_queue })
}

# Tables. Deletion protection follows force_destroy_data.
resource "aws_dynamodb_table" "readings" {
  provider = aws.project

  name                        = var.names.readings_table
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "node_id"
  range_key                   = "sk"
  deletion_protection_enabled = !var.force_destroy_data

  attribute {
    name = "node_id"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.data_key_arn
  }

  tags = merge(var.additional_tags, { Name = var.names.readings_table })
}

resource "aws_dynamodb_table" "ranges" {
  provider = aws.project

  name                        = var.names.ranges_table
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "zone_type"
  range_key                   = "variable#valid_from"
  deletion_protection_enabled = !var.force_destroy_data

  attribute {
    name = "zone_type"
    type = "S"
  }

  attribute {
    name = "variable#valid_from"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.data_key_arn
  }

  tags = merge(var.additional_tags, { Name = var.names.ranges_table })
}

# Version 1 only. The item is never updated, so a version published through the API stays untouched.
resource "aws_dynamodb_table_item" "initial_ranges" {
  for_each = local.range_items
  provider = aws.project

  table_name = aws_dynamodb_table.ranges.name
  hash_key   = aws_dynamodb_table.ranges.hash_key
  range_key  = aws_dynamodb_table.ranges.range_key
  item       = each.value

  lifecycle {
    ignore_changes = [item]
  }
}

resource "aws_dynamodb_table" "alerts" {
  provider = aws.project

  name                        = var.names.alerts_table
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "farm_id"
  range_key                   = "raised_at"
  deletion_protection_enabled = !var.force_destroy_data

  attribute {
    name = "farm_id"
    type = "S"
  }

  attribute {
    name = "raised_at"
    type = "S"
  }

  attribute {
    name = local.push_message_index
    type = "S"
  }

  # Sparse, since only alerts already published carry the attribute.
  global_secondary_index {
    name            = local.push_message_index
    projection_type = "KEYS_ONLY"

    key_schema {
      attribute_name = local.push_message_index
      key_type       = "HASH"
    }
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.data_key_arn
  }

  tags = merge(var.additional_tags, { Name = var.names.alerts_table })
}

# Archive of every message, in Parquet, for five years.
resource "aws_s3_bucket" "archive" {
  #checkov:skip=CKV2_AWS_62:Firehose writes the archive and nothing reacts to each object, see docs/iac-exceptions.md
  #checkov:skip=CKV_AWS_18:Only Firehose writes and Athena reads the archive, see docs/iac-exceptions.md
  #checkov:skip=CKV_AWS_144:The pilot runs in one Region, see docs/iac-exceptions.md
  provider = aws.project

  bucket        = var.names.archive_bucket
  force_destroy = var.force_destroy_data

  tags = merge(var.additional_tags, { Name = var.names.archive_bucket })
}

resource "aws_s3_bucket_public_access_block" "archive" {
  provider = aws.project

  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "archive" {
  provider = aws.project

  bucket = aws_s3_bucket.archive.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  provider = aws.project

  bucket = aws_s3_bucket.archive.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.objects_key_arn
    }
  }
}

resource "aws_s3_bucket_versioning" "archive" {
  provider = aws.project

  bucket = aws_s3_bucket.archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  provider = aws.project

  bucket = aws_s3_bucket.archive.id

  rule {
    id     = "five-years"
    status = "Enabled"

    filter {}

    expiration {
      days = local.archive_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.archive]
}

resource "aws_s3_bucket_policy" "archive" {
  provider = aws.project

  bucket = aws_s3_bucket.archive.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.archive.arn, "${aws_s3_bucket.archive.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.archive]
}

# Schema that Firehose uses to write Parquet. Partition projection lets Athena read it with no crawler.
resource "aws_glue_catalog_database" "archive" {
  provider = aws.project

  name        = var.names.archive_database
  description = "Telemetry archive of ${var.environment}"

  tags = merge(var.additional_tags, { Name = var.names.archive_database })
}

resource "aws_glue_catalog_table" "archive" {
  provider = aws.project

  name          = var.names.archive_table
  database_name = aws_glue_catalog_database.archive.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL                    = "TRUE"
    classification              = "parquet"
    "projection.enabled"        = "true"
    "projection.stream.type"    = "enum"
    "projection.stream.values"  = join(",", local.streams)
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2026,2040"
    "projection.month.type"     = "integer"
    "projection.month.range"    = "1,12"
    "projection.month.digits"   = "2"
    "projection.day.type"       = "integer"
    "projection.day.range"      = "1,31"
    "projection.day.digits"     = "2"
    "storage.location.template" = "s3://${var.names.archive_bucket}/$${stream}/year=$${year}/month=$${month}/day=$${day}/"
  }

  dynamic "partition_keys" {
    for_each = ["stream", "year", "month", "day"]

    content {
      name = partition_keys.value
      type = "string"
    }
  }

  storage_descriptor {
    location      = "s3://${var.names.archive_bucket}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = local.archive_columns

      content {
        name = columns.key
        type = columns.value
      }
    }
  }
}

resource "aws_kinesis_firehose_delivery_stream" "archive" {
  #checkov:skip=CKV_AWS_241:Records wait at most 900 seconds under the AWS owned key and land under the objects key, see docs/iac-exceptions.md
  provider = aws.project

  name        = var.names.archive_stream
  destination = "extended_s3"

  server_side_encryption {
    enabled  = true
    key_type = "AWS_OWNED_CMK"
  }

  extended_s3_configuration {
    role_arn            = var.role_arns.firehose_delivery
    bucket_arn          = aws_s3_bucket.archive.arn
    prefix              = local.archive_prefix
    error_output_prefix = local.error_prefix
    buffering_size      = 64
    buffering_interval  = 900

    dynamic_partitioning_configuration {
      enabled = true
    }

    processing_configuration {
      enabled = true

      processors {
        type = "MetadataExtraction"

        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }

        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{stream:.stream}"
        }
      }
    }

    data_format_conversion_configuration {
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {}
        }
      }

      schema_configuration {
        database_name = aws_glue_catalog_database.archive.name
        table_name    = aws_glue_catalog_table.archive.name
        role_arn      = var.role_arns.firehose_delivery
      }
    }
  }

  tags = merge(var.additional_tags, { Name = var.names.archive_stream })
}

# Log groups of the functions and of the push and SMS status, which hold tokens and phone numbers for 30 days.
resource "aws_cloudwatch_log_group" "logs" {
  #checkov:skip=CKV_AWS_338:Operational logs keep 30 days, see docs/iac-exceptions.md
  for_each = local.log_groups
  provider = aws.project

  name              = each.value
  retention_in_days = 30
  kms_key_id        = var.data_key_arn

  tags = merge(var.additional_tags, { Name = each.value })
}

# Functions. The packages come from the caller, and this module holds no function code.
resource "aws_lambda_function" "functions" {
  #checkov:skip=CKV_AWS_115:The account allows 10 concurrent executions and the mappings cap pollers, see docs/iac-exceptions.md
  #checkov:skip=CKV_AWS_116:Queue functions use the dead letter queue of their queue, see docs/iac-exceptions.md
  #checkov:skip=CKV_AWS_117:The functions call regional AWS APIs only, see docs/iac-exceptions.md
  #checkov:skip=CKV_AWS_173:Environment variables hold names only, see docs/iac-exceptions.md
  #checkov:skip=CKV_AWS_272:No signing profile exists yet, see docs/iac-exceptions.md
  #checkov:skip=CKV_AWS_50:Traces are outside the current observability design, see docs/iac-exceptions.md
  for_each = local.functions
  provider = aws.project

  function_name    = each.value.name
  role             = each.value.role_arn
  filename         = var.function_packages[each.key].path
  source_code_hash = filebase64sha256(var.function_packages[each.key].path)
  handler          = var.function_packages[each.key].handler
  runtime          = var.function_packages[each.key].runtime
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 30

  environment {
    variables = each.value.environment
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.logs[each.key].name
  }

  tags = merge(var.additional_tags, { Name = each.value.name })
}

# Batches of 10 with no wait, failures reported per message. Two pollers at most keep a burst in the queue.
resource "aws_lambda_event_source_mapping" "queues" {
  for_each = local.queue_triggers
  provider = aws.project

  event_source_arn                   = each.value
  function_name                      = aws_lambda_function.functions[each.key].arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 2
  }

  tags = merge(var.additional_tags, { Name = "${aws_lambda_function.functions[each.key].function_name}-queue" })
}

resource "aws_lambda_permission" "status_logs" {
  for_each = local.status_log_groups
  provider = aws.project

  statement_id   = "status-logs-${replace(each.key, "_", "-")}"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.functions["delivery_status"].function_name
  principal      = "logs.amazonaws.com"
  source_arn     = "${aws_cloudwatch_log_group.logs[each.key].arn}:*"
  source_account = local.account_id
}

resource "aws_cloudwatch_log_subscription_filter" "status_logs" {
  for_each = local.status_log_groups
  provider = aws.project

  name            = "${var.names.status_function}-${replace(each.key, "_", "-")}"
  log_group_name  = aws_cloudwatch_log_group.logs[each.key].name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.functions["delivery_status"].arn

  depends_on = [aws_lambda_permission.status_logs]
}

# SMS of urgent alerts, with every event of the carrier written to the status log group.
resource "aws_pinpointsmsvoicev2_configuration_set" "alerts" {
  provider = aws.project

  name = var.names.sms_config_set

  tags = merge(var.additional_tags, { Name = var.names.sms_config_set })
}

resource "aws_pinpointsmsvoicev2_event_destination" "sms_status" {
  provider = aws.project

  configuration_set_name = aws_pinpointsmsvoicev2_configuration_set.alerts.name
  event_destination_name = "status-logs"
  matching_event_types   = ["TEXT_ALL"]

  cloudwatch_logs_destination {
    iam_role_arn  = var.role_arns.sms_status_logs
    log_group_arn = aws_cloudwatch_log_group.logs["sms_status"].arn
  }
}
