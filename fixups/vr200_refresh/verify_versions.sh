#!/bin/bash
set -euo pipefail
: "${TOP_DIR:?Run through upgrade_ubuntu2604_vr200.sh}"
source "${UTILS_DIR}/utilities.sh"
check_package() {
    local name=$1 expected=$2 actual status
    status=$(dpkg-query -W -f='${db:Status-Status}' "$name")
    actual=$(dpkg-query -W -f='${Version}' "$name")
    [[ "$status" == installed && "$actual" == "$expected" ]] || {
        echo "ERROR: ${name}: expected installed ${expected}; found ${status} ${actual}" >&2; exit 1;
    }
    echo "${name}=${actual}"
}
check_dkms() {
    local name=$1 version=$2 status line expected
    expected="${name}/${version}, $(uname -r), $(uname -m): installed"
    status=$(dkms status -m "$name" -v "$version") || {
        echo "ERROR: could not query DKMS status for ${name}/${version}." >&2; return 1;
    }
    printf '%s\n' "$status"
    while IFS= read -r line; do
        case "$line" in
            "$expected"|"$expected (Original modules exist)") return 0 ;;
        esac
    done <<< "$status"
    echo "ERROR: expected ${expected}, optionally followed by (Original modules exist)." >&2
    return 1
}
nvidia_metadata=$(get_component_config nvidia)
cuda_metadata=$(get_component_config cuda)
doca_metadata=$(get_component_config doca)
nccl_metadata=$(get_component_config nccl)
nvbandwidth_metadata=$(get_component_config nvbandwidth)
driver_version=$(jq -r '.driver.version' <<< "$nvidia_metadata")
for name in nvidia-dkms-open nvidia-headless-open nvidia-headless-no-dkms-open \
            nvidia-kernel-common nvidia-firmware nvidia-modprobe nvidia-persistenced \
            libnvidia-compute libnvidia-cfg1 libnvidia-gpucomp libnvidia-imex1; do
    check_package "$name" "$driver_version"
done
check_package nvidia-imex-direct "$(jq -r '.imex.version' <<< "$nvidia_metadata")"
cuda_version=$(jq -r '.driver.version' <<< "$cuda_metadata")
check_package "cuda-toolkit-${cuda_version//./-}" "$(jq -r '.driver.package_version' <<< "$cuda_metadata")"
check_package doca-ofed "$(jq -r '.package_version' <<< "$doca_metadata")"
check_package libnccl2 "$(jq -r '.version' <<< "$nccl_metadata")"
check_package libnccl-dev "$(jq -r '.version' <<< "$nccl_metadata")"

# Check the exact new NVIDIA version for the running kernel; an old installed
# DKMS registration must not make the upgrade appear successful.
module_version=${driver_version%%-*}
check_dkms nvidia "$module_version"
[[ $(modinfo -F version nvidia) == "$module_version" ]]
# The installed doca-ofed package pins these four DKMS packages to its OFED build.
# Their DKMS PACKAGE_VERSION includes the Debian revision (unlike NVIDIA).
ofed_version=$(dpkg-query -W -f='${Depends}' doca-ofed | sed -n 's/.*mlnx-ofed-kernel-dkms (= \([^)]*\)).*/\1/p')
[[ -n "$ofed_version" ]] || { echo 'Missing exact OFED DKMS dependency.' >&2; exit 1; }
for name in mlnx-ofed-kernel iser isert srp; do
    check_package "${name}-dkms" "$ofed_version"
    check_dkms "$name" "$ofed_version"
done
apt-get check
audit=$(dpkg --audit)
[[ -z "$audit" ]] || { printf '%s\n' "$audit" >&2; exit 1; }
binary=$(jq -r '.binary_file' <<< "$nvbandwidth_metadata")
[[ $(readlink -f /opt/nvidia/nvbandwidth/nvbandwidth) == "/opt/nvidia/nvbandwidth/${binary}" ]]
verify_checksum "/opt/nvidia/nvbandwidth/${binary}" "$(jq -r '.sha256' <<< "$nvbandwidth_metadata")"
echo 'Target component package/module versions verified; runtime checks follow reboot.'
