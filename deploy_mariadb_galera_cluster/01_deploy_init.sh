#!/bin/bash
### initialize digital ocean config ###
echo 'terraform {
  required_version = ">= 0.12"
}' > version.tf

echo 'provider "google" {
 credentials = file("CREDENTIALS_FILE.json")
 project     = "turbodba-dev"
 region      = "europe-west2"
}' > provider_gcp.tf

terraform init
