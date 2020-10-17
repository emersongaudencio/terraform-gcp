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
dbprimary01_ip=$(cat ${OUTPUT_DIR}/db_ips.txt | grep dbprimary01 | awk -F ":" {'print $2'})
dbreplica01_ip=$(cat ${OUTPUT_DIR}/db_ips.txt | grep dbreplica01 | awk -F ":" {'print $2'})
dbreplica02_ip=$(cat ${OUTPUT_DIR}/db_ips.txt | grep dbreplica02 | awk -F ":" {'print $2'})

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
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a "curl -sS https://raw.githubusercontent.com/emersongaudencio/general-deployment-scripts/master/automation/install_ansible_proxysql2_replica.sh | sudo bash" proxyservers -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/install_proxysql_proxyservers.txt

# insert dns entries for ProxySQL on /etc/hosts
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a 'echo "# dbservers" >> /etc/hosts && echo "{{ dbprimary01_ip }} primary.replication.local" >> /etc/hosts && echo "{{ dbreplica01_ip }} replica1.replication.local" >> /etc/hosts && echo "{{ dbreplica02_ip }} replica2.replication.local" >> /etc/hosts; cat /etc/hosts' proxysql01 -u $ansible_user --private-key=$priv_key --become -e "{dbprimary01_ip: '$dbprimary01_ip', dbreplica01_ip: '$dbreplica01_ip', dbreplica02_ip: '$dbreplica02_ip'}" -o > ${OUTPUT_DIR}/setup_proxy_dbservers_px1.txt
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a 'echo "# dbservers" >> /etc/hosts && echo "{{ dbprimary01_ip }} primary.replication.local" >> /etc/hosts && echo "{{ dbreplica01_ip }} replica1.replication.local" >> /etc/hosts && echo "{{ dbreplica02_ip }} replica2.replication.local" >> /etc/hosts; cat /etc/hosts' proxysql02 -u $ansible_user --private-key=$priv_key --become -e "{dbprimary01_ip: '$dbprimary01_ip', dbreplica01_ip: '$dbreplica01_ip', dbreplica02_ip: '$dbreplica02_ip'}" -o > ${OUTPUT_DIR}/setup_proxy_dbservers_px2.txt

# deploy ProxySQL binlogreader on the Database SERVERS
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "yum -y install https://github.com/emersongaudencio/linux_packages/raw/master/RPM/proxysql-mysqlbinlog-1.0-1-centos7.x86_64.rpm; yum install boost-system -y;" dbservers -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/install_binlogreader_dbservers.txt

ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "mysql -N -e \"CREATE USER 'binlogreader'@'%' IDENTIFIED BY 'Test123dba'; GRANT SUPER, REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'binlogreader'@'%';\"" dbprimary01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_binlogreader_dbservers_user.txt

ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "proxysql_binlog_reader -h 127.0.0.1 -u binlogreader -pTest123dba -P 3306 -l 3307 -L /tmp/binlogreader.log" dbservers -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/startup_binlogreader_dbservers.txt

# insert binlogreader entries into ProxySQL
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a "mysql -N -e \"UPDATE mysql_servers SET gtid_port = 3307; LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; UPDATE mysql_query_rules SET gtid_from_hostgroup = 10 where rule_id = 200; LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK;
\"" proxyservers -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_binlogreader_proxyservers.txt

echo "ProxySQL deployment has been completed successfully!"
