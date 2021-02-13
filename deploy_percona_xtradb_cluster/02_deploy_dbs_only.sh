#!/bin/bash
### output directory ###
OUTPUT_DIR="output"
if [ ! -d ${OUTPUT_DIR} ]; then
    mkdir -p ${OUTPUT_DIR}
    chmod 755 ${OUTPUT_DIR}
fi
### deploy databases ###
echo 'resource "google_compute_instance" "dbcluster01" {
 name         = "dbcluster01"
 machine_type = var.DB_INSTANCE_TYPE
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
}' > dbcluster01.tf

echo 'resource "google_compute_instance" "dbcluster02" {
 name         = "dbcluster02"
 machine_type = var.DB_INSTANCE_TYPE
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
}' > dbcluster02.tf

echo 'resource "google_compute_instance" "dbcluster03" {
 name         = "dbcluster03"
 machine_type = var.DB_INSTANCE_TYPE
 zone         = var.DB_SUBNET_ID_AZC

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
}' > dbcluster03.tf

echo '# Output the private IP address of the new droplet
output "private_ip_server_dbcluster01" {  value = google_compute_instance.dbcluster01.network_interface[0].network_ip }
output "private_ip_server_dbcluster02" {  value = google_compute_instance.dbcluster02.network_interface[0].network_ip }
output "private_ip_server_dbcluster03" {  value = google_compute_instance.dbcluster03.network_interface[0].network_ip }

# Output the public IP address of the new droplet
output "public_ip_server_dbcluster01" {  value = google_compute_instance.dbcluster01.network_interface[0].access_config[0].nat_ip }
output "public_ip_server_dbcluster02" {  value = google_compute_instance.dbcluster02.network_interface[0].access_config[0].nat_ip }
output "public_ip_server_dbcluster03" {  value = google_compute_instance.dbcluster03.network_interface[0].access_config[0].nat_ip }
' > output_dbservers.tf

### apply changes to digital ocean ###
terraform apply -auto-approve

### vars databases ###
# private ips
dbcluster01_ip=`terraform output private_ip_server_dbcluster01`
dbcluster02_ip=`terraform output private_ip_server_dbcluster02`
dbcluster03_ip=`terraform output private_ip_server_dbcluster03`
# public ips
dbcluster01_ip_pub=`terraform output public_ip_server_dbcluster01`
dbcluster02_ip_pub=`terraform output public_ip_server_dbcluster02`
dbcluster03_ip_pub=`terraform output public_ip_server_dbcluster03`

# create db_ips file for proxysql deployment #
echo "dbcluster01_ip:$dbcluster01_ip" > ${OUTPUT_DIR}/db_ips.txt
echo "dbcluster02_ip:$dbcluster02_ip" >> ${OUTPUT_DIR}/db_ips.txt
echo "dbcluster03_ip:$dbcluster03_ip" >> ${OUTPUT_DIR}/db_ips.txt

# create db_hosts file for ansible database replica setup #
echo "[galeracluster]" > ${OUTPUT_DIR}/db_hosts.txt
echo "dbcluster01 ansible_ssh_host=$dbcluster01_ip_pub" >> ${OUTPUT_DIR}/db_hosts.txt
echo "dbcluster02 ansible_ssh_host=$dbcluster02_ip_pub" >> ${OUTPUT_DIR}/db_hosts.txt
echo "dbcluster03 ansible_ssh_host=$dbcluster03_ip_pub" >> ${OUTPUT_DIR}/db_hosts.txt

### pre-reqs install ###
curl -s https://raw.githubusercontent.com/emersongaudencio/general-deployment-scripts/master/automation/install_ansible_latest.sh -o install_ansible_latest.sh
sh install_ansible_latest.sh

# Percona XtraDB Galera Cluster installation setup #
git clone https://github.com/emersongaudencio/ansible-percona-xtradb-cluster.git
cd ansible-percona-xtradb-cluster/ansible
priv_key="/root/repos/ansible_keys/ansible"
# adjusting ansible parameters
sed -ie 's/ansible/\/usr\/local\/bin\/ansible/g' run_xtradb_galera_install.sh
sed -ie 's/# remote_user = ec2-user/remote_user = gcp-user/g' ansible.cfg
#### XtraDB deployment variables ####
GTID=$(($RANDOM))
echo $GTID > GTID
PXC_VERSION="80"
echo $PXC_VERSION > PXC_VERSION
CLUSTER_NAME="pxc80"
echo $CLUSTER_NAME > CLUSTER_NAME
#### Percona XtraDB deployment ansible hosts variables ####
echo "[galeracluster]" > hosts
echo "dbcluster01 ansible_ssh_host=$dbcluster01_ip_pub" >> hosts
echo "dbcluster02 ansible_ssh_host=$dbcluster02_ip_pub" >> hosts
echo "dbcluster03 ansible_ssh_host=$dbcluster03_ip_pub" >> hosts
#### private key link ####
ln -s $priv_key ansible
#### Execution section ####
sudo sh run_xtradb_galera_install.sh dbcluster01 $PXC_VERSION $GTID "$dbcluster01_ip" "$CLUSTER_NAME" "$dbcluster01_ip,$dbcluster02_ip,$dbcluster03_ip"
sleep 30
sudo sh run_xtradb_galera_install.sh dbcluster02 $PXC_VERSION $GTID "$dbcluster01_ip" "$CLUSTER_NAME" "$dbcluster01_ip,$dbcluster02_ip,$dbcluster03_ip"
sleep 30
sudo sh run_xtradb_galera_install.sh dbcluster03 $PXC_VERSION $GTID "$dbcluster01_ip" "$CLUSTER_NAME" "$dbcluster01_ip,$dbcluster02_ip,$dbcluster03_ip"

# setup proxysql user for monitoring purpose #
ansible -i hosts -m shell -a "mysql -N -e \"CREATE USER 'proxysqlchk'@'%' IDENTIFIED BY 'Test123?dba'; GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'proxysqlchk'@'%';\"" dbcluster01 -o > setup_galeracluster_proxysql_user.txt

echo "Database deployment has been completed successfully!"
