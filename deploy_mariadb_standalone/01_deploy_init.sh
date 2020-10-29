#!/bin/bash
### initialize digital ocean config ###
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

variable "DB_SUBNET_ID_AZA" {
  default = "europe-west2-a"
}

variable "DB_SUBNET_ID_AZB" {
  default = "europe-west2-b"
}

variable "DB_SUBNET_ID_AZC" {
  default = "europe-west2-c"
}

variable "DB_INSTANCE_TYPE" {
  default = "n1-standard-4"
}

variable "PROXY_INSTANCE_TYPE" {
  default = "e2-standard-4"
}


variable "VPC_ID" {
  default = "default"
}

variable "IMAGE_ID" {
  default = "centos-7-v20200811"
}

variable "SSH_GCP_USER" {
  default = "gcp-user"
}

variable "SSH_PUBLIC_KEY" {
  default = "ansible.pub"
}
' > vars.tf

terraform init
