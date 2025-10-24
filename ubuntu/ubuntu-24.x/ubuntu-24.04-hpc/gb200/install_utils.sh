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

# Remove the downloaded package
rm -rf packages-microsoft-prod.deb

apt-get -y install build-essential
apt-get -y install net-tools \
                   infiniband-diags \
                   dkms \
                   jq 
