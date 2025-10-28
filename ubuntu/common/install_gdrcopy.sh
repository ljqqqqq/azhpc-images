#!/bin/bash
set -ex

source ${COMMON_DIR}/utilities.sh

# Install gdrcopy
apt install -y build-essential devscripts debhelper check libsubunit-dev fakeroot pkg-config dkms

gdrcopy_metadata=$(get_component_config "gdrcopy")
GDRCOPY_VERSION=$(jq -r '.version' <<< $gdrcopy_metadata)
GDRCOPY_COMMIT=$(jq -r '.commit' <<< $gdrcopy_metadata)
GDRCOPY_DISTRIBUTION=$(jq -r '.distribution' <<< $gdrcopy_metadata)

cuda_metadata=$(get_component_config "cuda")
CUDA_DRIVER_VERSION=$(jq -r '.driver.version' <<< $cuda_metadata)


wget https://developer.download.nvidia.com/compute/redist/gdrcopy/CUDA%20${CUDA_DRIVER_VERSION}/${GDRCOPY_DISTRIBUTION}/${ARCH}/gdrdrv-dkms_${GDRCOPY_VERSION}-1_arm64.${GDRCOPY_DISTRIBUTION}.deb
dpkg -i gdrdrv-dkms_${GDRCOPY_VERSION}-1_arm64.${GDRCOPY_DISTRIBUTION}.deb

$COMMON_DIR/write_component_version.sh "GDRCOPY" ${GDRCOPY_VERSION}