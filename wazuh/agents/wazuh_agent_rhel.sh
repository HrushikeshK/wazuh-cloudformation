#!/bin/bash
# Install Wazuh agent using Cloudformation template
# Deployment for Amazon Linux agent

touch /tmp/log
echo "Starting process." > /tmp/log

agent_name=$(cat /tmp/wazuh_cf_settings | grep '^AgentName:' | cut -d' ' -f2)
ssh_username=$(cat /tmp/wazuh_cf_settings | grep '^SshUsername:' | cut -d' ' -f2)
master_ip=$(cat /tmp/wazuh_cf_settings | grep '^WazuhMasterIP:' | cut -d' ' -f2)
elb_wazuh_dns=$(cat /tmp/wazuh_cf_settings | grep '^ElbWazuhDNS:' | cut -d' ' -f2)
ssh_password=$(cat /tmp/wazuh_cf_settings | grep '^SshPassword:' | cut -d' ' -f2)
wazuh_server_port=$(cat /tmp/wazuh_cf_settings | grep '^WazuhServerPort:' | cut -d' ' -f2)
wazuh_registration_password=$(cat /tmp/wazuh_cf_settings | grep '^WazuhRegistrationPassword:' | cut -d' ' -f2)
manager_config='/var/ossec/etc/ossec.conf'
# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi
echo "Env vars completed." >> /tmp/log

# Add SSH user
adduser ${ssh_username}
echo "${ssh_username} ALL=(ALL)NOPASSWD:ALL" >> /etc/sudoers
usermod --password $(openssl passwd -1 ${ssh_password}) ${ssh_username}
sed -i 's|[#]*PasswordAuthentication no|PasswordAuthentication yes|g' /etc/ssh/sshd_config
service sshd restart

# Install dependencies
yum install wget git -y

### Use case 1: Docker

# Add Docker-ce repo
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# add selinux dependencies 
yum install -y http://mirror.centos.org/centos/7/extras/x86_64/Packages/container-selinux-2.74-1.el7.noarch.rpm

# install Docker
yum install -y docker-ce

### Use case 2: Web server
yum install httpd -y
service httpd restart

### Use case 3: Mysql
wget https://repo.mysql.com//mysql80-community-release-el7-2.noarch.rpm
yum localinstall mysql80-community-release-el7-2.noarch.rpm -y
yum install mysql -y
yum install mysql-server -y

### Use case 4: Netcat
yum install nc -y

### Use case 5: OpenSCAP
yum install openscap -y

### Use case 6: Suricata
# Install Suricata
yum -y install suricata

### Use case 7: Diamorphine
yum install "kernel-devel-uname-r == $(uname -r)" -y
yum install gcc make epel-release -y
git clone https://github.com/m0nad/Diamorphine
cd Diamorphine
make

# Adding Wazuh repository
echo -e '[wazuh_pre_release]\ngpgcheck=1\ngpgkey=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/key/GPG-KEY-WAZUH\nenabled=1\nname=EL-$releasever - Wazuh\nbaseurl=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/pre-release/yum/\nprotect=1' | tee /etc/yum.repos.d/wazuh_pre.repo
# Installing wazuh-manager
yum -y install wazuh-agent
echo "Installed Wazuh agent." >> /tmp/log

# Change manager protocol to tcp, to be used by Amazon ELB
sed -i "s/<protocol>udp<\/protocol>/<protocol>tcp<\/protocol>/" ${manager_config}

# Set manager port for agent communications
sed -i "s/<port>1514<\/port>/<port>${wazuh_server_port}<\/port>/" ${manager_config}

# Setting password for agents registration
echo "${wazuh_registration_password}" > /var/ossec/etc/authd.pass
echo "Set Wazuh password registration." >> /tmp/log

# Register agent using authd
/var/ossec/bin/agent-auth -m ${master_ip} -A ${agent_name}
sed -i 's:MANAGER_IP:'${elb_wazuh_dns}':g' ${manager_config}
echo "Registered Wazuh agent." >> /tmp/log

# Restart wazuh-manager
/var/ossec/bin/ossec-control restart
echo "Restarted Wazuh agent." >> /tmp/log
