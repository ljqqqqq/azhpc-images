set -ex

apt install libnvshmem3-cuda-12 libnvshmem3-dev-cuda-12
nvshmem_version=$(apt list --installed | grep libnvshmem3-cuda-12/ | cut -d' ' -f2)

$COMMON_DIR/write_component_version.sh "NVSHMEM" $nvshmem_version