#!/bin/bash
# =====================================================
#  GSP345 - Terraform on Google Cloud: Challenge Lab
#  FULL SCRIPT: Task 1 to Task 7
# =====================================================

# ---------- Inputs (press Enter to use the default) ----------
read -p "Enter bucket name   [tf-bucket-152562]: " BUCKET
read -p "Enter VPC name      [tf-vpc-752813]: " VPC
read -p "Enter instance name [tf-instance-811031]: " INSTANCE
read -p "Enter zone          [us-west1-b]: " ZONE

BUCKET=${BUCKET:-tf-bucket-152562}
VPC=${VPC:-tf-vpc-752813}
INSTANCE=${INSTANCE:-tf-instance-811031}
ZONE=${ZONE:-us-west1-b}

REGION=${ZONE%-*}
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

export BUCKET VPC INSTANCE ZONE REGION PROJECT_ID

gcloud config set compute/zone $ZONE
gcloud config set compute/region $REGION

echo "-------------------------------------------"
echo "Project  : $PROJECT_ID"
echo "Bucket   : $BUCKET"
echo "VPC      : $VPC"
echo "Instance : $INSTANCE"
echo "Zone     : $ZONE"
echo "Region   : $REGION"
echo "-------------------------------------------"

# ---------- Install Terraform ----------
cat <<'EOF' > ~/.customize_environment
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF
bash ~/.customize_environment
terraform --version

# ---------- Get instance IDs by name ----------
ID1=$(gcloud compute instances list --filter="name=tf-instance-1" --format="value(id)")
ID2=$(gcloud compute instances list --filter="name=tf-instance-2" --format="value(id)")
echo "tf-instance-1 ID: $ID1"
echo "tf-instance-2 ID: $ID2"


# =====================================================
# TASK 1: Create the configuration files
# =====================================================
cd ~
mkdir -p modules/instances modules/storage
touch main.tf variables.tf
touch modules/instances/instances.tf modules/instances/outputs.tf modules/instances/variables.tf
touch modules/storage/storage.tf modules/storage/outputs.tf modules/storage/variables.tf

cat > variables.tf <<EOF
variable "region" {
  default = "$REGION"
}

variable "zone" {
  default = "$ZONE"
}

variable "project_id" {
  default = "$PROJECT_ID"
}
EOF

cat > modules/instances/variables.tf <<EOF
variable "region" {
  default = "$REGION"
}

variable "zone" {
  default = "$ZONE"
}

variable "project_id" {
  default = "$PROJECT_ID"
}
EOF

cat > modules/storage/variables.tf <<EOF
variable "region" {
  default = "$REGION"
}

variable "zone" {
  default = "$ZONE"
}

variable "project_id" {
  default = "$PROJECT_ID"
}
EOF

cat > main.tf <<EOF
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
EOF

terraform init


# =====================================================
# TASK 2: Import infrastructure
# =====================================================
cat > modules/instances/instances.tf <<EOF
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
EOF

terraform import module.instances.google_compute_instance.tf-instance-1 $ID1
terraform import module.instances.google_compute_instance.tf-instance-2 $ID2

terraform plan
terraform apply -auto-approve


# =====================================================
# TASK 3: Configure a remote backend
# =====================================================
cat > modules/storage/storage.tf <<EOF
resource "google_storage_bucket" "storage-bucket" {
  name                        = "$BUCKET"
  location                    = "US"
  force_destroy               = true
  uniform_bucket_level_access = true
}
EOF

cat > main.tf <<EOF
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
EOF

terraform init
terraform apply -auto-approve

cat > main.tf <<EOF
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
EOF

terraform init -migrate-state -force-copy


# =====================================================
# TASK 4: Modify and update infrastructure
# =====================================================
cat > modules/instances/instances.tf <<EOF
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
EOF

terraform init
terraform apply -auto-approve


# =====================================================
# TASK 5: Destroy resources
# =====================================================
cat > modules/instances/instances.tf <<EOF
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
EOF

terraform init
terraform apply -auto-approve


# =====================================================
# TASK 6: Use a module from the Registry (VPC, v10.0.0)
# =====================================================
cat >> main.tf <<EOF

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
EOF

terraform init
terraform apply -auto-approve

cat > modules/instances/instances.tf <<EOF
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
EOF

terraform init
terraform apply -auto-approve


# =====================================================
# TASK 7: Configure a firewall
# =====================================================
cat >> main.tf <<EOF

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
EOF

terraform init
terraform apply -auto-approve


# ---------- Verify ----------
echo
terraform state list
echo
echo "ALL TASKS COMPLETE. Now click 'Check my progress' on each task."
