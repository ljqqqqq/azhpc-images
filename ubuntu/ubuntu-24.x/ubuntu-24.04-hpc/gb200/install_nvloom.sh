#!/bin/bash

set -ex
source ${COMMON_DIR}/utilities.sh

dest_dir=/opt/nvidia/nvloom
mkdir -p $dest_dir

NVLOOM_DOWNLOAD_URL="https://github.com/NVIDIA/nvloom.git"
NVLOOM_VERSION="1.2.0"

source /etc/profile.d/modules.sh
module load mpi/hpcx

git clone $NVLOOM_DOWNLOAD_URL --branch v$NVLOOM_VERSION
pushd nvloom
cmake . && make -j $(nproc)
mv nvloom_cli $dest_dir
popd

module unload mpi/hpcx

rm -rf ./nvloom

$COMMON_DIR/write_component_version.sh "NVLOOM" ${NVLOOM_VERSION}