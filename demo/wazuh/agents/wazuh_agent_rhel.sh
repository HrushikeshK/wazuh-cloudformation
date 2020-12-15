#!/bin/bash
# Install Wazuh agent using Cloudformation template
# Deployment for Amazon Linux agent

touch /tmp/log
echo "Starting process." > /tmp/log

agent_name=$(cat /tmp/wazuh_cf_settings | grep '^AgentName:' | cut -d' ' -f2)
ssh_username=$(cat /tmp/wazuh_cf_settings | grep '^SshUsername:' | cut -d' ' -f2)
wazuh_version=$(cat /tmp/wazuh_cf_settings | grep '^Elastic_Wazuh:' | cut -d' ' -f2 | cut -d'_' -f2)
wazuh_major=`echo $wazuh_version | cut -d'.' -f1`
wazuh_minor=`echo $wazuh_version | cut -d'.' -f2`
wazuh_patch=`echo $wazuh_version | cut -d'.' -f3`
branch=$(cat /tmp/wazuh_cf_settings | grep '^Branch:' | cut -d' ' -f2)
master_ip=$(cat /tmp/wazuh_cf_settings | grep '^WazuhMasterIP:' | cut -d' ' -f2)
elb_wazuh_dns=$(cat /tmp/wazuh_cf_settings | grep '^ElbWazuhDNS:' | cut -d' ' -f2)
ssh_password=$(cat /tmp/wazuh_cf_settings | grep '^SshPassword:' | cut -d' ' -f2)
wazuh_server_port=$(cat /tmp/wazuh_cf_settings | grep '^WazuhServerPort:' | cut -d' ' -f2)
wazuh_registration_password=$(cat /tmp/wazuh_cf_settings | grep '^WazuhRegistrationPassword:' | cut -d' ' -f2)
manager_config='/var/ossec/etc/ossec.conf'
EnvironmentType=$(cat /tmp/wazuh_cf_settings | grep '^EnvironmentType:' | cut -d' ' -f2)

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
systemctl restart sshd

# Added trojan
cp /usr/bin/w /usr/bin/w.backup
rm /usr/bin/w

cat >> /usr/bin/w << EOF
#!/bin/bash
echo `date` this is evil   > /tmp/trojan_created_file
echo demo from /usr/bin/w  >> /tmp/trojan_created_file
EOF

# Install dependencies
yum install wget git python-requests -y
### Use case 1: Docker

# Add Docker-ce repo
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# add selinux dependencies
yum install -y http://mirror.centos.org/centos/7/extras/x86_64/Packages/container-selinux-2.107-1.el7_6.noarch.rpm
# install Docker
yum install -y docker-ce
systemctl restart docker

### Use case 2: Web server
yum install httpd -y
systemctl restart httpd

### Use case 3: Mysql
wget https://repo.mysql.com//mysql80-community-release-el7-2.noarch.rpm
yum localinstall mysql80-community-release-el7-2.noarch.rpm -y
yum install mysql -y
yum install mysql-server -y
systemctl restart mysqld
mkdir /mysql
touch /mysql/mysql.conf

### Use case 4: Netcat
yum install nc vim lsof openscap-scanner -y

