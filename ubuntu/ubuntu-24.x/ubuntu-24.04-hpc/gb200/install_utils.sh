#!/bin/bash
############################################################################
# @Brief   : Installs Microsoft packages repository for Ubuntu 24.04.
# @Details : This script sets up the Microsoft packages repository for Ubuntu
#            24.04 and updates the package list.
# @Usage   : Run this script in the VM to install the Microsoft packages repository.
# @Args    : None
############################################################################
set -ex

# Setup microsoft packages repository
curl -sSL -O https://packages.microsoft.com/config/$(. /etc/os-release;echo $ID/$VERSION_ID)/packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
apt-get update

sed -i 's|^#precedence ::ffff:0:0/96  100|precedence ::ffff:0:0/96  100|' /etc/gai.conf

# Remove the downloaded package
rm -rf packages-microsoft-prod.deb

$UBUNTU_COMMON_DIR/install_utils.sh
