#!/bin/bash

# ---------- Colors ----------
CYAN=`tput setaf 6`
GREEN=`tput setaf 2`
YELLOW=`tput setaf 3`
RED=`tput setaf 1`
BOLD=`tput bold`
RESET=`tput sgr0`

echo "${CYAN}${BOLD}==================================================${RESET}"
echo "${CYAN}${BOLD}        STARTING TERRAFORM CHALLENGE LAB          ${RESET}"
echo "${CYAN}${BOLD}==================================================${RESET}"

# ---------- Inputs (lab values as defaults: just press Enter) ----------
read -p "${YELLOW}${BOLD}Enter bucket name [tf-bucket-152562]: ${RESET}" BUCKET
read -p "${YELLOW}${BOLD}Enter VPC name [tf-vpc-752813]: ${RESET}" VPC
read -p "${YELLOW}${BOLD}Enter zone [us-west1-b]: ${RESET}" ZONE

BUCKET=${BUCKET:-tf-bucket-152562}
VPC=${VPC:-tf-vpc-752813}
ZONE=${ZONE:-us-west1-b}
INSTANCE="tf-instance-811031"      # fixed by the lab (do not change)

export BUCKET VPC ZONE INSTANCE
echo "${GREEN}${BOLD}Variables set: $BUCKET | $VPC | $ZONE | $INSTANCE${RESET}"

# ---------- Install Terraform ----------
cat <<'EOF' > ~/.customize_environment
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF
bash ~/.customize_environment
terraform --version

# ---------- Environment ----------
gcloud auth list
export PROJECT_ID=$(gcloud config get-value project)
export REGION=${ZONE%-*}
gcloud config set compute/zone $ZONE
gcloud config set compute/region $REGION

# Get instance IDs BY NAME (safe, order independent)
export INSTANCE_ID_1=$(gcloud compute instances list --filter="name=tf-instance-1" --format="value(id)")
export INSTANCE_ID_2=$(gcloud compute instances list --filter="name=tf-instance-2" --format="value(id)")
echo "tf-instance-1 ID: $INSTANCE_ID_1"
echo "tf-instance-2 ID: $INSTANCE_ID_2"

# =====================================================
# TASK 1: Configuration files
# =====================================================
cd ~
mkdir -p modules/instances modules/storage
touch main.tf variables.tf
touch modules/instances/instances.tf modules/instances/outputs.tf modules/instances/variables.tf
touch modules/storage/storage.tf modules/storage/outputs.tf modules/storage/variables.tf

# variables.tf (root + both modules)
for f in variables.tf modules/instances/variables.tf modules/storage/variables.tf; do
cat > $f <<EOF_CP
variable "region" {
  default = "$REGION"
}

variable "zone" {
  default = "$ZONE"
}

variable "project_id" {
  default = "$PROJECT_ID"
}
EOF_CP
done

cat > main.tf <<EOF_CP
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "instances" {
  source = "./modules/instances"
}
EOF_CP

terraform init

# =====================================================
# TASK 2: Import infrastructure
# =====================================================
cat > modules/instances/instances.tf <<EOF_CP
resource "google_compute_instance" "tf-instance-1" {
  name         = "tf-instance-1"
  machine_type = "n1-standard-1"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
  }

  metadata_startup_script = <<-EOT
        #!/bin/bash
    EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "tf-instance-2" {
  name         = "tf-instance-2"
  machine_type = "n1-standard-1"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
  }

  metadata_startup_script = <<-EOT
        #!/bin/bash
    EOT
  allow_stopping_for_update = true
}
EOF_CP

terraform import module.instances.google_compute_instance.tf-instance-1 $INSTANCE_ID_1
terraform import module.instances.google_compute_instance.tf-instance-2 $INSTANCE_ID_2

terraform plan
terraform apply --auto-approve

# =====================================================
# TASK 3: Remote backend
# =====================================================
cat > modules/storage/storage.tf <<EOF_CP
resource "google_storage_bucket" "storage-bucket" {
  name                        = "$BUCKET"
  location                    = "US"
  force_destroy               = true
  uniform_bucket_level_access = true
}
EOF_CP

