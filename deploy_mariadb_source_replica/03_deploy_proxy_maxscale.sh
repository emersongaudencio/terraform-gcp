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
dbstandby01_ip=$(cat ${OUTPUT_DIR}/db_ips.txt | grep dbstandby01 | awk -F ":" {'print $2'})

### deploy proxysql ###
echo '// A single Compute Engine instance
resource "google_compute_instance" "maxscale01" {
 name         = "maxscale01"
 machine_type = "n1-standard-4"
 zone         = "europe-west2-a"

 boot_disk {
   initialize_params {
     image = "centos-7-v20200811"
   }
 }

 network_interface {
   network = "default"

   access_config {
     // Include this section to give the VM an external ip address
   }
 }

 metadata = {
   ssh-keys = "gcp-user:${file("ansible.pub")}"
 }
}' > maxscale01.tf

echo '// A single Compute Engine instance
resource "google_compute_instance" "maxscale02" {
 name         = "maxscale02"
 machine_type = "n1-standard-4"
 zone         = "europe-west2-a"

 boot_disk {
   initialize_params {
     image = "centos-7-v20200811"
   }
 }

 network_interface {
   network = "default"

   access_config {
     // Include this section to give the VM an external ip address
   }
 }

 metadata = {
   ssh-keys = "gcp-user:${file("ansible.pub")}"
 }
}' > maxscale02.tf


echo '# Output the private IP address of the new droplet
output "private_ip_server_maxscale01" {  value = google_compute_instance.maxscale01.network_interface[0].network_ip }
output "private_ip_server_maxscale02" {  value = google_compute_instance.maxscale02.network_interface[0].network_ip }

# Output the public IP address of the new droplet
output "public_ip_server_maxscale01" {  value = google_compute_instance.maxscale01.network_interface[0].access_config[0].nat_ip }
output "public_ip_server_maxscale02" {  value = google_compute_instance.maxscale02.network_interface[0].access_config[0].nat_ip }
' > output_proxyservers.tf

### apply changes to digital ocean ###
terraform apply -auto-approve

### vars proxysql ###
# private ips
maxscale01_ip=`terraform output private_ip_server_maxscale01`
maxscale02_ip=`terraform output private_ip_server_maxscale02`
# public ips
maxscale01_ip_pub=`terraform output public_ip_server_maxscale01`
maxscale02_ip_pub=`terraform output public_ip_server_maxscale02`

# create db_ips file for proxysql deployment #
echo "maxscale01:$maxscale01_ip" > proxy_ips.txt
echo "maxscale02:$maxscale02_ip" >> proxy_ips.txt

# create db_hosts file for ansible database replica setup #
echo "[proxyservers]" > ${OUTPUT_DIR}/proxy_hosts.txt
echo "maxscale01 ansible_ssh_host=$maxscale01_ip_pub" >> ${OUTPUT_DIR}/proxy_hosts.txt
echo "maxscale02 ansible_ssh_host=$maxscale02_ip_pub" >> ${OUTPUT_DIR}/proxy_hosts.txt

# wait until databases are fully deployed #
sleep 90

# insert dns entries for ProxySQL on /etc/hosts
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a 'echo "# dbservers" >> /etc/hosts && echo "{{ dbprimary01_ip }} dbprimary01.replication.local" >> /etc/hosts && echo "{{ dbstandby01_ip }} dbstandby01.replication.local" >> /etc/hosts; cat /etc/hosts' maxscale01 -u $ansible_user --private-key=$priv_key --become -e "{dbprimary01_ip: '$dbprimary01_ip', dbstandby01_ip: '$dbstandby01_ip'}" -o > ${OUTPUT_DIR}/setup_proxy_dbservers_mx1.txt
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a 'echo "# dbservers" >> /etc/hosts && echo "{{ dbprimary01_ip }} dbprimary01.replication.local" >> /etc/hosts && echo "{{ dbstandby01_ip }} dbstandby01.replication.local" >> /etc/hosts; cat /etc/hosts' maxscale02 -u $ansible_user --private-key=$priv_key --become -e "{dbprimary01_ip: '$dbprimary01_ip', dbstandby01_ip: '$dbstandby01_ip'}" -o > ${OUTPUT_DIR}/setup_proxy_dbservers_mx2.txt

# deploy MaxScale to the new VM instances using Ansible
ansible -i ${OUTPUT_DIR}/proxy_hosts.txt -m shell -a "curl -sS https://raw.githubusercontent.com/emersongaudencio/general-deployment-scripts/master/automation/install_ansible_maxscale_primary_standby.sh | sudo bash" proxyservers -u $ansible_user --private-key=$priv_key --become -o > ${OUTPUT_DIR}/install_proxysql_proxyservers.txt

echo "MaxScale deployment has been completed successfully!"
