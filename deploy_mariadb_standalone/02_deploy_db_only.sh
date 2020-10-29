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
### deploy databases ###
echo 'resource "google_compute_instance" "dbprimary01" {
 name         = "dbprimary01"
 machine_type = var.DB_INSTANCE_TYPE
 zone         = var.DB_SUBNET_ID_AZA

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
}' > dbprimary01.tf


echo '# Output the private IP address of the new VM instance
output "private_ip_server_dbprimary01" {  value = google_compute_instance.dbprimary01.network_interface[0].network_ip }

# Output the public IP address of the new VM instance
output "public_ip_server_dbprimary01" {  value = google_compute_instance.dbprimary01.network_interface[0].access_config[0].nat_ip }
' > output_dbservers.tf

### apply changes to digital ocean ###
terraform apply -auto-approve

### vars databases ###
# private ips
dbprimary01_ip=`terraform output private_ip_server_dbprimary01`
# public ips
dbprimary01_ip_pub=`terraform output public_ip_server_dbprimary01`

# create db_ips file for proxysql deployment #
echo "dbprimary01:$dbprimary01_ip" > ${OUTPUT_DIR}/db_ips.txt

# create db_hosts file for ansible database replica setup #
echo "[dbservers]" > ${OUTPUT_DIR}/db_hosts.txt
echo "dbprimary01 ansible_ssh_host=$dbprimary01_ip_pub" >> ${OUTPUT_DIR}/db_hosts.txt

# wait until ssh conn are fully deployed #
sleep 90

# deploy MariaDB to the new VM instances using Ansible
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "curl -sS https://raw.githubusercontent.com/emersongaudencio/general-deployment-scripts/master/automation/install_ansible_mariadb_104.sh | sudo bash" dbservers -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/install_mariadb_dbservers.txt

# wait until databases are fully deployed #
sleep 60

# setup proxysql user for monitoring purpose #
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "mysql -N -e \"GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'proxysqlchk'@'%' IDENTIFIED BY 'Test123?dba';\"" dbprimary01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_proxysql_user.txt

echo "Database deployment has been completed successfully!"
