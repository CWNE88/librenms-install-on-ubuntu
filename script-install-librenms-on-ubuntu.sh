#!/bin/bash

# Exit on any error
set -e
echo
echo "#################################"
echo "Starting LibreNMS installation..."
echo "#################################"
echo

read -sp "Enter MySQL database password for librenms user: " DATABASEPASSWORD
echo

read -p "Enter web server hostname: " WEBSERVERHOSTNAME

echo
echo "############################"
echo "Installing required packages"
echo "############################" 
echo

apt update
apt install -y acl curl fping git graphviz imagemagick mariadb-client mariadb-server mtr-tiny nginx-full nmap php-cli php-curl php-fpm php-gd php-gmp php-json php-mbstring php-mysql php-snmp php-xml php-zip rrdtool snmp snmpd unzip python3-command-runner python3-pymysql python3-dotenv python3-redis python3-setuptools python3-psutil python3-systemd python3-pip whois traceroute iputils-ping tcpdump vim cron

echo
echo "######################"
echo "Creating librenms user"
echo "######################"
echo

useradd librenms -d /opt/librenms -M -r -s "$(which bash)"

echo "###########################"
echo "Cloning LibreNMS repository"
echo "###########################"
echo

cd /opt
git clone https://github.com/librenms/librenms.git

echo
echo "############################################"
echo "Setting permissions for LibreNMS directories"
echo "############################################"
echo 

chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/

echo "################################"
echo "Installing Composer dependencies"
echo "################################"
echo

su - librenms -c "/opt/librenms/scripts/composer_wrapper.php install --no-dev"

echo
echo "########################"
echo "Configuring PHP timezone"
echo "########################"

sed -i 's/;date.timezone =/date.timezone = Australia\/Brisbane/' /etc/php/8.3/fpm/php.ini
sed -i 's/;date.timezone =/date.timezone = Australia\/Brisbane/' /etc/php/8.3/cli/php.ini

echo
echo "#############################################"
echo "Setting system timezone to Australia/Brisbane"
echo "#############################################"
echo
timedatectl set-timezone Australia/Brisbane

echo "############################"
echo "Configuring MariaDB settings"
echo "############################"
echo

sed -i '/\[mysqld\]/a \
innodb_file_per_table=1 \
lower_case_table_names=0' /etc/mysql/mariadb.conf.d/50-server.cnf

echo "###############################"
echo "Enabling and restarting MariaDB"
echo "###############################"
echo

systemctl enable mariadb
systemctl restart mariadb

echo
echo "###################################"
echo "Creating LibreNMS database and user"
echo "###################################"


mysql -u root <<EOF
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'librenms'@'localhost' IDENTIFIED BY '$DATABASEPASSWORD';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
EOF


echo
echo "#####################################"
echo "Configuring PHP-FPM pool for LibreNMS"
echo "#####################################"

cp /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's/user = www-data/user = librenms/' /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's/group = www-data/group = librenms/' /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's/\[www\]/\[librenms\]/' /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's|listen = /run/php/php8.3-fpm.sock|listen = /run/php-fpm-librenms.sock|' /etc/php/8.3/fpm/pool.d/librenms.conf



echo
echo "##############################"
echo "Configuring Nginx for LibreNMS"
echo "##############################"

cat << EOF > /etc/nginx/conf.d/librenms.conf
server {
 listen      80;
 server_name $WEBSERVERHOSTNAME;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
 location / {
  try_files \$uri \$uri/ /index.php?\$query_string;
 }
 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOF



echo
echo "####################################"
echo "Removing default Nginx configuration"
echo "####################################"

rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

echo
echo "Restarting Nginx and PHP-FPM..."
echo
systemctl restart nginx
systemctl restart php8.3-fpm

echo "#######################"
echo "Setting up lnms command"
echo "#######################"
echo

ln -s /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

echo "################"
echo "Configuring SNMP"
echo "################"

cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i 's/RANDOMSTRINGGOESHERE/public/' /etc/snmp/snmpd.conf
curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable snmpd
systemctl restart snmpd


cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms

echo
echo "#############################"
echo "Setting up LibreNMS scheduler"
echo "#############################"
echo

cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

echo
echo "##################################"
echo "Configuring logrotate for LibreNMS"
echo "##################################"

cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

echo

echo "####################################"
echo "Installing and configuring syslog-ng"
echo "####################################"
echo
apt-get install -y syslog-ng-core
cat << 'EOF' > /etc/syslog-ng/conf.d/librenms.conf
source s_net {
        tcp(port(514) flags(syslog-protocol));
        udp(port(514) flags(syslog-protocol));
};

destination d_librenms {
        program("/opt/librenms/syslog.php" template ("$HOST||$FACILITY||$PRIORITY||$LEVEL||$TAG||$R_YEAR-$R_MONTH-$R_DAY $R_HOUR:$R_MIN:$R_SEC||$MSG||$PROGRAM\n") template-escape(yes));
};

log {
        source(s_net);
        source(s_src);
        destination(d_librenms);
};
EOF


chown librenms:librenms /opt/librenms/syslog.php
chmod +x /opt/librenms/syslog.php

echo "Restarting syslog-ng..."
systemctl restart syslog-ng

echo
echo "#######################"
echo "Fixing up the .env file"
echo "#######################"

sed -i "s/#DB_HOST=/DB_HOST=localhost/" /opt/librenms/.env
sed -i "s/#DB_DATABASE=/DB_DATABASE=librenms/" /opt/librenms/.env
sed -i "s/#DB_USERNAME=/DB_USERNAME=librenms/" /opt/librenms/.env
sed -i "s/#DB_PASSWORD=/DB_PASSWORD=$DATABASEPASSWORD/" /opt/librenms/.env


echo
echo "#####################"
echo "Fixing log permission"
echo "#####################"
echo

while true; do
  if [ -f /opt/librenms/logs/librenms.log ]; then
    chown librenms:librenms /opt/librenms/logs/librenms.log
    break
  else
    echo "Waiting until log file appears to change permission..."
    sleep 1
  fi
done



echo
echo "LibreNMS installation and configuration complete"
echo "...almost"
echo
echo "#####################################" 
echo "DON'T FORGET TO COME BACK AND DO THIS"
echo "#####################################"
echo
echo "Go and do the web page setup..."
echo "...and then come back and do:"
echo
echo 'su librenms -c "lnms config:set enable_syslog true"'
echo
echo "Then it will be finished."
echo 
echo "Wait until a device has been polled, and then do:"
echo
echo "su librenms -c /opt/librenms/validate.php"





exit 0
