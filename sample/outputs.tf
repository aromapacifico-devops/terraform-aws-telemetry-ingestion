# Outputs that prove the sample worked.
output "topic_filter" {
  description = "Topic filter the rule of the sample listens to."
  value       = module.this.topic_filter
}

output "iot_policy_name" {
  description = "Node policy for the farm module."
  value       = module.this.iot_policy_name
}

output "thing_group_names" {
  description = "Thing group of each department."
  value       = module.this.thing_group_names
}
