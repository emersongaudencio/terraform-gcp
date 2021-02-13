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

echo 'resource "google_compute_instance" "dbreplica01" {
 name         = "dbreplica01"
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
}' > dbreplica01.tf

echo 'resource "google_compute_instance" "dbreplica02" {
 name         = "dbreplica02"
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
}' > dbreplica02.tf

echo '# Output the private IP address of the new VM instance
output "private_ip_server_dbprimary01" {  value = google_compute_instance.dbprimary01.network_interface[0].network_ip }
output "private_ip_server_dbreplica01" {  value = google_compute_instance.dbreplica01.network_interface[0].network_ip}
output "private_ip_server_dbreplica02" {  value = google_compute_instance.dbreplica02.network_interface[0].network_ip }

# Output the public IP address of the new VM instance
output "public_ip_server_dbprimary01" {  value = google_compute_instance.dbprimary01.network_interface[0].access_config[0].nat_ip }
output "public_ip_server_dbreplica01" {  value = google_compute_instance.dbreplica01.network_interface[0].access_config[0].nat_ip }
output "public_ip_server_dbreplica02" {  value = google_compute_instance.dbreplica02.network_interface[0].access_config[0].nat_ip }
' > output_dbservers.tf

### apply changes to digital ocean ###
terraform apply -auto-approve

### vars databases ###
# private ips
dbprimary01_ip=`terraform output private_ip_server_dbprimary01`
dbreplica01_ip=`terraform output private_ip_server_dbreplica01`
dbreplica02_ip=`terraform output private_ip_server_dbreplica02`
# public ips
dbprimary01_ip_pub=`terraform output public_ip_server_dbprimary01`
dbreplica01_ip_pub=`terraform output public_ip_server_dbreplica01`
dbreplica02_ip_pub=`terraform output public_ip_server_dbreplica02`

# create db_ips file for proxysql deployment #
echo "dbprimary01:$dbprimary01_ip" > ${OUTPUT_DIR}/db_ips.txt
echo "dbreplica01:$dbreplica01_ip" >> ${OUTPUT_DIR}/db_ips.txt
echo "dbreplica02:$dbreplica02_ip" >> ${OUTPUT_DIR}/db_ips.txt

# create db_hosts file for ansible database replica setup #
echo "[dbservers]" > ${OUTPUT_DIR}/db_hosts.txt
echo "dbprimary01 ansible_ssh_host=$dbprimary01_ip_pub" >> ${OUTPUT_DIR}/db_hosts.txt
echo "dbreplica01 ansible_ssh_host=$dbreplica01_ip_pub" >> ${OUTPUT_DIR}/db_hosts.txt
echo "dbreplica02 ansible_ssh_host=$dbreplica02_ip_pub" >> ${OUTPUT_DIR}/db_hosts.txt

# wait until ssh conn are fully deployed #
sleep 90

# deploy MariaDB to the new VM instances using Ansible
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "curl -sS https://raw.githubusercontent.com/emersongaudencio/general-deployment-scripts/master/automation/install_ansible_mysql_57.sh | bash" dbservers -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/install_mariadb_dbservers.txt

# wait until databases are fully deployed #
sleep 60

# replication setup using ansbile for automation purpose #
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "mysql -N -e 'show master status'" dbprimary01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_master_position.txt
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "cat /root/.my.cnf | grep replication_user" dbprimary01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_user_master.txt
# get replication_credentials info
rep_user=$(cat ${OUTPUT_DIR}/setup_replication_user_master.txt | awk -F "|" {'print $4'} | awk {'print $3'})
rep_pwd=$(cat ${OUTPUT_DIR}/setup_replication_user_master.txt | awk -F "|" {'print $4'} | awk {'print $6'})
# get replication file info #
log_file=$(cat ${OUTPUT_DIR}/setup_replication_master_position.txt | awk -F "|" {'print $4'} | awk {'print $2'})
log_position=$(cat ${OUTPUT_DIR}/setup_replication_master_position.txt | awk -F "|" {'print $4'} | awk {'print $3'})
gtid_position=$(cat ${OUTPUT_DIR}/setup_replication_master_position.txt | awk -F "|" {'print $4'} | awk {'print $4'})
# setup replica read_only = ON #
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "mysql -N -e 'set global read_only = 1; select @@read_only;'; echo '# readonly-mode' >> /etc/my.cnf && echo 'read_only = 1' >> /etc/my.cnf && echo 'innodb_flush_log_at_trx_commit = 2' >> /etc/my.cnf ;" dbreplica01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_dbreplica01_read_only.txt
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "mysql -N -e 'set global read_only = 1; select @@read_only;'; echo '# readonly-mode' >> /etc/my.cnf && echo 'read_only = 1' >> /etc/my.cnf && echo 'innodb_flush_log_at_trx_commit = 2' >> /etc/my.cnf ;" dbreplica02 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_dbreplica02_read_only.txt
# setup replication on replica servers #
master_host=$(cat ${OUTPUT_DIR}/db_ips.txt | grep dbprimary01 | awk -F ":" {'print $2'})
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a 'mysql -N -e "RESET MASTER; SET @@GLOBAL.GTID_PURGED=\"{{ gtid }}\"; CHANGE MASTER TO master_host=\"{{ master_host }}\", master_port=3306, master_user=\"{{ master_user }}\", master_password = \"{{ master_password }}\", MASTER_AUTO_POSITION=1; START SLAVE; SHOW SLAVE STATUS\G"' dbreplica01 -u $ansible_user --private-key=/root/repos/ansible_keys/ansible --become -e "{master_host: '$master_host', master_user: '$rep_user' , master_password: '$rep_pwd', master_log_file: '$log_file' , master_log_pos: '$log_position', gtid: '$gtid_position' }" -o > ${OUTPUT_DIR}/setup_replication_dbreplica01_activation.txt
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a 'mysql -N -e "RESET MASTER; SET @@GLOBAL.GTID_PURGED=\"{{ gtid }}\"; CHANGE MASTER TO master_host=\"{{ master_host }}\", master_port=3306, master_user=\"{{ master_user }}\", master_password = \"{{ master_password }}\", MASTER_AUTO_POSITION=1; START SLAVE; SHOW SLAVE STATUS\G"' dbreplica02 -u $ansible_user --private-key=/root/repos/ansible_keys/ansible --become -e "{master_host: '$master_host', master_user: '$rep_user' , master_password: '$rep_pwd', master_log_file: '$log_file' , master_log_pos: '$log_position', gtid: '$gtid_position' }" -o > ${OUTPUT_DIR}/setup_replication_dbreplica02_activation.txt

# setup proxysql user for monitoring purpose #
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "mysql -N -e \"CREATE USER 'proxysqlchk'@'%' IDENTIFIED BY 'Test123?dba'; GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'proxysqlchk'@'%';\"" dbprimary01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_proxysql_user.txt
# restart replicas #
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "sudo service mysqld restart" dbreplica01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_dbreplica01_restart.txt
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "sudo service mysqld restart" dbreplica02 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_dbreplica02_restart.txt

echo "Database deployment has been completed successfully!"
