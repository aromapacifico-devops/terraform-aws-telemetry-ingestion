# Plan-time tests against a mocked provider. They need no AWS account.
mock_provider "aws" {
  alias = "project"

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }

  override_resource {
    target          = aws_sqs_queue.ingestion_dead_letter
    override_during = plan
    values          = { arn = "arn:aws:sqs:us-east-1:111122223333:fnc-aroma-test-sqs-ingest-dlq" }
  }

  override_resource {
    target          = aws_sqs_queue.delivery_dead_letter
    override_during = plan
    values          = { arn = "arn:aws:sqs:us-east-1:111122223333:fnc-aroma-test-sqs-dlvcheck-dlq" }
  }
}

variables {
  client      = "fnc"
  project     = "aroma"
  environment = "test"

  data_key_arn    = "arn:aws:kms:us-east-1:111122223333:key/data"
  objects_key_arn = "arn:aws:kms:us-east-1:111122223333:key/objects"

  role_arns = {
    ingestion_function       = "arn:aws:iam::111122223333:role/fnc-aroma-test-role-ingest"
    iot_rule                 = "arn:aws:iam::111122223333:role/fnc-aroma-test-role-iotrule"
    firehose_delivery        = "arn:aws:iam::111122223333:role/fnc-aroma-test-role-firehose"
    delivery_status_function = "arn:aws:iam::111122223333:role/fnc-aroma-test-role-dlvstat"
    delivery_check_function  = "arn:aws:iam::111122223333:role/fnc-aroma-test-role-dlvcheck"
    push_status_logs         = "arn:aws:iam::111122223333:role/fnc-aroma-test-role-pushlogs"
    sms_status_logs          = "arn:aws:iam::111122223333:role/fnc-aroma-test-role-smslogs"
  }

  names = {
    ingestion_queue             = "fnc-aroma-test-sqs-ingest"
    ingestion_dead_letter_queue = "fnc-aroma-test-sqs-ingest-dlq"
    delivery_queue              = "fnc-aroma-test-sqs-dlvcheck"
    delivery_dead_letter_queue  = "fnc-aroma-test-sqs-dlvcheck-dlq"
    readings_table              = "fnc-aroma-test-ddb-readings"
    ranges_table                = "fnc-aroma-test-ddb-ranges"
    alerts_table                = "fnc-aroma-test-ddb-alerts"
    farms_table                 = "fnc-aroma-test-ddb-farms"
    archive_bucket              = "fnc-aroma-test-s3-archive"
    archive_stream              = "fnc-aroma-test-fh-archive"
    archive_database            = "fnc_aroma_test_telemetry"
    archive_table               = "readings"
    telemetry_rule              = "fnc_aroma_test_rule_telemetry"
    iot_policy                  = "fnc-aroma-test-iotpol-node"
    ingestion_function          = "fnc-aroma-test-fn-ingest"
    status_function             = "fnc-aroma-test-fn-dlvstatus"
    check_function              = "fnc-aroma-test-fn-dlvcheck"
    push_application            = "fnc-aroma-test-push-fcm"
    sms_config_set              = "fnc-aroma-test-sms-alerts"
    sms_status_logs             = "/aws/sms/fnc-aroma-test-status"
  }

  thing_groups = {
    cauca = "fnc-aroma-test-thg-cauca"
    huila = "fnc-aroma-test-thg-huila"
  }

  function_packages = {
    ingestion       = { path = "tests/fixtures/function.zip" }
    delivery_status = { path = "tests/fixtures/function.zip" }
    delivery_check  = { path = "tests/fixtures/function.zip" }
  }

  alert_ranges = [
    {
      zone_type   = "cultivation"
      variable    = "ph"
      unit        = "pH"
      valid_from  = "2026-11-10T00:00:00Z"
      reason      = "Initial range of the pilot"
      alert       = { min = 4.5, max = 6.0 }
      recommended = { min = 4.9, max = 5.6 }
    },
    {
      zone_type  = "drying"
      variable   = "grain_temp_c"
      unit       = "°C"
      valid_from = "2026-11-10T00:00:00Z"
      reason     = "Initial range of the pilot"
      alert      = { max = 40, max_included = false }
    },
    {
      zone_type  = "drying"
      variable   = "grain_humidity_pct"
      unit       = "percent"
      valid_from = "2026-11-10T00:00:00Z"
      reason     = "Initial reference of the pilot"
      reference  = { target = 12 }
    },
  ]
}

