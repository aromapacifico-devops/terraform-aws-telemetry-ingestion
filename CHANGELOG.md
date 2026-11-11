# Changelog

## [Unreleased]

### Added

- Ingestion path. IoT rule per environment prefix with `received_at`, `link` and `topic_node_id`, node policy limited to its own topics and shadow, thing group per department, ingestion queue with its dead letter queue, and the ingestion function with batches of 10, no batching window and batch item failures.
- Stores. Readings table with TTL, ranges table keyed by `variable#valid_from` with the initial ranges as version 1, alerts table with a sparse index on `push_message_id`, all with the data key and point-in-time recovery.
- Telemetry archive. Versioned S3 bucket with the objects key and five-year lifecycle, Glue schema with partition projection, and a Firehose stream that writes Parquet by stream and arrival date.
- Alert delivery. Delivery check queue with a delay of 300 seconds, delivery status and delivery check functions, push and SMS status log groups of 30 days with subscription filters, Firebase Cloud Messaging platform application with feedback at 100 percent, and SMS configuration set with a log destination.

### Changed

- Inputs take the keys, the role of each purpose in `role_arns`, the final names, the thing groups, the function packages and `alert_ranges`. Output `alert_topic_arn` is replaced by `push_application_arn`, since alerts go to phone endpoints.
