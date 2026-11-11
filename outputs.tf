# Outputs of the module. Each one exposes a single attribute and has a description.
output "iot_policy_name" {
  description = "Name of the node policy, which the farm module attaches to each certificate."
  value       = aws_iot_policy.node.name
}

output "thing_group_names" {
  description = "Name of the thing group of each department, keyed by department code."
  value       = { for department, group in aws_iot_thing_group.departments : department => group.name }
}

output "iot_topic_rule_name" {
  description = "Name of the telemetry rule of this environment."
  value       = aws_iot_topic_rule.telemetry.name
}

output "topic_filter" {
  description = "Topic filter of this environment, which its rule listens to."
  value       = "${local.topic_prefix}/+/+"
}

output "queue_arn" {
  description = "ARN of the ingestion queue."
  value       = aws_sqs_queue.ingestion.arn
}

output "dead_letter_queue_arn" {
  description = "ARN of the dead letter queue of the ingestion queue."
  value       = aws_sqs_queue.ingestion_dead_letter.arn
}

output "delivery_queue_arn" {
  description = "ARN of the delay queue of delivery checks."
  value       = aws_sqs_queue.delivery.arn
}

output "readings_table_arn" {
  description = "ARN of the readings table."
  value       = aws_dynamodb_table.readings.arn
}

output "ranges_table_arn" {
  description = "ARN of the ranges table."
  value       = aws_dynamodb_table.ranges.arn
}

output "alerts_table_arn" {
  description = "ARN of the alerts table."
  value       = aws_dynamodb_table.alerts.arn
}

output "archive_bucket_arn" {
  description = "ARN of the telemetry archive bucket."
  value       = aws_s3_bucket.archive.arn
}

output "push_application_arn" {
  description = "ARN of the Firebase Cloud Messaging platform application."
  value       = aws_sns_platform_application.fcm.arn
}

output "function_arns" {
  description = "ARN of each function, keyed ingestion, delivery_status and delivery_check."
  value       = { for key, function in aws_lambda_function.functions : key => function.arn }
}
