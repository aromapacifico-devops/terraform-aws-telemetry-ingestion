# terraform-aws-telemetry-ingestion

Critical data path of the Aroma Pacifico platform. The module receives each farm reading from AWS IoT Core, keeps a complete archive in S3, processes it through a queue and stores it in DynamoDB, and it holds the pieces that bring an alert to the farmer's phone. It implements box C07 of the implementation scope.

## Contents

- [Terms](#terms)
- [Path of a reading](#path-of-a-reading)
- [What it creates](#what-it-creates)
- [What it leaves to other places](#what-it-leaves-to-other-places)
- [Message contract](#message-contract)
- [Stores](#stores)
- [Alert delivery](#alert-delivery)
- [Usage](#usage)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Names](#names)
- [Destroying an environment](#destroying-an-environment)
- [Cost](#cost)
- [Develop and test](#develop-and-test)
- [Versions](#versions)
- [Related repositories](#related-repositories)

## Terms

| Term | Meaning |
|---|---|
| Reading | One message from a node, with the time it was measured |
| Dead letter queue | Queue that keeps the messages a function could not process |
| Batch item failure | Answer of a function that names the messages of a batch that failed, so only those return to the queue |
| Platform application | SNS object that holds the push service credential, under which each phone gets an endpoint |
| Version 1 of a range | First item of an alert range, written by this module. Later versions come from the platform API |

## Path of a reading

1. The node publishes over MQTT with TLS on port 8883, QoS 1, using its device certificate.
2. The IoT rule of the environment takes only topics under `aroma/{env}/farm/`, adds `received_at`, the link and the node of the topic, and sends the message to two destinations.
3. Amazon Data Firehose receives one copy and writes Parquet files to the S3 archive.
4. An SQS queue receives the other copy.
5. The ingestion function reads batches of 10 with no batching window, writes to DynamoDB with a conditional write and reports failures per message.
6. When a reading leaves its range, the function writes the alert, publishes it to the phones of the farm and queues a delivery check that waits 5 minutes.

The queue sits between IoT Core and the function, so a slow or failing function loses nothing. Firehose takes its copy straight from the rule, so the archive stays complete even if the function fails.

## What it creates

| Resource | Purpose |
|---|---|
| IoT topic rule | Filters `aroma/{env}/farm/+/+`, adds `received_at`, `link` and `topic_node_id`, and sends to the queue and to Firehose |
| IoT policy | Lets a node connect only as its own thing, publish only on its own `crop` and `drying` topics, and use only its own shadow |
| IoT thing groups | One per department, which the farm module joins |
| Ingestion queue and its dead letter queue | Buffer for the ingestion function. A message moves aside after the first receive and three retries |
| Delivery check queue and its dead letter queue | Holds each alert for 300 seconds before the delivery check |
| Readings table | Readings for 90 days through TTL, and the alert state of each node and variable |
| Ranges table and version 1 items | Alert ranges by measured time, with the initial ranges written once |
| Alerts table | Five years of alerts and their delivery record, with a sparse index on `push_message_id` |
| S3 archive bucket | Parquet files for five years, versioned, encrypted and reachable only over TLS |
| Glue database and table | Schema that Firehose uses to write Parquet, with partition projection so Athena reads it with no crawler |
| Firehose delivery stream | Partitions by stream and arrival date, buffers up to 15 minutes |
| Ingestion, delivery status and delivery check functions | Deploy the packages they receive, on arm64 with 256 MB and 30 seconds |
| Event source mappings | Batch of 10, batching window 0, batch item failures reported, two pollers at most |
| Log groups | Functions, push status and SMS status, 30 days, encrypted with the data key |
| Subscription filters | Send push and SMS status entries to the delivery status function |
| SNS platform application | Firebase Cloud Messaging, with success and failure feedback at a sample rate of 100 |
| SMS configuration set | Urgent alerts by SMS, with every carrier event written to the SMS status log group |

## What it leaves to other places

| Need | Where it lives |
|---|---|
| Roles and keys | Security module. This module creates neither |
| Network | None. The path uses public service endpoints and managed services, and the functions run outside the VPC |
| Function code | The caller passes a package for each function |
| Push service credential | Loaded into SNS outside the infrastructure code, as described in [Alert delivery](#alert-delivery) |
| Farm register, receipt route and new range versions | Platform API |
| Apple push application | Added when an iPhone application exists |

## Message contract

The topic format is `aroma/{env}/farm/{node_id}/{stream}`, where stream is `crop` or `drying`. Environments share the account and its IoT broker, so the environment in the topic keeps them apart, and the rule of each environment listens only to its own prefix.

The rule adds three fields. `received_at` is the time the rules engine saw the message, in UTC with milliseconds. `link` is `cellular`, the path of every node that publishes over MQTT. `topic_node_id` is the node in the topic, which the policy ties to the certificate, so the function can reject a body that names another node.

The idempotency key is `node_id` with `measured_at` and `seq`. QoS 1 can repeat a message, so the readings table uses a conditional write, and a repeat creates no second reading or second alert.

## Stores

| Store | Key | Retention |
|---|---|---|
| Readings table | Partition `node_id`, sort `sk` with `measured_at#seq` | 90 days through TTL on `expires_at` |
| Alert state items, in the readings table | Partition `node_id`, sort `sk` with `state#<variable>` | Current values |
| Ranges table | Partition `zone_type`, sort `variable#valid_from` | Every version, five years |
| Alerts table | Partition `farm_id`, sort `raised_at`, index on `push_message_id` | Five years |
| Telemetry archive | Parquet under `<stream>/year=/month=/day=/` of arrival | Five years through a lifecycle rule |

Tables use the data key and point-in-time recovery. The archive uses the objects key with S3 Bucket Keys.

Each item of the ranges table holds every kind of range of one variable from one moment, in the maps `alert`, `recommended` and `reference`, so the evaluation reads one item. The module writes the `alert_ranges` input as version 1 and never updates those items again, so a version published through the platform API survives every `terraform apply`.

## Alert delivery

The ingestion function publishes each alert straight to the phone endpoints of the farm, under the Firebase Cloud Messaging platform application. SNS logs the status of every push to two log groups named after the application, and a subscription filter passes each entry to the delivery status function, which writes the handoff time. Five minutes after the publish, the delivery check function reads the alert, and it sends one SMS for an urgent alert with no receipt.

The push credential is a secret, and Terraform stores every argument it sends in the state. The module therefore creates the application with a placeholder credential and ignores later changes to it. After the first deployment, the platform operator loads the real Firebase service account key with the AWS CLI.

```bash
aws sns set-platform-application-attributes \
  --platform-application-arn "$(terraform output -raw push_application_arn)" \
  --attributes PlatformCredential="$(jq @json < service-account.json)"
```

Until then, the application holds no working credential and a publish to a phone fails at the push service, which the failure log records.

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

  data_key_arn    = module.security.data_key_arn
  objects_key_arn = module.security.objects_key_arn
  role_arns = {
    ingestion_function       = module.security.ingestion_function_role_arn
    iot_rule                 = module.security.iot_rule_role_arn
    firehose_delivery        = module.security.firehose_role_arn
    delivery_status_function = module.security.delivery_status_function_role_arn
    delivery_check_function  = module.security.delivery_check_function_role_arn
    push_status_logs         = module.security.push_status_logs_role_arn
    sms_status_logs          = module.security.sms_status_logs_role_arn
  }

  names              = local.ingestion_names
  thing_groups       = local.thing_groups
  function_packages  = local.function_packages
  alert_ranges       = local.alert_ranges
  force_destroy_data = var.force_destroy_data
}
```

`sample/locals.tf` shows how a root builds every name, and `sample/data.tf` how it finds keys and roles when the security module lives in another state.

## Inputs

| Name | Type | Required | Description |
|---|---|---|---|
| `client`, `project`, `environment` | `string` | Yes | Codes for tags and the topic prefix. `environment` is `dev`, `test` or `prod` |
| `additional_tags` | `map(string)` | No | Tags added on top of the provider default tags |
| `data_key_arn` | `string` | Yes | Key of the tables, queues and log groups |
| `objects_key_arn` | `string` | Yes | Key of the archive |
| `role_arns` | `object` | Yes | Role of each purpose, `ingestion_function`, `iot_rule`, `firehose_delivery`, `delivery_status_function`, `delivery_check_function`, `push_status_logs` and `sms_status_logs` |
| `names` | `object` | Yes | Final name of every resource, built by the root. `farms_table` names the farm register of the platform API, which the functions read |
| `thing_groups` | `map(string)` | Yes | Thing group name of each department, keyed by department code |
| `function_packages` | `map(object)` | Yes | `path` of a `.zip` for `ingestion`, `delivery_status` and `delivery_check`, with optional `handler` (default `main.handler`) and `runtime` (default `python3.13`) |
| `alert_ranges` | `list(object)` | Yes | Initial ranges, each with `zone_type`, `variable`, `unit`, `valid_from`, `reason` and at least one of `alert`, `recommended` and `reference` |
| `force_destroy_data` | `bool` | No | Lets a destroy remove tables and the archive while they hold data. Defaults to `false` |

Validation rejects a rule name or a Glue name with hyphens, an invalid bucket name, a missing function package, a range with no limits, a minimum above its maximum, a repeated zone type and variable, and a `valid_from` outside UTC.

## Outputs

| Name | Description |
|---|---|
| `iot_policy_name` | Node policy that the farm module attaches to each certificate |
| `thing_group_names` | Thing group of each department |
| `iot_topic_rule_name` | Name of the rule |
| `topic_filter` | Topic filter of this environment |
| `queue_arn` | ARN of the ingestion queue |
| `dead_letter_queue_arn` | ARN of the dead letter queue of the ingestion queue |
| `delivery_queue_arn` | ARN of the delivery check queue |
| `readings_table_arn` | ARN of the readings table |
| `ranges_table_arn` | ARN of the ranges table |
| `alerts_table_arn` | ARN of the alerts table |
| `archive_bucket_arn` | ARN of the archive bucket |
| `push_application_arn` | ARN of the Firebase Cloud Messaging platform application |
| `function_arns` | ARN of each function |

## Names

The convention `{client}-{project}-{environment}-{type}-{key}` uses hyphens. IoT rule names and Glue names accept no hyphens, so the root replaces them with underscores in those names, which the exceptions file records. SNS names the push status log groups after the platform application, `sns/<region>/<account>/app/GCM/<name>` and the same name ending in `/Failure`, so the module builds those two names itself.

## Destroying an environment

Environments of the demonstration come up through the deployment pipeline when the team uses them, and the same pipeline destroys them when work stops. The standard `prevent_destroy` setting cannot depend on a variable, and it would block that destroy. Tables use DynamoDB deletion protection and the archive uses `force_destroy`, both driven by `force_destroy_data`, so data that must survive stays protected and a demonstration environment comes down cleanly.

## Cost

Every service bills per message, per request or per stored byte, so the module costs almost nothing while idle. Rates come from the AWS Price List API for us-east-1. A harvest month carries 108,000 messages of about 0.5 KB, and the platform telemetry cost analysis covers IoT Core, SQS, Lambda and DynamoDB at about USD 1.00 a month.

| Item | Rate | Harvest month | USD |
|---|---|---|---|
| Firehose ingestion | USD 0.029 per GB, each record rounded up to 5 KB | 0.54 GB billed | 0.02 |
| Parquet conversion | USD 0.018 per GB | 0.05 GB | Below 0.01 |
| Dynamic partitioning, data | USD 0.02 per GB processed | 0.05 GB | Below 0.01 |
| Dynamic partitioning, objects | USD 0.005 per 1,000 objects | About 6,000 objects, two streams with a file every 15 minutes | 0.03 |
| Dynamic partitioning, parsing | USD 0.07 per hour of processing | A few minutes | Below 0.01 |
| Status and function logs | USD 0.50 per GB ingested | Below 0.1 GB | Below 0.05 |

The archive adds about USD 0.05 a month to the telemetry figure. SMS for urgent alerts is the only item that grows with alerts, at USD 0.05087 per message to Colombia, and the alert delivery cost analysis holds its bound.

## Develop and test

The exact Terraform version lives in `.terraform-version`. Tests run against a mocked provider, so they need no AWS account and spend no credits. `tests/fixtures/function.zip` is a placeholder package that the tests deploy.

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
| [`terraform-aws-security`](https://github.com/aromapacifico-devops/terraform-aws-security) | Keys and roles this module receives |
| [`terraform-aws-farm`](https://github.com/aromapacifico-devops/terraform-aws-farm) | Identity of one farm, which joins the thing groups and takes the node policy |
| [`terraform-aws-module-template`](https://github.com/aromapacifico-devops/terraform-aws-module-template) | Template this repository was generated from |
| [`aromapacifico-devops-docs`](https://github.com/aromapacifico-devops/aromapacifico-devops-docs) | Architecture and design documents |
