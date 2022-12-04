terraform {
  required_version = "~> 1.3.4"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.44.1"
    }
  }
}

variable "project" {
  description = <<-EOT
  All resources deployed by this module are contained in a single project that must already exist. 
  The project must be linked to a billing account. 
  The operator must have enough permissions to:
    - enable services;
    - create service accounts;
    - set IAM policy at project level.
  EOT
  type        = string
  nullable    = false
}
variable "region" {
  description = "The default GCP region to deploy the resources into. Can be overridden at the resource level."
  type        = string
  default     = "europe-west2"
  nullable    = false
}
variable "zone" {
  description = "The default GCP zone to deploy the resources into. Can be overridden at the resource level."
  type        = string
  default     = "europe-west2-a"
  nullable    = false
}

# The "seed" provider instance uses operator's credentials to: 
#   - enable the necessary services on the project;
#   - create a service account;
#   - set IAM policy on the service account following the principle of least privilege.
provider "google" {
  alias   = "seed"
  project = var.project
  region  = var.region
  zone    = var.zone
  scopes = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
  ]
}

# Pre-requisite: "Service Usage API" (serviceusage.googleapis.com) must be enabled 
# for Terraform to be able to manage services in a Google Cloud project.

# Pre-requisite: in a long-running project, it is not wise to disable core services,
# like logging and monitoring. So, we enable those services, if they had not been
# enabled yet, but we don't turn them off on destroy.

locals {
  long_running_services = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ]
  enabled_services = [
    "compute.googleapis.com",
    "container.googleapis.com",
  ]
}

resource "google_project_service" "long_running" {
  provider = google.seed
  for_each = toset(local.long_running_services)
  service  = each.key

  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "enabled_by_terraform" {
  provider = google.seed
  for_each = toset(local.enabled_services)
  service  = each.key

  # (Optional) If true, services that are enabled and which depend on this service should also be disabled
  # when this service is destroyed. If false or unset, an error will be generated if any enabled services
  # depend on this service when destroying it.
  disable_dependent_services = false

  # (Optional) If true, disable the service when the Terraform resource is destroyed. Defaults to true.
  # May be useful in the event that a project is long-lived but the infrastructure running in that project changes frequently.
  disable_on_destroy = true
}

# Create a service account to manage the environment...

resource "google_service_account" "admin_robot" {
  provider    = google.seed
  account_id  = "admin-robot"
  description = "Manages task-oriented resources via Terraform"
  depends_on = [
    google_project_service.long_running,
    google_project_service.enabled_by_terraform,
  ]
}

# Grant the service account necessary admin roles...

# The admin robot will manage the cluster infrastructure, 
# but not their Kubernetes API objects. Thus, "Kubernetes Engine Cluster Admin"
# role is preferred to the full "Kubernetes Engine Admin" role.
# Predefined GKE Roles: https://cloud.google.com/kubernetes-engine/docs/how-to/iam#predefined
#
# The admin robot will also create and manage the service accounts
# that the nodes will use. And this is why it is granted the "Service Account Admin" role.
# Service Accounts roles: https://cloud.google.com/iam/docs/understanding-roles#service-accounts-roles

locals {
  admit_robot_roles = [
    "roles/container.clusterAdmin",
    "roles/iam.serviceAccountAdmin",
  ]
}

resource "google_project_iam_member" "admin_robot" {
  provider = google.seed
  project  = var.project
  for_each = toset(local.admit_robot_roles)
  role     = each.key
  member   = "serviceAccount:${google_service_account.admin_robot.email}"
}
