#!/bin/bash
### output directory ###
OUTPUT_DIR="output"
if [ ! -d ${OUTPUT_DIR} ]; then
    mkdir -p ${OUTPUT_DIR}
    chmod 755 ${OUTPUT_DIR}
fi
### deploy databases ###
echo '// A single Compute Engine instance
resource "google_compute_instance" "dbcluster01" {
 name         = "dbcluster01"
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
}' > dbcluster01.tf

echo '// A single Compute Engine instance
resource "google_compute_instance" "dbcluster02" {
 name         = "dbcluster02"
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
}' > dbcluster02.tf

echo '// A single Compute Engine instance
resource "google_compute_instance" "dbcluster03" {
 name         = "dbcluster03"
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

#### install python2 #####
verify_python=`rpm -qa | grep python-2.7`
if [[ "${verify_python}" == "python-2.7"* ]] ; then
echo "$verify_python is installed!"
else
   sudo yum install python -y
fi

#### install git #####
verify_git=`rpm -qa | grep git-1`
if [[ "${verify_git}" == "git"* ]] ; then
echo "$verify_git is installed!"
else
   sudo yum install git -y
fi

#### install pip #####
verify_pip=`pip -V`
if [[ "${verify_pip}" == "pip"* ]] ; then
echo "$verify_pip is installed!"
else
   curl -sS https://bootstrap.pypa.io/get-pip.py | sudo python
fi

#### install ansible #####
verify_ansible=`ansible --version`
if [[ "${verify_ansible}" == "ansible"* ]] ; then
echo "$verify_ansible is installed!"
else
  sudo pip install ansible --upgrade
  ansible --version
fi

sleep 90

# MariaDB Galera Cluster installation setup #
git clone https://github.com/emersongaudencio/ansible-mariadb-galera-cluster.git
cd ansible-mariadb-galera-cluster/ansible
priv_key="/root/repos/ansible_keys/ansible"
sed -ie 's/# remote_user = ec2-user/remote_user = gcp-user/g' ansible.cfg
#### MariaDB deployment variables ####
GTID=$(($RANDOM))
echo $GTID > GTID
MARIADB_VERSION="104"
echo $MARIADB_VERSION > MARIADB_VERSION
CLUSTER_NAME="mariadbcluster"
echo $CLUSTER_NAME > CLUSTER_NAME
#### MariaDB deployment ansible hosts variables ####
echo "[galeracluster]" > hosts
echo "dbcluster01 ansible_ssh_host=$dbcluster01_ip_pub" >> hosts
echo "dbcluster02 ansible_ssh_host=$dbcluster02_ip_pub" >> hosts
echo "dbcluster03 ansible_ssh_host=$dbcluster03_ip_pub" >> hosts
#### private key link ####
ln -s $priv_key ansible
#### Execution section ####
sudo sh run_mariadb_galera_install.sh dbcluster01 $MARIADB_VERSION $GTID "$dbcluster01_ip" "$CLUSTER_NAME" "$dbcluster01_ip,$dbcluster02_ip,$dbcluster03_ip"
sleep 30
sudo sh run_mariadb_galera_install.sh dbcluster02 $MARIADB_VERSION $GTID "$dbcluster01_ip" "$CLUSTER_NAME" "$dbcluster01_ip,$dbcluster02_ip,$dbcluster03_ip"
sleep 30
sudo sh run_mariadb_galera_install.sh dbcluster03 $MARIADB_VERSION $GTID "$dbcluster01_ip" "$CLUSTER_NAME" "$dbcluster01_ip,$dbcluster02_ip,$dbcluster03_ip"

# setup proxysql user for monitoring purpose #
ansible -i hosts -m shell -a "mysql -N -e \"GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'proxysqlchk'@'%' IDENTIFIED BY 'Test123?dba';\"" dbcluster01 -o > setup_galeracluster_proxysql_user.txt

echo "Database deployment has been completed successfully!"
