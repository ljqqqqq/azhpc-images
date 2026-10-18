#!/bin/bash
set -ex

source ${UTILS_DIR}/utilities.sh

dest_dir=/opt/nvidia/nvbandwidth
mkdir -p $dest_dir

nvbandwidth_metadata=$(get_component_config "nvbandwidth")
NVBANDWIDTH_VERSION=$(jq -r '.version' <<< $nvbandwidth_metadata)
NVBANDWIDTH_DOWNLOAD_URL=$(jq -r '.url' <<< $nvbandwidth_metadata)
NVBANDWIDTH_SOURCE=$(jq -r '.source // "public"' <<< $nvbandwidth_metadata)
NVBANDWIDTH_COMMIT=$(jq -r '.commit // empty' <<< $nvbandwidth_metadata)
NVBANDWIDTH_REF=$(jq -r '.ref // .branch // empty' <<< $nvbandwidth_metadata)
NVBANDWIDTH_REF=${NVBANDWIDTH_REF:-v${NVBANDWIDTH_VERSION}}

if [[ "$NVBANDWIDTH_SOURCE" != "private" ]]; then
    # Install source-build dependencies.
    if [[ $DISTRIBUTION == *"ubuntu"* ]]; then
        apt install -y libboost-program-options-dev
    elif [[ $DISTRIBUTION == almalinux* ]]; then
        dnf -y install boost-devel
    elif [[ $DISTRIBUTION == "azurelinux3.0" && $ARCHITECTURE != "aarch64" ]]; then
        dnf -y install boost-devel
    elif [[ $DISTRIBUTION == "azurelinux3.0" && $ARCHITECTURE == "aarch64" ]]; then
        dnf install -y boost-devel boost-program-options
        dnf install -y cmake
    fi
fi

if [[ "$NVBANDWIDTH_SOURCE" == "private" ]]; then
    NVBANDWIDTH_BINARY_FILE=$(jq -r '.binary_file' <<< $nvbandwidth_metadata)
    NVBANDWIDTH_BINARY_SHA256=$(jq -r '.sha256' <<< $nvbandwidth_metadata)
    verify_checksum "$TOP_DIR/internal_bits/$NVBANDWIDTH_BINARY_FILE" "$NVBANDWIDTH_BINARY_SHA256"
    install -m 0755 \
        "$TOP_DIR/internal_bits/$NVBANDWIDTH_BINARY_FILE" \
        "$dest_dir/$NVBANDWIDTH_BINARY_FILE"
    ln -sfn "$dest_dir/$NVBANDWIDTH_BINARY_FILE" "$dest_dir/nvbandwidth"
else
    git clone --branch ${NVBANDWIDTH_REF} ${NVBANDWIDTH_DOWNLOAD_URL}

    # Build and install the nvbandwidth tool.
    pushd nvbandwidth
    git checkout ${NVBANDWIDTH_COMMIT}
    write_repo_source_info "NVBANDWIDTH" . "${NVBANDWIDTH_COMMIT}" "${NVBANDWIDTH_REF}"
    source /etc/profile.d/modules.sh
    module load mpi/hpcx
    cmake -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DMULTINODE=1 .
    make
    mv ./nvbandwidth $dest_dir
    popd

    rm -rf ./nvbandwidth
fi
write_component_version "NVBANDWIDTH" ${NVBANDWIDTH_VERSION}
