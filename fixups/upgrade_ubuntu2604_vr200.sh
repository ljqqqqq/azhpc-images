#!/bin/bash
set -euo pipefail
# Packer: EXTRA_PROVISION_SCRIPT=fixups/upgrade_ubuntu2604_vr200.sh
# Direct use: sudo bash fixups/upgrade_ubuntu2604_vr200.sh [local-archive.tar.gz]

[[ $# -le 1 ]] || { echo "Usage: $0 [local-archive.tar.gz]" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
export TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export COMPONENT_DIR="${TOP_DIR}/components" UTILS_DIR="${TOP_DIR}/utils"
export AZHPC_IMAGES_TEST_DIR="${TOP_DIR}/tests"
export GPU="${GPU:-NVIDIA}" SKU="${SKU:-${GPU_SKU:-VR200}}"
export TARGET_NODE_TYPE="${TARGET_NODE_TYPE:-azure_vm_regular}"
export DISTRIBUTION="$(. /etc/os-release; printf '%s%s' "$ID" "$VERSION_ID")"
export ARCHITECTURE="$(uname -m)" ARCHITECTURE_DISTRO="$(dpkg --print-architecture)"
export MODULE_FILES_DIRECTORY=/usr/share/modules/modulefiles
export NVLINK_RACKSCALE=true REFRESH_MODE=true LC_ALL=C DEBIAN_FRONTEND=noninteractive
unset UCF_FORCE_CONFFOLD
export UCF_FORCE_CONFFNEW=1 NEEDRESTART_MODE=l
[[ "$DISTRIBUTION" == ubuntu26.04 && "$ARCHITECTURE" == aarch64 &&
   "$ARCHITECTURE_DISTRO" == arm64 && "$GPU" == NVIDIA && "$SKU" == VR200 &&
   "$TARGET_NODE_TYPE" == azure_vm_regular ]] || { echo 'Requires Ubuntu 26.04 arm64 NVIDIA VR200 azure_vm_regular.' >&2; exit 1; }

# set_properties.sh also performs a blanket OS upgrade; initialize explicitly.
COMPONENT_VERSIONS=$(jq -c . "${TOP_DIR}/versions.json")
export COMPONENT_VERSIONS
source "${UTILS_DIR}/utilities.sh"
source "${TOP_DIR}/fixups/vr200_refresh/preserve_settings.sh"
if [[ -n "${1:-}" ]]; then tar -xzf "$1" -C "$TOP_DIR"; fi

nvidia_metadata=$(get_component_config nvidia)
cuda_metadata=$(get_component_config cuda)
doca_metadata=$(get_component_config doca)
nvbandwidth_metadata=$(get_component_config nvbandwidth)
verify_bit() {
    local file=$1 checksum=$2
    [[ -f "${TOP_DIR}/internal_bits/${file}" && "$checksum" =~ ^[[:xdigit:]]{64}$ ]] ||
        { echo "Missing private input/checksum: ${file}" >&2; exit 1; }
    verify_checksum "${TOP_DIR}/internal_bits/${file}" "$checksum"
}
jq -e '.driver.source == "private"' <<< "$nvidia_metadata" >/dev/null
jq -e '.driver.source == "private"' <<< "$cuda_metadata" >/dev/null
for metadata in "$doca_metadata" "$nvbandwidth_metadata"; do
    jq -e '.source == "private"' <<< "$metadata" >/dev/null
done
verify_bit "$(jq -r '.driver.repo_file' <<< "$nvidia_metadata")" "$(jq -r '.driver.sha256' <<< "$nvidia_metadata")"
verify_bit "$(jq -r '.driver.repo_file' <<< "$cuda_metadata")" "$(jq -r '.driver.sha256' <<< "$cuda_metadata")"
verify_bit "$(jq -r '.repo_file' <<< "$doca_metadata")" "$(jq -r '.sha256' <<< "$doca_metadata")"
verify_bit "$(jq -r '.binary_file' <<< "$nvbandwidth_metadata")" "$(jq -r '.sha256' <<< "$nvbandwidth_metadata")"
[[ -d "/lib/modules/$(uname -r)/build" ]] || { echo 'Running-kernel headers are missing.' >&2; exit 1; }
bash -e -c 'source /etc/profile.d/modules.sh; module load mpi/hpcx; test -d "$HPCX_MPI_DIR"; test -d "$HPCX_SHARP_DIR"; test -d "$HPCX_UCX_DIR"'

export VR200_STATE_DIR
VR200_STATE_DIR=$(mktemp -d /var/tmp/vr200-in-place-upgrade.XXXXXX)
export VR200_REPORT_DIR="/var/tmp/azhpc-image-evidence/${IMAGE_EVIDENCE_RUN_NAME:-vr200-refresh}/upgrade"
install -d -m 0700 "$VR200_REPORT_DIR"
settings_saved=false
settings_restored=false
nvbandwidth_completed=false
nvbandwidth_path=/opt/nvidia/nvbandwidth

cleanup() {
    local rc=$? path
    trap - EXIT
    set +e
    if [[ "$settings_saved" == true && "$settings_restored" != true ]]; then
        restore_image_settings || rc=1
    fi
    # Successful directory replacements and package upgrades are not rolled back.
    for path in "$nvbandwidth_path"; do
        [[ "$nvbandwidth_completed" != true ]] || continue
        if [[ -e "${VR200_STATE_DIR}/previous${path}" || -L "${VR200_STATE_DIR}/previous${path}" ]]; then
            if [[ -e "$path" || -L "$path" ]]; then
                mkdir -p "$(dirname "${VR200_STATE_DIR}/generated${path}")"
                mv "$path" "${VR200_STATE_DIR}/generated${path}" || rc=1
            fi
            mv "${VR200_STATE_DIR}/previous${path}" "$path" || rc=1
        fi
    done
    if [[ $rc -eq 0 ]]; then rm -rf -- "$VR200_STATE_DIR"; else
        echo "ERROR: upgrade failed; work/state backups retained at ${VR200_STATE_DIR}; reports: ${VR200_REPORT_DIR}. Package changes are not rolled back." >&2
    fi
    exit "$rc"
}
trap cleanup EXIT
snapshot_image_settings
settings_saved=true
dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "${VR200_REPORT_DIR}/packages-before.tsv"

# Use the new package configuration during noninteractive upgrades. APT may
# replace conflicting packages as required by the component installers.
# No component purge, autoremove, or explicit DKMS removal is performed.
export APT_CONFIG="${VR200_STATE_DIR}/apt-install.conf"
cat > "$APT_CONFIG" <<'EOF'
Dpkg::Options { "--force-confnew"; };
EOF
prepare_image_settings

run_component() {
    local script=$1
    mkdir -p "${VR200_STATE_DIR}/work/${script%.sh}"
    echo "##[section]VR200 in-place upgrade: ${script}"
    (cd "${VR200_STATE_DIR}/work/${script%.sh}" && bash "${COMPONENT_DIR}/${script}")
}
move_previous_paths() {
    local path
    for path in "$@"; do
        if [[ -e "$path" || -L "$path" ]]; then
            mkdir -p "$(dirname "${VR200_STATE_DIR}/previous${path}")"
            mv "$path" "${VR200_STATE_DIR}/previous${path}"
        fi
    done
}
CUDA_REPO_DISTRIBUTION=$(jq -r '.driver.distribution' <<< "$cuda_metadata")
configure_cuda_online_repo "$CUDA_REPO_DISTRIBUTION" sbsa disabled \
    2>&1 | tee "${VR200_REPORT_DIR}/cuda-source-policy.log"
run_component install_doca.sh 2>&1 | tee "${VR200_REPORT_DIR}/doca.log"
# This private CUDA repo changed contents without changing its package version.
# A normal `apt install <local.deb>` can leave the old repository payload in place.
apt-get install -y --reinstall "${TOP_DIR}/internal_bits/$(jq -r '.driver.repo_file' <<< "$cuda_metadata")" \
    2>&1 | tee "${VR200_REPORT_DIR}/cuda-repo.log"
bash "${TOP_DIR}/fixups/vr200_refresh/refresh_nvidia_repo.sh" 2>&1 | tee "${VR200_REPORT_DIR}/nvidia-repo.log"
bash "${TOP_DIR}/fixups/vr200_refresh/reinstall_private_packages.sh" \
    "/var/$(jq -r '.driver.repo_file' <<< "$nvidia_metadata" | cut -d_ -f1)" \
    "/var/$(jq -r '.driver.repo_file' <<< "$cuda_metadata" | cut -d_ -f1)" \
    2>&1 | tee "${VR200_REPORT_DIR}/private-packages.log"
run_component install_nvidiagpudriver.sh 2>&1 | tee "${VR200_REPORT_DIR}/nvidia.log"
# Preserve the base image's NCCL packages, plugin and test binaries.
move_previous_paths "$nvbandwidth_path"
run_component install_nvbandwidth_tool.sh 2>&1 | tee "${VR200_REPORT_DIR}/nvbandwidth.log"
nvbandwidth_completed=true

bash "${TOP_DIR}/fixups/vr200_refresh/apply_image_fixes.sh" 2>&1 | tee "${VR200_REPORT_DIR}/image-fixes.log"

# DCGM is inherited from the base image; keep only its public packages available.
configure_cuda_online_repo "$CUDA_REPO_DISTRIBUTION" sbsa dcgm \
    2>&1 | tee -a "${VR200_REPORT_DIR}/cuda-source-policy.log"

# Restore only the temporary policy-rc.d and original package holds.
# Component configuration remains as written by the installers.
restore_image_settings
settings_restored=true
ldconfig
update-initramfs -u -k all
bash "${TOP_DIR}/fixups/vr200_refresh/remove_nolpi.sh" 2>&1 | tee "${VR200_REPORT_DIR}/remove-nolpi.log"
bash "${TOP_DIR}/fixups/vr200_refresh/verify_versions.sh" 2>&1 | tee "${VR200_REPORT_DIR}/verify-versions.log"
dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "${VR200_REPORT_DIR}/packages-after.tsv"
diff -u <(awk '$1 ~ /^libnccl/' "${VR200_REPORT_DIR}/packages-before.tsv") \
    <(awk '$1 ~ /^libnccl/' "${VR200_REPORT_DIR}/packages-after.tsv") || {
    echo 'ERROR: NCCL package versions changed during refresh.' >&2; exit 1;
}
echo '##[section]Target components upgraded in place. Reboot before GPU/RDMA runtime validation.'
