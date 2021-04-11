#!/bin/bash
### initialize gcp config ###
echo 'terraform {
  required_version = ">= 0.12"
}' > version.tf

echo 'provider "google" {
 credentials = file("CREDENTIALS_FILE.json")
 project     = "turbodba-dev"
 region      = var.GCP_REGION
}' > provider_gcp.tf

echo 'variable "GCP_REGION" {
  default = "europe-west2"
}
' > vars.tf

### deploy gcs buckets ###
echo 'resource "google_storage_bucket" "terraform-state-prod" {
  name          = "terraform-state-prod-bucket"
  location      = "EU"
  versioning = true
}' > gcs_bucket.tf

### apply changes to GCP ###
terraform init
terraform apply -auto-approve
