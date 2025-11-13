#!/bin/bash
############################################################################
# @Brief   : Installs the necessary components for an HPC VM image on Ubuntu 24.04.
# @Details : This script installs various components such as NVIDIA drivers,
#            DOCA OFED, PMIX, MPI libraries, and more, depending on the GPU type.
# @Usage   : Run this script in the VM to install the necessary components.
# @Args    : Optional argument to specify the GPU type ('NVIDIA' or 'AMD').
############################################################################
set -ex

# Check if arguments are passed
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Error: Missing arguments. Please provide both GPU type (NVIDIA/AMD) and SKU."
    exit 1
fi

export GPU=$1
export SKU=$2

if [[ "$#" -gt 0 ]]; then
   if [[ "$GPU" != "NVIDIA" && "$GPU" != "AMD" ]]; then
       echo "Error: Invalid GPU type. Please specify 'NVIDIA' or 'AMD'."
       exit 1
    fi
fi


# jq is needed to parse the component versions from the versions.json file
apt install -y jq

# set properties
source ./set_properties.sh
export DISTRIBUTION=$DISTRIBUTION-aks

# install utils
./install_utils.sh

# install DOCA OFED
$UBUNTU_COMMON_DIR/install_doca.sh


if [ "$GPU" = "NVIDIA" ]; then
    # install nvidia gpu driver
    ./install_nvidiagpudriver.sh
fi

if [ "$GPU" = "AMD" ]; then
    # Set up docker
    apt-get install -y moby-engine
    systemctl enable docker
    systemctl restart docker
fi

# cleanup downloaded tarballs - clear some space
rm -rf *.tgz *.bz2 *.tbz *.tar.gz *.run *.deb *_offline.sh
rm -rf /tmp/MLNX_OFED_LINUX* /tmp/*conf*
rm -rf /var/intel/ /var/cache/*
rm -Rf -- */


$UBUNTU_COMMON_DIR/install_waagent.sh

# Install AZNFS Mount Helper
# $COMMON_DIR/install_aznfs.sh

# copy test file
$COMMON_DIR/copy_test_file.sh

# SKU Customization
$COMMON_DIR/setup_sku_customizations.sh

if [ "$GPU" = "AMD" ]; then
    #install rocm software stack
    ./install_rocm.sh
    
    #install rccl and rccl-tests
    ./install_rccl.sh
fi

# scan vulnerabilities using Trivy
$COMMON_DIR/trivy_scan.sh
