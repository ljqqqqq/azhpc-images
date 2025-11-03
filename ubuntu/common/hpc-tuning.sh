#!/bin/bash
set -ex

SKU=$1
# Install Dependencies
if [[ $DISTRIBUTION == "ubuntu24.04" ]]; then
    apt install python3-netifaces -y
else
    pip3 install -U netifaces
    pip3 install -U PyYAML
fi


# Disable some unneeded services by default (administrators can re-enable if desired)
systemctl disable ufw

if [[ "$SKU" == "GB200" ]]; then 
    echo "net.core.rmem_max = 2147483647" >> /etc/sysctl.conf
    echo "net.core.wmem_max = 2147483647" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_rmem = 4096 67108864 1073741824" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_wmem = 4096 67108864 1073741824" >> /etc/sysctl.conf

    echo "NUMAPolicy=bind" | tee -a /etc/systemd/system.conf
    echo "NUMAMask=0-1" | tee -a /etc/systemd/system.conf
fi

$COMMON_DIR/hpc-tuning.sh

# Azure Linux Agent
$UBUNTU_COMMON_DIR/install_waagent.sh