# Sample values. No identifiers of real resources and no secrets.
client      = "fnc"
project     = "aroma"
environment = "dev"
region      = "us-east-1"

common_tags = {
  Client      = "fnc"
  Project     = "aroma"
  Environment = "dev"
  Owner       = "platform"
  CostCenter  = "pruebas"
  ManagedBy   = "Terraform"
}

departments = ["cauca"]

# Placeholder package that only answers with no failures.
function_package_path = "../tests/fixtures/function.zip"

alert_ranges = [
  {
    zone_type  = "drying"
    variable   = "grain_temp_c"
    unit       = "°C"
    valid_from = "2026-11-10T00:00:00Z"
    reason     = "Initial range of the pilot"
    alert      = { max = 40, max_included = false }
  },
]
