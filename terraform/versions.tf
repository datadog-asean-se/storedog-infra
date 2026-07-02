terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0"
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
