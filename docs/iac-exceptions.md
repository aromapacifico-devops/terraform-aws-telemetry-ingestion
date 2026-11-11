# Infrastructure code exceptions

A finding of the automated checks is accepted only through a row in this table, added in its own reviewed pull request. Each row states why the finding is acceptable and the condition that ends the exception.

| Rule | Path | Resource | Reason | Expires when |
|---|---|---|---|---|
| Lifecycle protection | `main.tf` | DynamoDB tables and S3 archive | `prevent_destroy` cannot depend on a variable and would block the destroy of a demonstration environment when work stops. Deletion protection and `force_destroy`, driven by `force_destroy_data`, keep the data of the pilot protected | The platform leaves the demonstration account |
| Resource naming | `main.tf` | IoT topic rule, Glue database and table | IoT rule names accept only letters, numbers and underscores, and Glue names are lowercase with underscores for Athena, so the root replaces the hyphens of the convention | AWS accepts hyphens in those names |
