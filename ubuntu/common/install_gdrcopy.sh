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

git clone https://github.com/NVIDIA/gdrcopy.git
pushd gdrcopy/packages/
git checkout ${GDRCOPY_COMMIT}

CUDA=/usr/local/cuda ./build-deb-packages.sh
if [ "$ARCH" == "x86_64" ]; then
    dpkg -i gdrdrv-dkms_${GDRCOPY_VERSION}_amd64.${GDRCOPY_DISTRIBUTION}.deb
    dpkg -i libgdrapi_${GDRCOPY_VERSION}_amd64.${GDRCOPY_DISTRIBUTION}.deb
    dpkg -i gdrcopy-tests_${GDRCOPY_VERSION}_amd64.${GDRCOPY_DISTRIBUTION}+cuda${CUDA_DRIVER_VERSION}.deb
    dpkg -i gdrcopy_${GDRCOPY_VERSION}_amd64.${GDRCOPY_DISTRIBUTION}.deb
else
    dpkg -i gdrdrv-dkms_${GDRCOPY_VERSION}_arm64.${GDRCOPY_DISTRIBUTION}.deb
    dpkg -i libgdrapi_${GDRCOPY_VERSION}_arm64.${GDRCOPY_DISTRIBUTION}.deb
    dpkg -i gdrcopy-tests_${GDRCOPY_VERSION}_arm64.${GDRCOPY_DISTRIBUTION}+cuda${CUDA_DRIVER_VERSION}.deb
    dpkg -i gdrcopy_${GDRCOPY_VERSION}_arm64.${GDRCOPY_DISTRIBUTION}.deb
fi
apt-mark hold gdrdrv-dkms
apt-mark hold libgdrapi
apt-mark hold gdrcopy-tests
apt-mark hold gdrcopy
popd

$COMMON_DIR/write_component_version.sh "GDRCOPY" ${GDRCOPY_VERSION}