cat > main.tf <<EOF_CP
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "instances" {
  source = "./modules/instances"
}

module "storage" {
  source = "./modules/storage"
}
EOF_CP

terraform init
terraform apply --auto-approve

cat > main.tf <<EOF_CP
terraform {
  backend "gcs" {
    bucket = "$BUCKET"
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "instances" {
  source = "./modules/instances"
}

module "storage" {
  source = "./modules/storage"
}
EOF_CP

terraform init -migrate-state -force-copy

# =====================================================
# TASK 4: Modify and update (3 instances, all e2-standard-2)
# =====================================================
cat > modules/instances/instances.tf <<EOF_CP
resource "google_compute_instance" "tf-instance-1" {
  name         = "tf-instance-1"
  machine_type = "e2-standard-2"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
  }

  metadata_startup_script = <<-EOT
        #!/bin/bash
    EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "tf-instance-2" {
  name         = "tf-instance-2"
  machine_type = "e2-standard-2"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
  }

  metadata_startup_script = <<-EOT
        #!/bin/bash
    EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "$INSTANCE" {
  name         = "$INSTANCE"
  machine_type = "e2-standard-2"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
  }

  metadata_startup_script = <<-EOT
        #!/bin/bash
    EOT
  allow_stopping_for_update = true
}
EOF_CP

terraform init
terraform apply --auto-approve

# =====================================================
# TASK 5: Destroy the third instance (remove resource + apply)
# =====================================================
cat > modules/instances/instances.tf <<EOF_CP
resource "google_compute_instance" "tf-instance-1" {
  name         = "tf-instance-1"
  machine_type = "e2-standard-2"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
  }

  metadata_startup_script = <<-EOT
        #!/bin/bash
    EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "tf-instance-2" {
  name         = "tf-instance-2"
  machine_type = "e2-standard-2"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
  }

  metadata_startup_script = <<-EOT
        #!/bin/bash
    EOT
  allow_stopping_for_update = true
}
EOF_CP

terraform init
terraform apply --auto-approve

# =====================================================
# TASK 6: VPC module from Registry (version 10.0.0)
# =====================================================
cat > main.tf <<EOF_CP
terraform {
  backend "gcs" {
    bucket = "$BUCKET"
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "instances" {
  source = "./modules/instances"
}

module "storage" {
  source = "./modules/storage"
}

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "10.0.0"

  project_id   = "$PROJECT_ID"
  network_name = "$VPC"
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name   = "subnet-01"
      subnet_ip     = "10.10.10.0/24"
      subnet_region = "$REGION"
    },
    {
      subnet_name   = "subnet-02"
      subnet_ip     = "10.10.20.0/24"
      subnet_region = "$REGION"
    },
  ]
}
EOF_CP

terraform init
terraform apply --auto-approve

# Connect instances to the new VPC / subnets
cat > modules/instances/instances.tf <<EOF_CP
resource "google_compute_instance" "tf-instance-1" {
  name         = "tf-instance-1"
  machine_type = "e2-standard-2"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network    = "$VPC"
    subnetwork = "subnet-01"
  }

  metadata_startup_script = <<-EOT
        #!/bin/bash
    EOT
  allow_stopping_for_update = true
}

resource "google_compute_instance" "tf-instance-2" {
  name         = "tf-instance-2"
  machine_type = "e2-standard-2"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network    = "$VPC"
    subnetwork = "subnet-02"
  }

  metadata_startup_script = <<-EOT
        #!/bin/bash
    EOT
  allow_stopping_for_update = true
}
EOF_CP

terraform init
terraform apply --auto-approve

# =====================================================
# TASK 7: Firewall
# =====================================================
cat >> main.tf <<EOF_CP

resource "google_compute_firewall" "tf-firewall" {
  name    = "tf-firewall"
  network = "projects/$PROJECT_ID/global/networks/$VPC"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]

  depends_on = [module.vpc]
}
EOF_CP

terraform init
terraform apply --auto-approve

echo
echo "${GREEN}${BOLD}==================== ALL TASKS DONE ====================${RESET}"
echo "Now click 'Check my progress' on every task."
