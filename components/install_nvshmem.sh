#!/bin/bash
# Installed on NVIDIA NVLink rack-scale SKUs.
set -ex

source ${UTILS_DIR}/utilities.sh

cuda_metadata=$(get_component_config "cuda")
CUDA_DRIVER_VERSION=$(jq -r '.driver.version' <<< $cuda_metadata)
CUDA_MAJOR_VERSION=$(echo $CUDA_DRIVER_VERSION | cut -d. -f1)

if [[ "$DISTRIBUTION" == "ubuntu26.04" &&
      "$SKU" == "VR200" &&
      "${TARGET_NODE_TYPE:-azure_vm_regular}" == azure_vm_* ]]; then
    nvshmem_metadata=$(get_component_config "nvshmem")
    NVSHMEM_VERSION=$(jq -r '.version' <<< "$nvshmem_metadata")
    NVSHMEM_ARCHIVE_FILE="libnvshmem_cuda${CUDA_MAJOR_VERSION}-linux-sbsa-${NVSHMEM_VERSION}.tar.gz"
    NVSHMEM_ROOT=/opt/nvidia/nvshmem/$NVSHMEM_VERSION

    rm -rf "$NVSHMEM_ROOT"
    install -d -m 0755 "$NVSHMEM_ROOT"
    tar -xzf "$TOP_DIR/internal_bits/$NVSHMEM_ARCHIVE_FILE" \
        --strip-components=1 \
        -C "$NVSHMEM_ROOT"

    cat > /etc/profile.d/nvshmem.sh <<EOF
export NVSHMEM_HOME=$NVSHMEM_ROOT
export PATH="\${NVSHMEM_HOME}/bin\${PATH:+:\${PATH}}"
export LD_LIBRARY_PATH="\${NVSHMEM_HOME}/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
EOF
    write_component_version "NVSHMEM" "$NVSHMEM_VERSION"
elif [[ $DISTRIBUTION == "azurelinux3.0" ]]; then
    NVSHMEM_CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/rhel9/sbsa"
    dnf install -y --nogpgcheck \
        --repofrompath=cuda-rhel9-sbsa,$NVSHMEM_CUDA_REPO \
        libnvshmem3-cuda-$CUDA_MAJOR_VERSION libnvshmem3-devel-cuda-$CUDA_MAJOR_VERSION libnvshmem3-static-cuda-$CUDA_MAJOR_VERSION
    nvshmem_version=$(dnf list installed | grep libnvshmem3-cuda-$CUDA_MAJOR_VERSION | awk '{print $2}')
elif [[ $DISTRIBUTION == *"ubuntu"* ]]; then
    apt install libnvshmem3-cuda-$CUDA_MAJOR_VERSION libnvshmem3-dev-cuda-$CUDA_MAJOR_VERSION
    nvshmem_version=$(apt list --installed | grep libnvshmem3-cuda-$CUDA_MAJOR_VERSION/ | cut -d' ' -f2)
fi

if [[ -n "${nvshmem_version:-}" ]]; then
    write_component_version "NVSHMEM" "$nvshmem_version"
fi
