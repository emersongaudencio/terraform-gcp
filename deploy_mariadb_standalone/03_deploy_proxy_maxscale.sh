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

### deploy MaxScale ###
echo 'resource "google_compute_instance" "maxscale01" {
 name         = "maxscale01"
 machine_type = var.PROXY_INSTANCE_TYPE
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
}' > maxscale01.tf

echo '# Output the private IP address of the new droplet
output "private_ip_server_maxscale01" {  value = google_compute_instance.maxscale01.network_interface[0].network_ip }

# Output the public IP address of the new droplet
output "public_ip_server_maxscale01" {  value = google_compute_instance.maxscale01.network_interface[0].access_config[0].nat_ip }
' > output_proxyservers_mx.tf

### apply changes to digital ocean ###
terraform apply -auto-approve

### vars proxysql ###
# private ips
maxscale01_ip=`terraform output private_ip_server_maxscale01`
# public ips
maxscale01_ip_pub=`terraform output public_ip_server_maxscale01`

# create db_ips file for proxysql deployment #
echo "maxscale01:$maxscale01_ip" > proxymx_ips.txt

# create db_hosts file for ansible database replica setup #
echo "[proxyservers]" > ${OUTPUT_DIR}/proxymx_hosts.txt
echo "maxscale01 ansible_ssh_host=$maxscale01_ip_pub" >> ${OUTPUT_DIR}/proxymx_hosts.txt

# wait until databases are fully deployed #
sleep 90

# insert dns entries for ProxySQL on /etc/hosts
ansible -i ${OUTPUT_DIR}/proxymx_hosts.txt -m shell -a 'echo "# dbservers" >> /etc/hosts && echo "{{ dbprimary01_ip }} primary.db.local" >> /etc/hosts; cat /etc/hosts' maxscale01 -u $ansible_user --private-key=$priv_key --become -e "{dbprimary01_ip: '$dbprimary01_ip'}" -o > ${OUTPUT_DIR}/setup_proxy_dbservers_mx1.txt

# deploy MaxScale to the new VM instances using Ansible
ansible -i ${OUTPUT_DIR}/proxymx_hosts.txt -m shell -a "curl -sS https://raw.githubusercontent.com/emersongaudencio/general-deployment-scripts/master/automation/install_ansible_maxscale_primary_standalone.sh | bash" proxyservers -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/install_proxysql_proxyservers_mx1.txt

# setup proxysql user for monitoring purpose #
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "mysql -N -e \"CREATE USER 'maxscalechk'@'%' IDENTIFIED BY 'Test123?dba'; GRANT SELECT ON mysql.* TO 'maxscalechk'@'%'; GRANT SHOW DATABASES ON *.* TO 'maxscalechk'@'%';\"" dbprimary01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_proxysql_maxscalechk.txt
ansible -i ${OUTPUT_DIR}/db_hosts.txt -m shell -a "mysql -N -e \"CREATE USER 'monitor_user'@'%' IDENTIFIED BY 'Test123?dba'; GRANT SUPER, RELOAD, REPLICATION CLIENT, REPLICATION SLAVE on *.* to 'monitor_user'@'%';\"" dbprimary01 -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/setup_replication_proxysql_monitor_user.txt


echo "MaxScale deployment has been completed successfully!"
