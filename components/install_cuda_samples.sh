#!/bin/bash
set -ex

source ${UTILS_DIR}/utilities.sh

# Read CUDA config from versions.json
cuda_metadata=$(get_component_config "cuda")
CUDA_DRIVER_VERSION=$(jq -r '.driver.version' <<< $cuda_metadata)
CUDA_SAMPLES_VERSION=$(jq -r '.samples.version' <<< $cuda_metadata)
CUDA_SAMPLES_SHA256=$(jq -r '.samples.sha256' <<< $cuda_metadata)

# Download and build CUDA samples
TARBALL="v${CUDA_SAMPLES_VERSION}.tar.gz"
CUDA_SAMPLES_DOWNLOAD_URL=https://github.com/NVIDIA/cuda-samples/archive/refs/tags/${TARBALL}
download_and_verify ${CUDA_SAMPLES_DOWNLOAD_URL} ${CUDA_SAMPLES_SHA256}
tar -xvf ${TARBALL}
pushd ./cuda-samples-${CUDA_SAMPLES_VERSION}
mkdir build && cd build
cmake -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc ..
make -j $(nproc)

# NVIDIA renamed the top-level Samples directory to cpp in the CUDA 13.2
# update; the change is present in the v13.3 tag, while v13.2 still uses Samples.
if [[ "$(printf '%s\n' "${CUDA_SAMPLES_VERSION}" "13.3" | sort -V | head -n1)" == "13.3" ]]; then
	CUDA_SAMPLES_BUILD_DIR=./cpp
else
	CUDA_SAMPLES_BUILD_DIR=./Samples
fi
if [[ ! -d "${CUDA_SAMPLES_BUILD_DIR}" ]]; then
	echo "Unable to locate CUDA samples ${CUDA_SAMPLES_VERSION} build output at ${CUDA_SAMPLES_BUILD_DIR}" >&2
	exit 1
fi
mv -vT "${CUDA_SAMPLES_BUILD_DIR}" "/usr/local/cuda-${CUDA_DRIVER_VERSION}/samples"
popd