### Use case 6: Suricata
# Install Suricata
yum -y install suricata-4.1.5
wget https://rules.emergingthreats.net/open/suricata-4.1.5/emerging.rules.tar.gz
tar zxvf emerging.rules.tar.gz
rm -f /etc/suricata/suricata.yaml
wget -O /etc/suricata/suricata.yaml http://www.branchnetconsulting.com/wazuh/suricata.yaml
tar -xvzf emerging.rules.tar.gz && mv rules/*.rules /etc/suricata/rules
sed -i '/rule-files:/,/#only use the scada_special if you have the scada extensions compiled int/{//!d}' /etc/suricata/suricata.yaml
sed -i '/rule-files/ a \  - "*.rules"' /etc/suricata/suricata.yaml
chown suricata:suricata /etc/suricata/rules/*.rules
chmod +r /etc/suricata/rules/*.rules
systemctl daemon-reload
systemctl enable suricata
systemctl start suricata
yum -y install audit

uid=$(id -u wazuh)

# Audit rules
cat >> /etc/audit/rules.d/audit.rules << EOF
-a exit,always -F euid=${uid} -F arch=b32 -S execve -k audit-wazuh-c
-a exit,always -F euid=${uid} -F arch=b64 -S execve -k audit-wazuh-c
EOF

auditctl -D
auditctl -R /etc/audit/rules.d/audit.rules
systemctl restart auditd

### Use case 7: Diamorphine
yum install "kernel-devel-uname-r == $(uname -r)" -y
yum install gcc make epel-release jq -y
git clone https://github.com/m0nad/Diamorphine
cd Diamorphine
make

# Install Osquery
yum install -y https://pkg.osquery.io/rpm/osquery-3.3.2-1.linux.x86_64.rpm
/etc/init.d/osqueryd restart
cat >>/etc/osquery/osquery.conf << EOF
{
    "options": {
        "config_plugin": "filesystem",
        "logger_plugin": "filesystem",
        "utc": "true"
    },

    "schedule": {
        "system_info": {
        "query": "SELECT hostname, cpu_brand, physical_memory FROM system_info;",
        "interval": 3600
        },
        "high_load_average": {
        "query": "SELECT period, average, '70%' AS 'threshold' FROM load_average WHERE period = '15m' AND average > '0.7';",
        "interval": 900,
        "description": "Report if load charge is over 70 percent."
        },
        "low_free_memory": {
        "query": "SELECT memory_total, memory_free, CAST(memory_free AS real) / memory_total AS memory_free_perc, '10%' AS threshold FROM memory_info WHERE memory_free_perc < 0.1;",
        "interval": 1800,
        "description": "Free RAM is under 10%."
        }
    },

    "packs": {
        "osquery-monitoring": "/usr/share/osquery/packs/osquery-monitoring.conf",
        "incident-response": "/usr/share/osquery/packs/incident-response.conf",
        "it-compliance": "/usr/share/osquery/packs/it-compliance.conf",
        "vuln-management": "/usr/share/osquery/packs/vuln-management.conf",
        "hardware-monitoring": "/usr/share/osquery/packs/hardware-monitoring.conf",
        "ossec-rootkit": "/usr/share/osquery/packs/ossec-rootkit.conf"
    }
}
EOF

# Adding Wazuh repository
if [[ ${EnvironmentType} == 'staging' ]]
then
echo 'stag' >> /tmp/stage

	# Adding Wazuh pre_release repository
	echo -e '[wazuh_pre_release]\ngpgcheck=1\ngpgkey=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/key/GPG-KEY-WAZUH\nenabled=1\nname=EL-$releasever - Wazuh\nbaseurl=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/pre-release/yum/\nprotect=1' | tee /etc/yum.repos.d/wazuh_pre.repo
elif [[ ${EnvironmentType} == 'production' ]]
then
echo 'prod' >> /tmp/stage
cat > /etc/yum.repos.d/wazuh.repo <<\EOF
[wazuh_repo]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh repository
baseurl=https://packages.wazuh.com/3.x/yum/
protect=1
EOF
elif [[ ${EnvironmentType} == 'devel' ]]
then
	echo 'devel' >> /tmp/stage
	echo -e '[wazuh_staging]\ngpgcheck=1\ngpgkey=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/key/GPG-KEY-WAZUH\nenabled=1\nname=EL-$releasever - Wazuh\nbaseurl=https://s3-us-west-1.amazonaws.com/packages-dev.wazuh.com/staging/yum/\nprotect=1' | tee /etc/yum.repos.d/wazuh_staging.repo
elif [[ ${EnvironmentType} == 'sources' ]]
then

  # Compile Wazuh manager from sources
  BRANCH="$branch"

  yum install make gcc policycoreutils-python automake autoconf libtool -y
  curl -Ls https://github.com/wazuh/wazuh/archive/$BRANCH.tar.gz | tar zx
  rm -f $BRANCH.tar.gz
  cd wazuh-$BRANCH/src
  make TARGET=agent DEBUG=1 -j8
  USER_LANGUAGE="en" \
  USER_NO_STOP="y" \
  USER_INSTALL_TYPE="agent" \
  USER_DIR="/var/ossec" \
  USER_ENABLE_ACTIVE_RESPONSE="y" \
  USER_ENABLE_SYSCHECK="y" \
  USER_ENABLE_ROOTCHECK="y" \
  USER_ENABLE_OPENSCAP="n" \
  USER_AGENT_SERVER_IP="${master_ip}" \
  USER_CA_STORE="/var/ossec/wpk_root.pem" \
  USER_ENABLE_SCA="y" \
  THREADS=2 \
  ../install.sh
  echo "Compiled wazuh" >> /tmp/deploy.log

else
	echo 'no repo' >> /tmp/stage
fi
# Installing wazuh-manager
yum -y install wazuh-agent-$wazuh_version
echo "Installed Wazuh agent." >> /tmp/log

# Change manager protocol to tcp, to be used by Amazon ELB
sed -i "s/<protocol>udp<\/protocol>/<protocol>tcp<\/protocol>/" ${manager_config}

# Set manager port for agent communications
sed -i "s/<port>1514<\/port>/<port>${wazuh_server_port}<\/port>/" ${manager_config}

# Setting password for agents registration
echo "${wazuh_registration_password}" > /var/ossec/etc/authd.pass
echo "Set Wazuh password registration." >> /tmp/log
echo 'logcollector.remote_commands=1' >>  /var/ossec/etc/local_internal_options.conf
# Register agent using authd
until `cat /var/ossec/logs/ossec.log | grep -q "Valid key created. Finished."`
do
  /var/ossec/bin/agent-auth -m ${master_ip} -A ${agent_name}
  sleep 1
done
sed -i 's:MANAGER_IP:'${elb_wazuh_dns}':g' ${manager_config}
echo "Registered Wazuh agent." >> /tmp/log

# Enable integrator
/var/ossec/bin/wazuh-control enable integrator

# Installing pip docker dependency
pip install docker

# Restarting services
systemctl restart wazuh-agent
systemctl restart suricata

echo "Restarted Wazuh agent." >> /tmp/log

# give time to execute Docker actions
sleep 300

# Executing docker commands
docker pull nginx
docker run -d -P --name nginx_container nginx
docker exec -ti nginx_container cat /etc/passwd
docker stop nginx_container
docker rm nginx_container
