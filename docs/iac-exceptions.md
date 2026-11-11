# Infrastructure code exceptions

A finding of the automated checks is accepted only through a row in this table, added in its own reviewed pull request. Each row states why the finding is acceptable and the condition that ends the exception.

| Rule | Path | Resource | Reason | Expires when |
|---|---|---|---|---|
| Lifecycle protection | `main.tf` | DynamoDB tables and S3 archive | `prevent_destroy` cannot depend on a variable and would block the destroy of a demonstration environment when work stops. Deletion protection and `force_destroy`, driven by `force_destroy_data`, keep the data of the pilot protected | The platform leaves the demonstration account |
| Resource naming | `main.tf` | IoT topic rule, Glue database and table | IoT rule names accept only letters, numbers and underscores, and Glue names are lowercase with underscores for Athena, so the root replaces the hyphens of the convention | AWS accepts hyphens in those names |
| CKV2_AWS_62, S3 event notifications | `main.tf` | Archive bucket | Firehose writes the archive and no process reacts to each object, since queries read it through Athena | A process needs to react to new archive objects |
| CKV_AWS_18, S3 access logging | `main.tf` | Archive bucket | Only Firehose writes the archive and only Athena queries read it. The audit design records data events for flight objects, restricted images and range writes, and server access logs arrive on a best-effort basis | The audit design adds the telemetry archive |
| CKV_AWS_144, cross-Region replication | `main.tf` | Archive bucket | The pilot runs in one Region, and a replica would double archive storage with no recovery target that needs it | A recovery objective requires a second Region |
| CKV_AWS_241, Firehose under a customer key | `main.tf` | Archive stream | Records wait at most 900 seconds in the stream under the AWS owned key, and every object lands in S3 under the objects key | A requirement asks for the customer key on buffered records too |
| CKV_AWS_338, log retention of one year | `main.tf` | Function and status log groups | Operational logs keep 30 days, since lasting evidence lives in the tables and the audit trail, and the push and SMS logs hold tokens and phone numbers | Operations require longer log retention |
| CKV_AWS_115, reserved concurrency | `main.tf` | Functions | The account allows 10 concurrent executions, which leaves no room to reserve. The event source mappings cap the pollers | The account concurrency quota rises |
| CKV_AWS_116, Lambda dead letter queue | `main.tf` | Functions | The queue functions use the dead letter queue of their queue through its redrive policy, and the status function runs from a log subscription that retries by itself. A Lambda dead letter queue applies only to asynchronous invocations | A function gains an asynchronous trigger |
| CKV_AWS_117, function in a VPC | `main.tf` | Functions | The functions call regional AWS APIs only, and a VPC would need interface endpoints with an hourly charge | Private access to those services becomes a requirement |
| CKV_AWS_173, environment variables under a customer key | `main.tf` | Functions | The variables hold names and settings, never a secret, and Lambda encrypts them at rest with its service key | A secret is passed as an environment variable |
| CKV_AWS_272, code signing | `main.tf` | Functions | Packages are built from the reviewed repository by the pipeline that deploys them, and no signing profile exists yet | A signing profile exists for the platform functions |
| CKV_AWS_50, X-Ray tracing | `main.tf` | Functions | Traces are not part of the current observability design, and the function roles hold no trace permission | The observability design adds traces for the functions |
