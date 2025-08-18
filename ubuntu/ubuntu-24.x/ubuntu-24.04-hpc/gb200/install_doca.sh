#!/bin/bash

set -x

source ${COMMON_DIR}/utilities.sh
DOCA_METADATA=$(get_component_config "doca")
DOCA_VERSION=$(jq -r '.version' <<< $DOCA_METADATA)
DOCA_SHA256=$(jq -r '.sha256' <<< $DOCA_METADATA)
DOCA_URL=$(jq -r '.url' <<< $DOCA_METADATA)
DOCA_FILE=$(basename ${DOCA_URL})

# azcopy copy $DOCA_URL /tmp/
$COMMON_DIR/download_and_verify.sh $DOCA_URL $DOCA_SHA256

# pushd /tmp/
sudo dpkg -i $DOCA_FILE
# popd
apt-get update

if ! apt-get -y install doca-ofed; then
    apt-get -f -y install
    systemctl restart dkms
    dkms autoinstall
    if ! apt-get -y install doca-ofed; then
        echo "Failed to install doca-ofed after retry."
        exit 1
    fi
fi
$COMMON_DIR/write_component_version.sh "DOCA" $DOCA_VERSION

OFED_VERSION=$(ofed_info | sed -n '1,1p' | awk -F'-' 'OFS="-" {print $3,$4}' | tr -d ':')
$COMMON_DIR/write_component_version.sh "OFED" $OFED_VERSION

/etc/init.d/openibd restart
/etc/init.d/openibd status
error_code=$?
if [ ${error_code} -ne 0 ]
then
    echo "OpenIBD not loaded correctly!"
    exit ${error_code}
fi

# Uninstall doca ofed source package and repository
rm -rf $DOCA_FILE
rm -rf /etc/apt/sources.list.d/doca.list
