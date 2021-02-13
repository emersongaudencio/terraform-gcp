#!/bin/bash
### output directory ###
OUTPUT_DIR="output"
if [ ! -d ${OUTPUT_DIR} ]; then
    mkdir -p ${OUTPUT_DIR}
    chmod 755 ${OUTPUT_DIR}
fi
### ansible config ###
export ANSIBLE_HOST_KEY_CHECKING=False
priv_key="/root/repos/ansible_keys/ansible"
ansible_user="gcp-user"

### deploy proxysql ###
echo 'resource "google_compute_disk" "pmmserver01-data-disk01" {
  name  = "pmmserver01-data-disk01"
  type  = "pd-standard"
  size = 100
  zone = "europe-west2-a"
}

resource "google_compute_instance" "pmmserver01" {
 name         = "pmmserver01"
 machine_type = "e2-standard-4"
 zone         = "europe-west2-a"

 boot_disk {
   initialize_params {
     image = var.IMAGE_ID
     size  = 50
   }
 }

 network_interface {
   network = var.VPC_ID

   access_config {
     // Include this section to give the VM an external ip address
   }
 }

 metadata = {
   ssh-keys = "${var.SSH_GCP_USER}:${file(var.SSH_PUBLIC_KEY)}"
 }
}

resource "google_compute_attached_disk" "default" {
  disk     = google_compute_disk.pmmserver01-data-disk01.id
  instance = google_compute_instance.pmmserver01.id
}' > pmmserver01.tf


echo '# Output the private IP address of the new VM
output "private_ip_server_pmmserver01" {  value = google_compute_instance.pmmserver01.network_interface[0].network_ip }

# Output the public IP address of the new VM
output "public_ip_server_pmmserver01" {  value = google_compute_instance.pmmserver01.network_interface[0].access_config[0].nat_ip }
' > output_pmmserver.tf

### apply changes to GCP ###
terraform apply -auto-approve

### vars pmm ###
# private ips
pmmserver01_ip=`terraform output private_ip_server_pmmserver01`
# public ips
pmmserver01_ip_pub=`terraform output public_ip_server_pmmserver01`

# create db_ips file for proxysql deployment #
echo "pmmserver01:$pmmserver01_ip" > pmmserver_ips.txt

# create db_hosts file for ansible setup #
echo "[monitoring]" > ${OUTPUT_DIR}/pmmserver_hosts.txt
echo "pmmserver01 ansible_ssh_host=$pmmserver01_ip_pub" >> ${OUTPUT_DIR}/pmmserver_hosts.txt

# wait until databases are fully deployed #
sleep 90

# Setup disks for PMM to the new VM instances using Ansible
ansible -i ${OUTPUT_DIR}/pmmserver_hosts.txt -m shell -a "curl -sS https://raw.githubusercontent.com/emersongaudencio/general-deployment-scripts/master/automation/setup_disks_pmm_server_standalone.sh | bash" pmmserver01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_disks_pmmserver01.txt

# deploy PMM to the new VM instances using Ansible
ansible -i ${OUTPUT_DIR}/pmmserver_hosts.txt -m shell -a "curl -sS https://raw.githubusercontent.com/emersongaudencio/general-deployment-scripts/master/automation/install_ansible_pmm_server_standalone.sh | bash" pmmserver01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/install_pmmserver01.txt

echo "PMM deployment has been completed successfully!"
