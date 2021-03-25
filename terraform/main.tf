provider "google" {
  credentials = file(var.credentials) # Access to the cluster. Needs to be created first
  project     = var.gce_project
}

provider "google-beta" {
  credentials = file(var.credentials) # Access to the cluster. Needs to be created first
  project     = var.gce_project
}


data "google_container_engine_versions" "k8s-versions" {
  provider       = google-beta
  location       = var.gce_location
  version_prefix = var.k8s_version_prefix
}

resource "google_container_cluster" "cluster" {
  name               = var.cluster_name
  location           = var.gce_location
  min_master_version = data.google_container_engine_versions.k8s-versions.latest_master_version

  # Initial node gets destroyed immediately and is replaced by node pool
  initial_node_count       = 1
  remove_default_node_pool = true

  # Add entry to local kubeconfig automatically
  provisioner "local-exec" {
    command = "if ! command -v gcloud >/dev/null 2>&1; then echo WARNING: gcloud not installed. Cannot add cluster to local kubeconfig; else gcloud container clusters get-credentials ${var.cluster_name} --zone ${var.gce_location} --project ${var.gce_project}; fi"
  }
}


# k8s node pool
resource "google_container_node_pool" "node_pool" {
  name       = "default-node-pool"
  location   = var.gce_location
  version    = data.google_container_engine_versions.k8s-versions.latest_node_version
  cluster    = google_container_cluster.cluster.name
  node_count = var.node_pool_node_count

  management {
    # Avoid upgrade during demos
    auto_upgrade = false
  }

  node_config {
    # We use ubuntu, because Container-optimized OS has /tmp mounted with noexec.
    # This conflicts with the workarounds we need to take to make Jenkins Build runnable with docker inside the cluster
    # Basically: Providing the docker binary within the agent pods, via a hostPath mount :-|
    # On the default Container-optimized OS /tmp mounted with noexec.
    # So we use ubuntu
    # A more robust option would be to provide a jenkins-agent-docker image but for now this seems to much effort
    image_type = "ubuntu"
    preemptible  = false
    machine_type = "n1-standard-2" # pricing: https://cloud.google.com/compute/vm-instance-pricing#n1_predefined
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      # Grants Read Access to GCR to clusters
      "https://www.googleapis.com/auth/devstorage.read_only",
    ]
  }
}
