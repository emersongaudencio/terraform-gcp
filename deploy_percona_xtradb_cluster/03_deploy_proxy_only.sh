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
### vars databases ###
dbcluster01_ip=$(cat ${OUTPUT_DIR}/db_ips.txt | grep dbcluster01 | awk -F ":" {'print $2'})
dbcluster02_ip=$(cat ${OUTPUT_DIR}/db_ips.txt | grep dbcluster02 | awk -F ":" {'print $2'})
dbcluster03_ip=$(cat ${OUTPUT_DIR}/db_ips.txt | grep dbcluster03 | awk -F ":" {'print $2'})

### deploy proxysql ###
echo 'resource "google_compute_instance" "proxysql01" {
 name         = "proxysql01"
 machine_type = var.PROXY_INSTANCE_TYPE
 zone         = var.DB_SUBNET_ID_AZA

 boot_disk {
   initialize_params {
     image = var.IMAGE_ID
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
}' > proxysql01.tf

echo 'resource "google_compute_instance" "proxysql02" {
 name         = "proxysql02"
 machine_type = var.PROXY_INSTANCE_TYPE
 zone         = var.DB_SUBNET_ID_AZB

 boot_disk {
   initialize_params {
     image = var.IMAGE_ID
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
}' > proxysql02.tf


echo '# Output the private IP address of the new droplet
output "private_ip_server_proxysql01" {  value = google_compute_instance.proxysql01.network_interface[0].network_ip }
output "private_ip_server_proxysql02" {  value = google_compute_instance.proxysql02.network_interface[0].network_ip }

# Output the public IP address of the new droplet
output "public_ip_server_proxysql01" {  value = google_compute_instance.proxysql01.network_interface[0].access_config[0].nat_ip }
output "public_ip_server_proxysql02" {  value = google_compute_instance.proxysql02.network_interface[0].access_config[0].nat_ip }
' > output_proxyservers.tf

### apply changes to digital ocean ###
terraform apply -auto-approve

### vars proxysql ###
# private ips
proxysql01_ip=`terraform output private_ip_server_proxysql01`
proxysql02_ip=`terraform output private_ip_server_proxysql02`
# public ips
proxysql01_ip_pub=`terraform output public_ip_server_proxysql01`
proxysql02_ip_pub=`terraform output public_ip_server_proxysql02`

# create db_ips file for proxysql deployment #
echo "proxysql01:$proxysql01_ip" > proxy_ips.txt
echo "proxysql02:$proxysql02_ip" >> proxy_ips.txt

# create db_hosts file for ansible database replica setup #
echo "[proxyservers]" > ${OUTPUT_DIR}/proxy_hosts.txt
echo "proxysql01 ansible_ssh_host=$proxysql01_ip_pub" >> ${OUTPUT_DIR}/proxy_hosts.txt
echo "proxysql02 ansible_ssh_host=$proxysql02_ip_pub" >> ${OUTPUT_DIR}/proxy_hosts.txt

# wait until databases are fully deployed #
sleep 90

# deploy ProxySQL to the new VM instances using Ansible
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a "curl -sS https://raw.githubusercontent.com/emersongaudencio/general-deployment-scripts/master/automation/install_ansible_proxysql2_galera.sh | bash" proxyservers -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/install_proxysql_proxyservers.txt

# insert dns entries for ProxySQL on /etc/hosts
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a 'echo "{{ dbcluster01_ip }} dbnode01.cluster.local" >> /etc/hosts && echo "{{ dbcluster02_ip }} dbnode02.cluster.local" >> /etc/hosts && echo "{{ dbcluster03_ip }} dbnode03.cluster.local" >> /etc/hosts; cat /etc/hosts' proxysql01 -u $ansible_user --private-key=$priv_key --become -e "{dbcluster01_ip: '$dbcluster01_ip', dbcluster02_ip: '$dbcluster02_ip', dbcluster03_ip: '$dbcluster03_ip'}" -o > ${OUTPUT_DIR}/setup_proxy_dbservers_px1.txt
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a 'echo "{{ dbcluster01_ip }} dbnode01.cluster.local" >> /etc/hosts && echo "{{ dbcluster02_ip }} dbnode02.cluster.local" >> /etc/hosts && echo "{{ dbcluster03_ip }} dbnode03.cluster.local" >> /etc/hosts; cat /etc/hosts' proxysql02 -u $ansible_user --private-key=$priv_key --become -e "{dbcluster01_ip: '$dbcluster01_ip', dbcluster02_ip: '$dbcluster02_ip', dbcluster03_ip: '$dbcluster03_ip'}" -o > ${OUTPUT_DIR}/setup_proxy_dbservers_px2.txt

echo "ProxySQL deployment has been completed successfully!"
