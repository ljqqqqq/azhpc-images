#!/bin/bash
set -ex

source ${UTILS_DIR}/utilities.sh

# Set NCCL versions
nccl_metadata=$(get_component_config "nccl")
NCCL_VERSION=$(jq -r '.version' <<< $nccl_metadata)
NCCL_RDMA_SHARP_COMMIT=$(jq -r '.rdmasharpplugins.commit' <<< $nccl_metadata)
NCCL_SOURCE=$(jq -r '.source // "public"' <<< $nccl_metadata)

cuda_metadata=$(get_component_config "cuda")
CUDA_DRIVER_VERSION=$(jq -r '.driver.version' <<< $cuda_metadata)

TARBALL="v${NCCL_VERSION}.tar.gz"
NCCL_DOWNLOAD_URL=https://github.com/NVIDIA/nccl/archive/refs/tags/${TARBALL}

# Install NCCL
if [[ $DISTRIBUTION == "ubuntu26.04" ]]; then
    apt install -y build-essential patchelf zlib1g-dev
elif [[ $DISTRIBUTION == *"ubuntu"* ]]; then
    apt install -y build-essential devscripts debhelper fakeroot patchelf
    # Comment the installation of libibverbs-dev to avoid conflicts on builds for bare metal 1P nodes
    # For VM it has been installed via the install_utils.sh or install_doca.sh
    apt install -y zlib1g-dev # libibverbs-dev
elif [[ $DISTRIBUTION == "azurelinux3.0" ]]; then
    dnf install -y rpm-build rpmdevtools autoconf automake git libtool patchelf
else
    # RHEL-family: AlmaLinux, Rocky Linux, RHEL, etc.
    dnf install -y rpm-build rpmdevtools patchelf
fi

pushd /tmp
if [[ $DISTRIBUTION == "ubuntu26.04" ]]; then
    if [[ "$NCCL_SOURCE" == "private" ]]; then
        NCCL_RUNTIME_FILE="libnccl2_${NCCL_VERSION}_${ARCHITECTURE_DISTRO}.deb"
        NCCL_DEV_FILE="libnccl-dev_${NCCL_VERSION}_${ARCHITECTURE_DISTRO}.deb"
        apt install -y \
            "$TOP_DIR/internal_bits/$NCCL_RUNTIME_FILE" \
            "$TOP_DIR/internal_bits/$NCCL_DEV_FILE"
    else
        apt-get install -y libnccl2 libnccl-dev
    fi
    apt-mark hold libnccl2
    apt-mark hold libnccl-dev
else
    wget ${NCCL_DOWNLOAD_URL}
    tar -xvf ${TARBALL}

    pushd nccl-${NCCL_VERSION}
    make -j $(( $(nproc) - 1 )) src.build
    if [[ $DISTRIBUTION == *"ubuntu"* ]]; then
        make pkg.debian.build
        pushd build/pkg/deb/
        apt install -y ./libnccl2_${NCCL_VERSION}+cuda${CUDA_DRIVER_VERSION}_${ARCHITECTURE_DISTRO}.deb
        apt-mark hold libnccl2
        apt install -y ./libnccl-dev_${NCCL_VERSION}+cuda${CUDA_DRIVER_VERSION}_${ARCHITECTURE_DISTRO}.deb
        apt-mark hold libnccl-dev
        popd
    elif [[ $DISTRIBUTION == "azurelinux3.0" ]]; then
        make pkg.redhat.build
        if [ "$ARCHITECTURE" = "aarch64" ]; then
            dnf install -y ./build/pkg/rpm/aarch64/libnccl-${NCCL_VERSION}+cuda*.aarch64.rpm
            dnf install -y ./build/pkg/rpm/aarch64/libnccl-devel-${NCCL_VERSION}+cuda*.aarch64.rpm
            dnf install -y ./build/pkg/rpm/aarch64/libnccl-static-${NCCL_VERSION}+cuda*.aarch64.rpm
        else
            dnf install -y ./build/pkg/rpm/x86_64/libnccl-${NCCL_VERSION}+cuda*.x86_64.rpm
            dnf install -y ./build/pkg/rpm/x86_64/libnccl-devel-${NCCL_VERSION}+cuda*.x86_64.rpm
            dnf install -y ./build/pkg/rpm/x86_64/libnccl-static-${NCCL_VERSION}+cuda*.x86_64.rpm
        fi

        dnf_pin_packages "libnccl*"
    else
        # RHEL-family: AlmaLinux, Rocky Linux, RHEL, etc.
        make pkg.redhat.build
        rpm -i ./build/pkg/rpm/x86_64/libnccl-${NCCL_VERSION}+cuda${CUDA_DRIVER_VERSION}.x86_64.rpm
        rpm -i ./build/pkg/rpm/x86_64/libnccl-devel-${NCCL_VERSION}+cuda${CUDA_DRIVER_VERSION}.x86_64.rpm
        rpm -i ./build/pkg/rpm/x86_64/libnccl-static-${NCCL_VERSION}+cuda${CUDA_DRIVER_VERSION}.x86_64.rpm
        dnf_pin_packages "libnccl*"
    fi
    popd
