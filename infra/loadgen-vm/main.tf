terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh-loadgen"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["loadgen"]
}

# Allow Locust Web UI on 8089
resource "google_compute_firewall" "allow_locust_ui" {
  count   = var.enable_locust_ui ? 1 : 0
  name    = "allow-locust-ui"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["8089"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["loadgen"]
}

resource "google_compute_instance" "loadgen" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["loadgen"]

  # Cost saving for load tests:
  scheduling {
    provisioning_model          = var.use_spot ? "SPOT" : "STANDARD"
    automatic_restart           = var.use_spot ? false : true
    preemptible                 = var.use_spot ? true : false
    instance_termination_action = var.use_spot ? "STOP" : null
  }

  boot_disk {
    initialize_params {
      # Container-Optimized OS: fast, secure, has Docker
      image = "projects/cos-cloud/global/images/family/cos-stable"
      size  = 20
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    startup-script = templatefile("${path.module}/startup.sh.tftpl", {
      frontend_addr    = var.frontend_addr
      users            = var.users
      rate             = var.rate
      duration         = var.duration
      export_csv       = var.export_csv
      enable_locust_ui = var.enable_locust_ui
    })
  }
}

output "loadgen_external_ip" {
  value = google_compute_instance.loadgen.network_interface[0].access_config[0].nat_ip
}
