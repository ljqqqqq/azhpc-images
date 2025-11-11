#!/bin/bash
set -ex

source ${COMMON_DIR}/utilities.sh


doca_metadata=$(get_component_config "doca")
DOCA_VERSION=$(jq -r '.version' <<< $doca_metadata)
DOCA_SHA256=$(jq -r '.sha256' <<< $doca_metadata)
DOCA_URL=$(jq -r '.url' <<< $doca_metadata)
DOCA_FILE=$(basename ${DOCA_URL})

if [[ "$SKU" == "GB200" ]]; then
    dpkg -i $TOP_DIR/internal_bits/doca-host_${DOCA_VERSION}_arm64.deb
else
    $COMMON_DIR/download_and_verify.sh $DOCA_URL $DOCA_SHA256
    dpkg -i $DOCA_FILE
fi


apt-get update

if [[ "$ARCH" == "aarch64" ]]; then
    # Unset ARCH set by set_properties.sh. 
    # ARCH == uname -m (aarch64)
    # messes up some doca-ofed package post install scripts,
    # since kernel source dir only has arch/arm64
    unset ARCH
fi

apt-get -y install doca-ofed
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
