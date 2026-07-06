terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0"
    }
    datadog = {
      source  = "DataDog/datadog"
      version = ">= 3.40.0"
    }
  }

  # Optional: use a GCS backend so the ephemeral cluster state is shared.
  # backend "gcs" {
  #   bucket = "datadog-ese-sandbox-tfstate"
  #   prefix = "storedog-gke-reference"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Datadog Monitor for the `monitor` Deployment Gates JIT rule (see monitor.tf).
# Reads DD_API_KEY / DD_APP_KEY from the environment automatically - no explicit
# api_key/app_key/api_url arguments needed (matches this repo's existing
# `dotenvx run --` convention for sourcing Datadog credentials at runtime).
# This resource has no dependency on the GKE cluster resources in main.tf, so it
# can be created/updated independently, e.g.:
#   dotenvx run -- terraform apply -target=datadog_monitor.discounts_error_rate
provider "datadog" {}
