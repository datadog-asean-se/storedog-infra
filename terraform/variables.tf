variable "project_id" {
  description = "GCP project. Defaults to the shared datadog-ese-sandbox SE project."
  type        = string
  default     = "datadog-ese-sandbox"
}

variable "region" {
  description = "GCP region."
  type        = string
  default     = "asia-southeast1"
}

variable "zone" {
  description = "Zone for the (zonal, cheaper) ephemeral cluster."
  type        = string
  default     = "asia-southeast1-a"
}

variable "cluster_name" {
  description = "Name of the ephemeral GKE cluster."
  type        = string
  default     = "storedog-adlc-demo"
}

variable "network" {
  description = "Existing VPC network to attach to (do NOT create open firewall rules)."
  type        = string
  default     = "default"
}

variable "subnetwork" {
  description = "Existing subnetwork in var.region."
  type        = string
  default     = "default"
}

variable "node_machine_type" {
  description = "Machine type for the single demo node pool."
  type        = string
  default     = "e2-standard-4"
}

variable "node_count" {
  description = "Number of nodes (storedog + argocd + rollouts + datadog agent fit in ~2)."
  type        = number
  default     = 2
}

variable "labels" {
  description = "Labels applied to the cluster for cost tracking / ephemeral cleanup. Override `owner` with your own username when you deploy."
  type        = map(string)
  default = {
    purpose   = "adlc-datadog-demo"
    ephemeral = "true"
    owner     = "unset"
  }
}