run "rule_listens_only_to_its_environment" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  assert {
    condition     = endswith(aws_iot_topic_rule.telemetry.sql, "FROM 'aroma/test/farm/+/+'")
    error_message = "The rule must listen only to the prefix of its environment."
  }

  assert {
    condition     = strcontains(aws_iot_topic_rule.telemetry.sql, "AS received_at")
    error_message = "The rule must add received_at."
  }

  assert {
    condition     = length(aws_iot_topic_rule.telemetry.sqs) == 1 && length(aws_iot_topic_rule.telemetry.firehose) == 1
    error_message = "The rule must send one copy to the queue and one to the archive."
  }
}

run "node_policy_is_limited_to_its_own_topics_and_shadow" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  assert {
    condition = toset(jsondecode(aws_iot_policy.node.policy).Statement[1].Resource) == toset([
      "arn:aws:iot:us-east-1:111122223333:topic/aroma/test/farm/$${iot:Connection.Thing.ThingName}/crop",
      "arn:aws:iot:us-east-1:111122223333:topic/aroma/test/farm/$${iot:Connection.Thing.ThingName}/drying",
      "arn:aws:iot:us-east-1:111122223333:topic/$aws/things/$${iot:Connection.Thing.ThingName}/shadow/get",
      "arn:aws:iot:us-east-1:111122223333:topic/$aws/things/$${iot:Connection.Thing.ThingName}/shadow/update",
    ])
    error_message = "A node may publish only on its own streams and its own shadow."
  }

  assert {
    condition     = jsondecode(aws_iot_policy.node.policy).Statement[0].Condition.Bool["iot:Connection.Thing.IsAttached"] == "true"
    error_message = "A node may connect only with the certificate attached to its thing."
  }

  assert {
    condition     = length(aws_iot_thing_group.departments) == 2
    error_message = "Each department gets one thing group."
  }
}

run "queues_follow_the_alert_budget" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  assert {
    condition = alltrue([
      for mapping in aws_lambda_event_source_mapping.queues :
      mapping.batch_size == 10 && mapping.maximum_batching_window_in_seconds == 0 && contains(mapping.function_response_types, "ReportBatchItemFailures") && mapping.scaling_config[0].maximum_concurrency == 2
    ])
    error_message = "Mappings use batches of 10, no batching window, failures per message and two pollers at most."
  }

  assert {
    condition     = aws_sqs_queue.delivery.delay_seconds == 300
    error_message = "Delivery checks wait 5 minutes."
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.ingestion.redrive_policy).maxReceiveCount == 4 && jsondecode(aws_sqs_queue.delivery.redrive_policy).maxReceiveCount == 4
    error_message = "A message moves aside after the first receive and three retries."
  }

  assert {
    condition     = alltrue([for queue in [aws_sqs_queue.ingestion, aws_sqs_queue.ingestion_dead_letter, aws_sqs_queue.delivery, aws_sqs_queue.delivery_dead_letter] : queue.kms_master_key_id == var.data_key_arn])
    error_message = "Queues use the data key."
  }
}

run "stores_keep_their_keys_and_retention" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  assert {
    condition     = aws_dynamodb_table.readings.ttl[0].attribute_name == "expires_at" && aws_dynamodb_table.readings.range_key == "sk"
    error_message = "Readings expire through TTL and share a sort key with the alert state items."
  }

  assert {
    condition     = aws_dynamodb_table.ranges.hash_key == "zone_type" && aws_dynamodb_table.ranges.range_key == "variable#valid_from"
    error_message = "The ranges table keeps versions by variable and time."
  }

  assert {
    condition     = one(one(aws_dynamodb_table.alerts.global_secondary_index).key_schema).attribute_name == "push_message_id"
    error_message = "The alerts table needs the index on push_message_id."
  }

  assert {
    condition     = alltrue([for table in [aws_dynamodb_table.readings, aws_dynamodb_table.ranges, aws_dynamodb_table.alerts] : table.point_in_time_recovery[0].enabled && table.server_side_encryption[0].kms_key_arn == var.data_key_arn && table.deletion_protection_enabled])
    error_message = "Tables use the data key, point-in-time recovery and deletion protection by default."
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.archive.rule).expiration[0].days == 1826 && !aws_s3_bucket.archive.force_destroy
    error_message = "The archive keeps five years and is protected by default."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.archive.rule).apply_server_side_encryption_by_default[0].kms_master_key_id == var.objects_key_arn
    error_message = "The archive uses the objects key."
  }

  assert {
    condition     = alltrue([for group in aws_cloudwatch_log_group.logs : group.retention_in_days == 30 && group.kms_key_id == var.data_key_arn])
    error_message = "Log groups keep 30 days and use the data key."
  }
}

