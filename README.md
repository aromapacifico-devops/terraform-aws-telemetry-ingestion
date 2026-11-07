# terraform-aws-telemetry-ingestion

Critical data path of the Aroma Pacifico platform. The module receives each farm reading from AWS IoT Core, keeps a complete archive in S3, processes it through a queue and stores it in DynamoDB, where it can raise an alert for the farmer. It implements box C07 of the implementation scope.

This repository holds the skeleton and the interface the module commits to. The resources arrive with the first release, and no version tag exists yet.

## Path of a reading

1. The node publishes over MQTT with TLS on port 8883, QoS 1, using its device certificate.
2. An IoT rule validates the topic, adds `received_at` and sends the message to two destinations.
3. Amazon Data Firehose receives one copy and writes Parquet files to the S3 archive.
4. An SQS queue receives the other copy.
5. A Lambda function reads batches, validates the contract and writes to DynamoDB with a conditional write.
6. The function compares the reading with the current ranges and raises an alert through SNS on a change of state.

The queue sits between IoT Core and the function, so a slow or failing function loses nothing. Firehose takes its copy straight from the rule, so the archive stays complete even if the function fails.

## What it creates

| Resource | Purpose |
|---|---|
| IoT topic rule | Filters `aroma/{env}/farm/+/+`, adds `received_at` and sends to the queue and to Firehose |
| IoT policy | Lets a node publish only on topics with its own identifier and use only its own shadow |
| IoT thing groups | One per department, which the farm module joins |
| SQS queue and dead letter queue | Buffer for the function, with three retries before a message moves aside |
| Firehose delivery stream | Parquet files, partitioned by `stream/year/month/day/` of arrival |
| S3 archive bucket | Five years of telemetry through a lifecycle rule |
| Lambda function and event source mapping | Ingestion, with `ReportBatchItemFailures` so that a good message in a failed batch is not processed again |
| Readings, ranges and alerts tables | Recent history, thresholds and five years of alerts |
| SNS topic | Delivery of alerts |

The function code stays out of this module. It receives a deployment package, since the project builds no application logic.

## What it leaves to other modules

Roles and keys come from the security module, and this module creates neither. It creates no network, because the path uses public service endpoints and managed services.

## Message contract

The topic format is `aroma/{env}/farm/{node_id}/{stream}`, where stream is `crop` or `drying`. The environment in the topic keeps test and production apart, since both can share an account and its IoT broker. The rule of each environment listens only to its own prefix.

The idempotency key is `node_id` with `measured_at` and `seq`. QoS 1 can repeat a message, so the readings table uses a conditional write, and a repeat creates no second reading or second alert.

## Stores

| Store | Key | Retention |
|---|---|---|
| Readings table | Partition `node_id`, sort `measured_at#seq` | 90 days through TTL |
| Alert state items, in the readings table | Partition `node_id`, sort `state#<variable>` | Current values |
| Ranges table | Partition `zone_type`, sort `variable` | Current values |
| Alerts table | Partition `farm_id`, sort `raised_at` | Five years |
| Telemetry archive | Parquet by arrival date | Five years |

## Usage

Use the latest released tag in place of `v1.0.0`.

```hcl
module "telemetry_ingestion" {
  source = "git::https://github.com/aromapacifico-devops/terraform-aws-telemetry-ingestion.git?ref=v1.0.0"

  providers = {
    aws.project = aws.principal
  }

  client      = var.client
  project     = var.project
  environment = var.environment

  data_key_arn      = module.security.data_key_arn
  objects_key_arn   = module.security.objects_key_arn
  function_role_arn = module.security.ingestion_function_role_arn
  iot_rule_role_arn = module.security.iot_rule_role_arn
  firehose_role_arn = module.security.firehose_role_arn

  names                 = local.ingestion_names
  departments           = var.departments
  function_package_path = var.ingestion_package_path
  force_destroy_data    = var.force_destroy_data
}
```

## Inputs

| Name | Type | Required | Description |
|---|---|---|---|
| `client`, `project`, `environment`, `additional_tags` | Governance | See below | Codes for tags and the extra tags of the module. `additional_tags` is optional |
| `data_key_arn` | `string` | Yes | Key of the tables |
| `objects_key_arn` | `string` | Yes | Key of the archive |
| `function_role_arn` | `string` | Yes | Role of the ingestion function |
| `iot_rule_role_arn` | `string` | Yes | Role of the IoT rule |
| `firehose_role_arn` | `string` | Yes | Role of the delivery stream |
| `names` | `object` | Yes | Final names of the resources, built by the root |
| `departments` | `set(string)` | Yes | Departments that get a thing group |
| `function_package_path` | `string` | Yes | Deployment package of the function |
| `force_destroy_data` | `bool` | No | Lets a destroy remove data. Defaults to `false`, and the production environment of the pilot keeps it off |

## Outputs

| Name | Description |
|---|---|
| `iot_policy_name` | Policy the farm module attaches to each certificate |
| `iot_topic_rule_name` | Name of the rule |
| `thing_group_names` | Thing group of each department |
| `queue_arn` | ARN of the queue |
| `dead_letter_queue_arn` | ARN of the dead letter queue |
| `readings_table_arn` | ARN of the readings table |
| `archive_bucket_arn` | ARN of the archive bucket |
| `alert_topic_arn` | ARN of the alert topic |

## Names

The convention `{client}-{project}-{environment}-{type}-{key}` uses hyphens, and an IoT rule name accepts only letters, numbers and underscores. The root replaces the hyphens in that one name, which the exceptions file records.

## Destroying an environment

The standard `prevent_destroy` setting cannot depend on a variable, and it would block the nightly destroy that protects the credits. Tables use DynamoDB deletion protection and buckets use `force_destroy`, both driven by `force_destroy_data`, so the data of the pilot stays protected and the demonstration comes down cleanly.

## Cost

The module has no hourly charge and costs almost nothing while idle, since every service bills per message or per stored byte.

## Develop and test

The exact Terraform version lives in `.terraform-version`. Tests run against a mocked provider, so they need no AWS account and spend no credits.

```bash
terraform init -backend=false
terraform test
terraform -chdir=sample init -backend=false
terraform -chdir=sample validate
```

`terraform validate` runs on `sample/` because this module declares the `aws.project` provider alias, which only receives a provider from a caller.

The shared checks of the organization cover format, tests, TFLint, Checkov and secret scanning. An accepted finding goes in `docs/iac-exceptions.md` with its reason and its end condition.

## Versions

Commits follow Conventional Commits, and they decide the next version. A `fix` raises the patch, a `feat` raises the minor, and a breaking change raises the major. Each release publishes an exact `vX.Y.Z` tag and updates `CHANGELOG.md`. Consumers pin that tag, so a new version reaches an environment only through a reviewed change in the infrastructure repository.

## Related repositories

| Repository | Role |
|---|---|
| [`aromapacifico-devops-infra`](https://github.com/aromapacifico-devops/aromapacifico-devops-infra) | Roots of each environment, which consume this module |
| [`terraform-aws-module-template`](https://github.com/aromapacifico-devops/terraform-aws-module-template) | Template this repository was generated from |
| [`aromapacifico-devops-docs`](https://github.com/aromapacifico-devops/aromapacifico-devops-docs) | Architecture and design documents |
