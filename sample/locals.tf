# Transformations of the sample. The final resource names and the payload of the module are built here.
locals {
  name_prefix = "${var.client}-${var.project}-${var.environment}"
  underscored = replace(local.name_prefix, "-", "_")

  role_names = {
    ingestion_function       = "${local.name_prefix}-role-ingest"
    iot_rule                 = "${local.name_prefix}-role-iotrule"
    firehose_delivery        = "${local.name_prefix}-role-firehose"
    delivery_status_function = "${local.name_prefix}-role-dlvstat"
    delivery_check_function  = "${local.name_prefix}-role-dlvcheck"
    push_status_logs         = "${local.name_prefix}-role-pushlogs"
    sms_status_logs          = "${local.name_prefix}-role-smslogs"
  }

  names = {
    ingestion_queue             = "${local.name_prefix}-sqs-ingest"
    ingestion_dead_letter_queue = "${local.name_prefix}-sqs-ingest-dlq"
    delivery_queue              = "${local.name_prefix}-sqs-dlvcheck"
    delivery_dead_letter_queue  = "${local.name_prefix}-sqs-dlvcheck-dlq"
    readings_table              = "${local.name_prefix}-ddb-readings"
    ranges_table                = "${local.name_prefix}-ddb-ranges"
    alerts_table                = "${local.name_prefix}-ddb-alerts"
    farms_table                 = "${local.name_prefix}-ddb-farms"
    archive_bucket              = "${local.name_prefix}-s3-archive"
    archive_stream              = "${local.name_prefix}-fh-archive"
    archive_database            = "${local.underscored}_telemetry"
    archive_table               = "readings"
    telemetry_rule              = "${local.underscored}_rule_telemetry"
    iot_policy                  = "${local.name_prefix}-iotpol-node"
    ingestion_function          = "${local.name_prefix}-fn-ingest"
    status_function             = "${local.name_prefix}-fn-dlvstatus"
    check_function              = "${local.name_prefix}-fn-dlvcheck"
    push_application            = "${local.name_prefix}-push-fcm"
    sms_config_set              = "${local.name_prefix}-sms-alerts"
    sms_status_logs             = "/aws/sms/${local.name_prefix}-status"
  }

  thing_groups = { for department in var.departments : department => "${local.name_prefix}-thg-${department}" }

  function_packages = {
    for function in ["ingestion", "delivery_status", "delivery_check"] : function => { path = var.function_package_path }
  }
}
