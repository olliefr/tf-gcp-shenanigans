terraform {
  required_version = "~> 1.3.4"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.44.1"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9.1"
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

# Pre-requisite: "Cloud Resource Manager API" (cloudresourcemanager.googleapis.com) must be enabled
# for Terraform to be able to manage IAM policies at project level.

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
#
# The admin robot will be managing the permissions for the service accounts that it creates for GKE nodes. 
# This is why it needs "Project IAM Admin" role: https://cloud.google.com/resource-manager/docs/access-control-proj#resourcemanager.projectIamAdmin
locals {
  admin_robot_roles = [
    "roles/container.clusterAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/resourcemanager.projectIamAdmin",
  ]
}

resource "google_project_iam_member" "admin_robot" {
  provider = google.seed
  project  = var.project
  for_each = toset(local.admin_robot_roles)
  role     = each.key
  member   = "serviceAccount:${google_service_account.admin_robot.email}"
}

# The rest of deployment is done by impersonating the "admin robot" service account.
# Configure the impersonation...

# Establish operator (human user) identity that was used up to this point.
data "google_client_openid_userinfo" "operator" {
  provider = google.seed
}

# Reveal operator identity (for convenience only).
output "my-email" {
  value = data.google_client_openid_userinfo.operator.email
}

# Grant the operator permission to impersonate the admin-robot service account...

# Allow the operator to impersonate a specific service account (admin-robot).
resource "google_service_account_iam_member" "operator_as_admin_robot" {
  provider           = google.seed
  service_account_id = google_service_account.admin_robot.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${data.google_client_openid_userinfo.operator.email}"
}

# To configure service account impersonation in Terraform, we'll create a new Google provider instance,
# with the permissions limited to those of admin-robot service account only. For this we'll need 
# an access token.

# Pre-requisite: the operator must have the "Service Account Token Creator" role on the service account.
data "google_service_account_access_token" "operator_as_admin_robot" {
  provider               = google.seed
  target_service_account = google_service_account.admin_robot.email
  scopes = [
    "userinfo-email",
    "cloud-platform",
  ]
  lifetime = "1200s"

  # Without the following explicit dependency declaration, the data source is likely to be read before the IAM policy 
  # allowing the operator to impersonate the service account is set (google_service_account_iam_member.operator_as_admin_robot)
  # This is illustrated by shenanigans-5.dot, where IAM policy setting and token acquisition are independent paths.
  # The idea here is to declare an explicit dependency on the IAM binding resource, as illustrated by shenanigans-6.dot
  # Unfortunately, this does not work and eventual consistency of IAM bites hard, with the request to the data source
  # failing with error 403 (permission denied) on the first few consequent runs.
  depends_on = [
    google_service_account_iam_member.operator_as_admin_robot,
    time_sleep.delay_between_iam_update_and_token_read,
  ]
}

# To work around the 403 permission denied issue related to eventual consistency of IAM,
# we wait some time after the IAM policy had been set on the service account. This is not ideal
# at all as IAM changes may take hours to propagate in the worst case. But it's better than nothing.
# The value of 120s was chosen empirically. It appears that IAM changes at service account level take
# longer to propagate on average than IAM changes at project/folder/organisation level.
# FIXME: i hope that Terraform will have something more sophisticated in the future to wait on IAM eventual consistency

resource "time_sleep" "delay_between_iam_update_and_token_read" {
  create_duration = "120s"
  depends_on      = [google_service_account_iam_member.operator_as_admin_robot]
}

# At this point all configuration that required elevated privileges has been done.
# From now on, the service account admin-robot will deploy the rest of the resources
# using only the permissions assigned to it (least privilege principle applied).

# To facilitate that, create the "default" Google provider instance that impersonates
# admin-robot service account. All remaining resources will be deployed using this provider...

provider "google" {
  project      = var.project
  region       = var.region
  zone         = var.zone
  access_token = data.google_service_account_access_token.operator_as_admin_robot.access_token
}

# Example: a locked-down service account for GKE nodes...

# The service account for main pool nodes (GKE)
resource "google_service_account" "gke_main_pool_node" {
  account_id  = "gke-main-pool-node"
  description = "Locked down account for GKE main pool nodes"
}

# Creation of service accounts is eventually consistent,
# and that can lead to errors when you try to set IAM policies
# on a service account immediately after having created one.
# The value of 60s is an empirical observation, there is no guarantee
# that the service account is going to be created and ready in that time.
# FIXME: i hope that Terraform will have something more sophisticated in the future to wait on service accounts' eventual consistency
resource "time_sleep" "delay_between_create_account_and_set_iam_policy" {
  create_duration = "60s"
  depends_on      = [google_service_account.gke_main_pool_node]
}

locals {
  # Role assignment for the least privileged GKE node service account
  # Use least privilege Google service accounts: https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster#use_least_privilege_sa
  # "Kubernetes Engine Node Service Account" role reference: https://cloud.google.com/iam/docs/understanding-roles#container.nodeServiceAccount
  gke_main_pool_node_roles = [
    "roles/container.nodeServiceAccount",
  ]
}

# Grant necessary permissions to main pool nodes at project level (GKE)
resource "google_project_iam_member" "gke_main_pool_node" {
  project  = var.project
  for_each = toset(local.gke_main_pool_node_roles)
  role     = each.key
  member   = "serviceAccount:${google_service_account.gke_main_pool_node.email}"

  # FIXME: as referenced above, this is a hack to deal with eventual consistency. not ideal
  depends_on = [time_sleep.delay_between_create_account_and_set_iam_policy]
}

# The admin-robot service account must be allowed to use main pool nodes service account to deploy the nodes with that identity. 
resource "google_service_account_iam_member" "admin_robot_as_gke_main_pool_node" {
  service_account_id = google_service_account.gke_main_pool_node.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.admin_robot.email}"

  # FIXME: i hope that Terraform will have something more sophisticated in the future to wait on service accounts' eventual consistency
  depends_on = [time_sleep.delay_between_create_account_and_set_iam_policy]
}
