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

$COMMON_DIR/hpc-tuning.sh

# Azure Linux Agent
$UBUNTU_COMMON_DIR/install_waagent.sh

if [[ "$SKU" == "GB200" ]]; then
    echo "NUMAPolicy=bindNUMAMask=0-1" | tee -a /etc/systemd/system.conf
fi