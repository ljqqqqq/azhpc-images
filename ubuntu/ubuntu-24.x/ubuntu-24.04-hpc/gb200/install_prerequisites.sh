#!/bin/bash
############################################################################
# @Brief   : Installs prerequisites for the HPC AI VM image.
# @Details : This script installs the necessary packages and dependencies
#            required for the HPC AI VM image.
# @Usage   : Run this script in the VM to install the prerequisites.
# @Args    : None
############################################################################
set -ex

# Don't allow the kernel to be updated
apt-mark hold linux-azure-nvidia

# upgrade pre-installed components
apt update
apt upgrade -y
