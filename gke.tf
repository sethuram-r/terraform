variable "gke_username" {
  default     = ""
  description = "gke username"
}

variable "gke_password" {
  default     = ""
  description = "gke password"
}

variable "gke_num_nodes" {
  default     = 1
  description = "number of gke nodes"
}

variable "auth0_token" {}
variable "aws_root_access_key" {}
variable "aws_root_secret_key" {}

######################################################## aws part ########################################################

provider "aws" {
  version = "~> 2.0"
  region  = "us-east-1"
  access_key = var.aws_root_access_key
  secret_key = var.aws_root_secret_key
}
//export TF_VAR_auth0_token=

module "bucket_access"{
  bucket_name = "smartshare_user_dev"
  source="./s3"
}


##########################################################################################################################


# GKE cluster
resource "google_container_cluster" "primary" {
  name     = "${var.project_id}-gke"
  location = var.region

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  master_auth {
    username = var.gke_username
    password = var.gke_password

    client_certificate_config {
      issue_client_certificate = false
    }
  }
}

# Separately Managed Node Pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "${google_container_cluster.primary.name}-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = var.gke_num_nodes

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    labels = {
      env = var.project_id
    }

    # preemptible  = true
    machine_type = "n1-standard-1"
    tags         = ["gke-node", "${var.project_id}-gke"]
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${var.region};echo $?"
  }

}


resource "google_compute_address" "frontend" {
  name = "frontend-ip"
   depends_on = [google_container_node_pool.primary_nodes]
}

output "frontend-ip" {
  value       = google_compute_address.frontend.address
}

resource "google_compute_address" "gateway" {
  name = "gateway-ip"
   depends_on = [google_container_node_pool.primary_nodes]
  }

  output "gateway-ip" {
  value       = google_compute_address.gateway.address
}

output "kubernetes_cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE Cluster Name"
}


resource "null_resource" "passing_aws_secret" {
  provisioner "local-exec" {
  command = "kubectl create secret generic aws-credentials --from-literal=aws_access_key=${module.bucket_access.access_key} --from-literal=aws_secret_key=${module.bucket_access.secret} --from-literal=aws_region='us-east-1'"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

  resource "null_resource" "modifying_kubectl_services_yamls" {
  provisioner "local-exec" {
  working_dir = "${path.module}/k8s" 
  command = "yq w -i frontend-services.yaml 'spec.loadBalancerIP'  ${google_compute_address.frontend.address} --style=double;yq w -i gateway-service.yaml 'spec.loadBalancerIP'  ${google_compute_address.gateway.address} --style=double"

  }
  depends_on = [null_resource.passing_aws_secret]
  }

  resource "null_resource" "modifying_kubectl_deployment_yamls" {
  provisioner "local-exec" {
  working_dir = "${path.module}/k8s" 

  command = <<EOT
  yq w -i frontend-deployment.yaml 'spec.template.spec.containers[0].env[0].value'  http://${google_compute_address.gateway.address}:8081 --style=double
  yq w -i frontend-deployment.yaml 'spec.template.spec.containers[0].env[1].value'  http://${google_compute_address.frontend.address}:4200 --style=double
  yq w -i gateway-deployment.yaml 'spec.template.spec.containers[0].env[0].value'  http://${google_compute_address.frontend.address}:4200 --style=double
  EOT
   }
   depends_on = [null_resource.modifying_kubectl_services_yamls]
 
  }

resource "null_resource" "execute_kubectl_commands" {
  provisioner "local-exec" {
  working_dir = "${path.module}/k8s" 
  command= <<EOT
  kubectl apply -f kafka.yaml;kubectl apply -f postgres.yaml;kubectl apply -f redis.yaml;kubectl apply -f lock-deployment.yaml;kubectl apply -f lock-service.yaml;kubectl apply -f admin-deployment.yaml
  kubectl apply -f admin-service.yaml;kubectl apply -f core-deployment.yaml;kubectl apply -f core-service.yaml
  kubectl apply -f gateway-service.yaml;kubectl apply -f frontend-services.yaml
  kubectl apply -f gateway-deployment.yaml;kubectl apply -f frontend-deployment.yaml
EOT
  }
  depends_on = [null_resource.modifying_kubectl_deployment_yamls]
  }


resource "null_resource" "configure_auth0" {
  provisioner "local-exec" {
  working_dir = "."  
  command = <<EOT
  callb1="http://${google_compute_address.frontend.address}:4200/signin-callback"
  callb2="http://${google_compute_address.frontend.address}:4200/assets/silent-callback.html"
  origins="http://${google_compute_address.frontend.address}:4200/assets/silent-callback.html"
  allow="http://${google_compute_address.frontend.address}:4200/signout-callback"
  jq --arg c1 $callb1  --arg c2 $callb2  --arg o $origins  --arg  a $allow '.callbacks[2]=$c1|.callbacks[3]=$c2|.allowed_origins[1]=$o| .web_origins[1]=$o| .allowed_logout_urls[1]=$a' auth.json >auth1.json
  curl -H 'Authorization: Bearer ${var.auth0_token}' -X PATCH  -H 'Content-Type: application/json' -d @auth1.json https://smartshare.eu.auth0.com/api/v2/clients/KLGG9PHgbxBwiHJinbFByrLdbYg1Gll5
  EOT
  }
  }