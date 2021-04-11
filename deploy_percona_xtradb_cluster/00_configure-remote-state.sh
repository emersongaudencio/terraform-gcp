#!/bin/bash
# https://www.terraform.io/docs/language/settings/backends/gcs.html
# backend remote state
echo 'terraform {
  backend "gcs" {
    bucket      = "terraform-state-turbo-dba-dev-gcp"
    prefix      = "xtradb-galera-cluster/terraform.tfstate"
    credentials = "CREDENTIALS_FILE.json"
  }
}
' > backend.tf