run "initial_ranges_are_version_one" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  assert {
    condition     = length(aws_dynamodb_table_item.initial_ranges) == 3
    error_message = "Each zone type and variable gets one item."
  }

  assert {
    condition = (
      jsondecode(aws_dynamodb_table_item.initial_ranges["cultivation/ph"].item)["variable#valid_from"].S == "ph#2026-11-10T00:00:00Z" &&
      jsondecode(aws_dynamodb_table_item.initial_ranges["cultivation/ph"].item).version.N == "1" &&
      jsondecode(aws_dynamodb_table_item.initial_ranges["cultivation/ph"].item).alert.M.max.N == "6" &&
      jsondecode(aws_dynamodb_table_item.initial_ranges["cultivation/ph"].item).recommended.M.min.N == "4.9"
    )
    error_message = "The alert and recommended ranges of one variable share one version 1 item."
  }

  assert {
    condition     = !jsondecode(aws_dynamodb_table_item.initial_ranges["drying/grain_temp_c"].item).alert.M.max_included.BOOL && !contains(keys(jsondecode(aws_dynamodb_table_item.initial_ranges["drying/grain_temp_c"].item).alert.M), "min")
    error_message = "Grain above 40 °C has an open upper limit and no lower limit."
  }
}

run "push_feedback_logs_every_message" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  assert {
    condition     = aws_sns_platform_application.fcm.success_feedback_sample_rate == "100" && aws_sns_platform_application.fcm.failure_feedback_role_arn == var.role_arns.push_status_logs
    error_message = "Push status is logged for every message."
  }

  assert {
    condition     = aws_cloudwatch_log_group.logs["push_failure"].name == "sns/us-east-1/111122223333/app/GCM/fnc-aroma-test-push-fcm/Failure"
    error_message = "The failure log group carries the name SNS writes to."
  }

  assert {
    condition     = length(aws_cloudwatch_log_subscription_filter.status_logs) == 3
    error_message = "Push success, push failure and SMS status feed the delivery status function."
  }
}

run "force_destroy_data_opens_the_stores" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  variables {
    force_destroy_data = true
  }

  assert {
    condition     = aws_s3_bucket.archive.force_destroy && !aws_dynamodb_table.alerts.deletion_protection_enabled
    error_message = "force_destroy_data lets a destroy remove data."
  }
}

run "rejects_a_rule_name_with_hyphens" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  variables {
    names = merge(var.names, { telemetry_rule = "fnc-aroma-test-rule-telemetry" })
  }

  expect_failures = [var.names]
}

run "rejects_an_alert_range_with_min_above_max" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  variables {
    alert_ranges = [{
      zone_type  = "cultivation"
      variable   = "ph"
      unit       = "pH"
      valid_from = "2026-11-10T00:00:00Z"
      reason     = "Wrong limits"
      alert      = { min = 6.0, max = 4.5 }
    }]
  }

  expect_failures = [var.alert_ranges]
}

run "rejects_a_repeated_range" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  variables {
    alert_ranges = [
      { zone_type = "drying", variable = "grain_temp_c", unit = "°C", valid_from = "2026-11-10T00:00:00Z", reason = "First", alert = { max = 40 } },
      { zone_type = "drying", variable = "grain_temp_c", unit = "°C", valid_from = "2026-11-11T00:00:00Z", reason = "Second", alert = { max = 41 } },
    ]
  }

  expect_failures = [var.alert_ranges]
}

run "rejects_a_missing_function_package" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  variables {
    function_packages = { ingestion = { path = "tests/fixtures/function.zip" } }
  }

  expect_failures = [var.function_packages]
}

run "rejects_an_unknown_environment" {
  command = plan

  providers = {
    aws.project = aws.project
  }

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}
