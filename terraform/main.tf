# Ephemeral GKE cluster for the ADLC + Datadog storedog demo.
#
# Design constraints (datadog-ese-sandbox GCP project org policy):
#   - NEVER create a firewall rule with source-ranges 0.0.0.0/0 (org policy blocks it).
#     This module creates NO firewall rules at all.
#   - Access the control plane over the GKE DNS-based endpoint (no public IP allowlist,
#     no authorized-networks CIDR management). Authn via gke-gcloud-auth-plugin.
#   - Reach the storefront via `kubectl port-forward` (see scripts/port-forward.sh) -
#     no public Ingress / LoadBalancer with an open CIDR.
#
# The cluster is Standard (not Autopilot) because the Datadog node agent and the
# storedog APM unix-socket hostPath mount need node-level access.

data "google_container_engine_versions" "channel" {
  location       = var.zone
  version_prefix = "1.30."
}

resource "google_container_cluster" "storedog" {
  name     = var.cluster_name
  location = var.zone

  # Attach to an existing VPC/subnet; we never create open firewall rules.
  network    = var.network
  subnetwork = var.subnetwork

  # Remove the default node pool; we manage our own below.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Ephemeral: allow `terraform destroy` to tear it down cleanly.
  deletion_protection = false

  release_channel {
    channel = "REGULAR"
  }
  min_master_version = data.google_container_engine_versions.channel.latest_master_version

  # DNS-based control-plane endpoint: kubectl reaches the API server via a
  # Google-managed DNS name, authenticated with gke-gcloud-auth-plugin/IAM -
  # no authorized-networks CIDRs to manage, no public IP allowlist.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  # Private nodes (no public node IPs). Control plane reached via DNS endpoint.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # DNS endpoint handles access; no IP-based public endpoint needed
  }

  # VPC-native (alias IPs). Uses the subnetwork's secondary ranges if present.
  ip_allocation_policy {}

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Keep Datadog's own signals clean; disable GKE's basic logging/monitoring noise
  # (Datadog agent is the source of truth for this demo).
  logging_service    = "none"
  monitoring_service = "none"

  resource_labels = var.labels

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

resource "google_container_node_pool" "primary" {
  name       = "demo-pool"
  location   = var.zone
  cluster    = google_container_cluster.storedog.name
  node_count = var.node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"

    # No public IP on nodes.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = var.labels
    tags   = ["storedog-adlc-demo"] # network tag only; NO firewall rule is created here
  }
}
