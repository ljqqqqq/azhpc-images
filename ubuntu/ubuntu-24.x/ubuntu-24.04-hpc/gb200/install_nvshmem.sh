set -ex

apt install libnvshmem3-cuda-13 libnvshmem3-dev-cuda-13
nvshmem_version=$(apt list --installed | grep libnvshmem3-cuda-13   / | cut -d' ' -f2)

$COMMON_DIR/write_component_version.sh "NVSHMEM" $nvshmem_version