fi

# Install the nccl rdma sharp plugin. Skip for non-IB SKUs (no DOCA-OFED, no SHARP, no GPUDirect RDMA)
if [[ "$(sku_network_mode)" == "standard_ib" ]]; then
    source /etc/profile.d/modules.sh
    module load mpi/hpcx

    if [[ -z "${HPCX_SHARP_DIR:-}" || ! -d "${HPCX_SHARP_DIR}" ]]; then
        echo "HPC-X module did not provide a valid HPCX_SHARP_DIR; cannot build NCCL RDMA SHARP plugin."
        exit 1
    fi
    if [[ -z "${HPCX_UCX_DIR:-}" || ! -d "${HPCX_UCX_DIR}" ]]; then
        echo "HPC-X module did not provide a valid HPCX_UCX_DIR; cannot build NCCL RDMA SHARP plugin."
        exit 1
    fi
    mkdir -p /usr/local/nccl-rdma-sharp-plugins
    git clone https://github.com/Mellanox/nccl-rdma-sharp-plugins.git
    pushd nccl-rdma-sharp-plugins
    git checkout ${NCCL_RDMA_SHARP_COMMIT}

    if [[ "$DISTRIBUTION" == "azurelinux3.0" ]]; then
        libtoolize --verbose
    fi

    ./autogen.sh
    ./configure --prefix=/usr/local/nccl-rdma-sharp-plugins --with-cuda=/usr/local/cuda
    make
    make install
    cat > /etc/ld.so.conf.d/nccl-rdma-sharp-plugins.conf <<EOF
/usr/local/nccl-rdma-sharp-plugins/lib
EOF
    ldconfig
    popd
    write_component_version "NCCL-RDMA_SHARP_PLUGIN" ${NCCL_RDMA_SHARP_COMMIT}
    module unload mpi/hpcx
fi

# Build the nccl tests
source /etc/profile.d/modules.sh
module load mpi/hpcx
git clone https://github.com/NVIDIA/nccl-tests.git
pushd nccl-tests
make MPI=1 MPI_HOME=${HPCX_MPI_DIR} CUDA_HOME=/usr/local/cuda
popd
mv nccl-tests /opt/.
module unload mpi/hpcx
popd

if [[ $DISTRIBUTION == "ubuntu26.04" ]]; then
    write_component_version "NCCL" "$(dpkg-query -W -f='${Version}' libnccl2 | sed 's/+cuda.*//')"
else
    write_component_version "NCCL" "$NCCL_VERSION"
fi

# Remove installation files
rm -rf /tmp/${TARBALL}
rm -rf /tmp/nccl-${NCCL_VERSION}
