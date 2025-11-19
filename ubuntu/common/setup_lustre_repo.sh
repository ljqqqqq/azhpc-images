#!/bin/bash
set -ex

source /etc/lsb-release
UBUNTU_VERSION=$(cat /etc/os-release | grep VERSION_ID | cut -d= -f2 | cut -d\" -f2)
if [ $UBUNTU_VERSION == 24.04 ]; then
    SIGNED_BY="/usr/share/keyrings/microsoft-prod.gpg"
elif [ $UBUNTU_VERSION == 22.04 ]; then
    SIGNED_BY="/etc/apt/trusted.gpg.d/microsoft-prod.gpg"
fi

if [[ "$ARCH" == "aarch64" ]]; then
    echo "deb [arch=arm64 signed-by=$SIGNED_BY] https://packages.microsoft.com/repos/amlfs-${DISTRIB_CODENAME}/ ${DISTRIB_CODENAME} main" | tee /etc/apt/sources.list.d/amlfs.list
else
    echo "deb [arch=amd64 signed-by=$SIGNED_BY] https://packages.microsoft.com/repos/amlfs-${DISTRIB_CODENAME}/ ${DISTRIB_CODENAME} main" | tee /etc/apt/sources.list.d/amlfs.list
fi
    curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null

