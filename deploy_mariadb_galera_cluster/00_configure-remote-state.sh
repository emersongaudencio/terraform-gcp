#!/bin/bash

# backend remote state
echo 'terraform {
  backend "gcs" {
    bucket      = "terraform-state-turbo-dba-dev-gcp"
    prefix      = "database-tfstate"
    credentials = "CREDENTIALS_FILE.json"
  }
}
' > backend.tf
