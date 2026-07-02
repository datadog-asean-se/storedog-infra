output "cluster_name" {
  value = google_container_cluster.storedog.name
}

output "location" {
  value = google_container_cluster.storedog.location
}

# DNS-based control-plane endpoint. Use it with:
#   gcloud container clusters get-credentials <name> --location <zone> --dns-endpoint
output "dns_endpoint" {
  description = "GKE DNS-based control-plane endpoint (no public IP allowlist needed)."
  value       = try(google_container_cluster.storedog.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint, null)
}

output "get_credentials_command" {
  description = "Run this to configure kubectl via the DNS endpoint."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.storedog.name} --location ${google_container_cluster.storedog.location} --project ${var.project_id} --dns-endpoint"
}
