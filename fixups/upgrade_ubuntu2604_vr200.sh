#!/bin/bash
set -euo pipefail
# Packer: EXTRA_PROVISION_SCRIPT=fixups/upgrade_ubuntu2604_vr200.sh
# Direct use: sudo bash fixups/upgrade_ubuntu2604_vr200.sh [local-archive.tar.gz]
# This refresh updates only NVIDIA driver packages and their local repository.

[[ $# -le 1 ]] || { echo "Usage: $0 [local-archive.tar.gz]" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TOP_DIR
export COMPONENT_DIR="${TOP_DIR}/components" UTILS_DIR="${TOP_DIR}/utils"
export GPU="${GPU:-NVIDIA}" SKU="${SKU:-${GPU_SKU:-VR200}}"
export TARGET_NODE_TYPE="${TARGET_NODE_TYPE:-azure_vm_regular}"
DISTRIBUTION="$(. /etc/os-release; printf '%s%s' "$ID" "$VERSION_ID")"
ARCHITECTURE="$(uname -m)"
ARCHITECTURE_DISTRO="$(dpkg --print-architecture)"
export DISTRIBUTION ARCHITECTURE ARCHITECTURE_DISTRO
export REFRESH_MODE=true LC_ALL=C DEBIAN_FRONTEND=noninteractive
unset UCF_FORCE_CONFFOLD
export UCF_FORCE_CONFFNEW=1 NEEDRESTART_MODE=l
[[ "$DISTRIBUTION" == ubuntu26.04 && "$ARCHITECTURE" == aarch64 &&
   "$ARCHITECTURE_DISTRO" == arm64 && "$GPU" == NVIDIA && "$SKU" == VR200 &&
   "$TARGET_NODE_TYPE" == azure_vm_regular ]] || { echo 'Requires Ubuntu 26.04 arm64 NVIDIA VR200 azure_vm_regular.' >&2; exit 1; }

# Do not source set_properties.sh: it also performs a blanket OS upgrade.
COMPONENT_VERSIONS=$(jq -c . "${TOP_DIR}/versions.json")
export COMPONENT_VERSIONS
source "${UTILS_DIR}/utilities.sh"
source "${TOP_DIR}/fixups/vr200_refresh/preserve_settings.sh"
source "${COMPONENT_DIR}/configure_nvidia_repositories.sh"
if [[ -n "${1:-}" ]]; then tar -xzf "$1" -C "$TOP_DIR"; fi

nvidia_metadata=$(get_component_config nvidia)
jq -e '.driver.source == "private"' <<< "$nvidia_metadata" >/dev/null
driver_version=$(jq -er '.driver.version' <<< "$nvidia_metadata")
repo_file=$(jq -er '.driver.repo_file' <<< "$nvidia_metadata")
repo_path="${TOP_DIR}/internal_bits/${repo_file}"
verify_checksum "$repo_path" "$(jq -er '.driver.sha256' <<< "$nvidia_metadata")"
repo_package=$(dpkg-deb -f "$repo_path" Package)
[[ "$repo_package" == nvidia-driver-local-repo-* ]] || { echo 'Unexpected NVIDIA repository package.' >&2; exit 1; }
[[ -d "/lib/modules/$(uname -r)/build" ]] || { echo 'Running-kernel headers are missing.' >&2; exit 1; }

# Include the versioned driver libraries, including libnvidia-imex1, but leave
# the standalone nvidia-imex-direct package and its service configuration alone.
driver_packages=(nvidia-dkms-open nvidia-headless-open nvidia-headless-no-dkms-open
                 nvidia-kernel-common nvidia-kernel-source-open nvidia-firmware
                 nvidia-modprobe nvidia-persistenced libnvidia-compute libnvidia-cfg1
                 libnvidia-gpucomp libnvidia-imex1)
package_args=()
for package in "${driver_packages[@]}"; do package_args+=("${package}=${driver_version}"); done

export VR200_STATE_DIR
VR200_STATE_DIR=$(mktemp -d /var/tmp/vr200-in-place-upgrade.XXXXXX)
export VR200_REPORT_DIR="/var/tmp/azhpc-image-evidence/${IMAGE_EVIDENCE_RUN_NAME:-vr200-refresh}/upgrade"
install -d -m 0700 "$VR200_REPORT_DIR"
settings_saved=false
settings_restored=false
cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    if [[ "$settings_saved" == true && "$settings_restored" != true ]]; then
        restore_image_settings || rc=1
    fi
    if [[ $rc -eq 0 ]]; then rm -rf -- "$VR200_STATE_DIR"; else
        echo "ERROR: NVIDIA driver refresh failed; state retained at ${VR200_STATE_DIR}; reports: ${VR200_REPORT_DIR}. Package changes are not rolled back." >&2
    fi
    exit "$rc"
}
trap cleanup EXIT
snapshot_image_settings
settings_saved=true
dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "${VR200_REPORT_DIR}/packages-before.tsv"
export APT_CONFIG="${VR200_STATE_DIR}/apt-install.conf"
cat > "$APT_CONFIG" <<'EOF'
Dpkg::Options { "--force-confnew"; };
EOF
prepare_image_settings "${driver_packages[@]}" "$repo_package"

# Import only the new driver repository; do not reconfigure CUDA/public sources.
# shellcheck disable=SC2034 # Read by the sourced install_local_repository helper.
refresh=true
install_local_repository nvidia "$nvidia_metadata" 2>&1 | tee "${VR200_REPORT_DIR}/nvidia-repository.log"

# Fail before changing driver packages if APT needs another component changed.
install_args=(install -y --no-remove --no-install-recommends "${package_args[@]}")
apt-get --simulate "${install_args[@]}" 2>&1 | tee "${VR200_REPORT_DIR}/nvidia-plan.log"
while read -r action package _; do
    [[ "$action" == Inst || "$action" == Remv ]] || continue
    allowed=false
    for driver_package in "${driver_packages[@]}"; do
        [[ "${package%%:*}" != "$driver_package" ]] || allowed=true
    done
    if [[ "$action" == Remv || "$allowed" != true ]]; then
        echo "ERROR: driver-only refresh would ${action} unrelated/conflicting package ${package}." >&2
        exit 1
    fi
done < "${VR200_REPORT_DIR}/nvidia-plan.log"

echo '##[section]VR200 in-place refresh: NVIDIA driver only'
apt-get "${install_args[@]}" 2>&1 | tee "${VR200_REPORT_DIR}/nvidia.log"
restore_image_settings
settings_restored=true
ldconfig
update-initramfs -u -k all
bash "${TOP_DIR}/fixups/vr200_refresh/verify_versions.sh" --driver-only \
    2>&1 | tee "${VR200_REPORT_DIR}/verify-versions.log"
write_component_version NVIDIA "${driver_version%%-*}"
dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "${VR200_REPORT_DIR}/packages-after.tsv"
echo '##[section]NVIDIA driver upgraded in place. Reboot before GPU/RDMA runtime validation.'
