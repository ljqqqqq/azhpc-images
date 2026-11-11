#!/bin/bash
set -euo pipefail
# Replace the five confirmed public NVIDIA/IMEX downloads in build 40806.
# Other installed private/unknown-source components retain their versions.
# Packer: EXTRA_PROVISION_SCRIPT=fixups/upgrade_ubuntu2604_vr200_private_nvidia_cuda.sh
# Direct: sudo bash fixups/upgrade_ubuntu2604_vr200_private_nvidia_cuda.sh [bundle.tar.gz]

[[ $# -le 1 && $EUID -eq 0 ]] || { echo "Usage: sudo bash $0 [bundle.tar.gz]" >&2; exit 1; }
export TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export UTILS_DIR="${TOP_DIR}/utils" GPU=NVIDIA SKU=VR200 TARGET_NODE_TYPE=azure_vm_regular
export DISTRIBUTION="$(. /etc/os-release; printf '%s%s' "$ID" "$VERSION_ID")"
export ARCHITECTURE="$(uname -m)" LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
[[ "$DISTRIBUTION" == ubuntu26.04 && "$ARCHITECTURE" == aarch64 &&
   "$(dpkg --print-architecture)" == arm64 ]] || {
    echo 'Requires an existing Ubuntu 26.04 arm64 VR200 image.' >&2; exit 1;
}
[[ -d "/lib/modules/$(uname -r)/build" ]] || { echo 'Running-kernel headers are missing.' >&2; exit 1; }
unset UCF_FORCE_CONFFOLD
export UCF_FORCE_CONFFNEW=1
export COMPONENT_VERSIONS
COMPONENT_VERSIONS=$(jq -c . "${TOP_DIR}/versions.json")
source "${UTILS_DIR}/utilities.sh"
source "${TOP_DIR}/fixups/vr200_refresh/preserve_settings.sh"

# Only unpack the two repository payloads needed by this repair.
nvidia_metadata=$(get_component_config nvidia)
cuda_metadata=$(get_component_config cuda)
jq -e '.driver.source == "private"' <<< "$nvidia_metadata" >/dev/null
jq -e '.driver.source == "private"' <<< "$cuda_metadata" >/dev/null
nvidia_repo_file=$(jq -er '.driver.repo_file' <<< "$nvidia_metadata")
cuda_repo_file=$(jq -er '.driver.repo_file' <<< "$cuda_metadata")
if [[ -n "${1:-}" ]]; then
    tar -xzf "$1" -C "$TOP_DIR" "internal_bits/${nvidia_repo_file}" "internal_bits/${cuda_repo_file}"
fi
verify_checksum "${TOP_DIR}/internal_bits/${nvidia_repo_file}" "$(jq -er '.driver.sha256' <<< "$nvidia_metadata")"
verify_checksum "${TOP_DIR}/internal_bits/${cuda_repo_file}" "$(jq -er '.driver.sha256' <<< "$cuda_metadata")"
nvidia_repo_package=$(dpkg-deb -f "${TOP_DIR}/internal_bits/${nvidia_repo_file}" Package)
cuda_repo_package=$(dpkg-deb -f "${TOP_DIR}/internal_bits/${cuda_repo_file}" Package)
[[ "$nvidia_repo_package" == nvidia-driver-local-repo-* && "$cuda_repo_package" == cuda-repo-*-local ]] || {
    echo 'Unexpected private repository registration packages.' >&2; exit 1;
}

export VR200_STATE_DIR
VR200_STATE_DIR=$(mktemp -d /var/tmp/vr200-private-nvidia-cuda.XXXXXX)
report_dir="/var/tmp/azhpc-image-evidence/${IMAGE_EVIDENCE_RUN_NAME:-vr200-private-repair}/private-nvidia-cuda"
install -d -m 0700 "$report_dir"
exec > >(tee -a "${report_dir}/upgrade.log") 2>&1
settings_saved=false
cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    if [[ "$settings_saved" == true ]]; then restore_image_settings || rc=1; fi
    if [[ $rc -eq 0 ]]; then rm -rf -- "$VR200_STATE_DIR"; else
        echo "ERROR: repair failed; state retained at ${VR200_STATE_DIR}; reports: ${report_dir}. Package changes are not rolled back." >&2
    fi
    exit "$rc"
}
trap cleanup EXIT
snapshot_image_settings
settings_saved=true
inventory() {
    dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n' | sort
}
inventory > "${report_dir}/packages-before.tsv"
export APT_CONFIG="${VR200_STATE_DIR}/apt.conf"
printf 'Dpkg::Options { "--force-confnew"; };\n' > "$APT_CONFIG"
printf '#!/bin/sh\nexit 101\n' > "${VR200_STATE_DIR}/policy-rc.d"
rm -f -- "$policy_rc_path"
install -m 0755 "${VR200_STATE_DIR}/policy-rc.d" "$policy_rc_path"
for package in "$nvidia_repo_package" "$cuda_repo_package"; do
    if grep -Fxq "$package" "${VR200_STATE_DIR}/original-holds.txt"; then apt-mark unhold "$package"; fi
done

# Refresh even an unchanged outer DEB version; its embedded archives may differ.
apt-get install -y --reinstall -- "${TOP_DIR}/internal_bits/${nvidia_repo_file}" "${TOP_DIR}/internal_bits/${cuda_repo_file}"
nvidia_repo="/var/${nvidia_repo_package}"
cuda_repo="/var/${cuda_repo_package}"
shopt -s nullglob
nvidia_keys=("$nvidia_repo"/nvidia-driver-local-*-keyring.gpg)
cuda_keys=("$cuda_repo"/cuda-*-keyring.gpg)
[[ ${#nvidia_keys[@]} -eq 1 && ${#cuda_keys[@]} -eq 1 ]] || { echo 'Expected one keyring per private repository.' >&2; exit 1; }
install -m 0644 "${nvidia_keys[0]}" "${cuda_keys[0]}" /usr/share/keyrings/

planner="${TOP_DIR}/fixups/vr200_refresh/private_nvidia_cuda.py"
plan="${report_dir}/private-packages.tsv"
python3 "$planner" plan "${report_dir}/packages-before.tsv" "$plan" "${VR200_STATE_DIR}/archives" "$nvidia_repo" "$cuda_repo"
mapfile -d '' -t archives < "${VR200_STATE_DIR}/archives"
while IFS=$'\t' read -r repository package architecture rest; do
    [[ "$repository" != repository ]] || continue
    for held in "$package" "${package}:${architecture}"; do
        if grep -Fxq "$held" "${VR200_STATE_DIR}/original-holds.txt"; then apt-mark unhold "$held"; fi
    done
done < "$plan"

# Use fresh, isolated indexes containing ONLY these two signed private repos.
# The simulated transaction must not change any component outside the target list.
# Explicit DEB paths force the supplied payload even when the version is equal.
mkdir -p "${VR200_STATE_DIR}/lists/partial"
private_sources="${VR200_STATE_DIR}/private.list"
printf 'deb [signed-by=/usr/share/keyrings/%s] file:%s /\n' "$(basename "${nvidia_keys[0]}")" "$nvidia_repo" > "$private_sources"
printf 'deb [signed-by=/usr/share/keyrings/%s] file:%s /\n' "$(basename "${cuda_keys[0]}")" "$cuda_repo" >> "$private_sources"
cp "$private_sources" "${report_dir}/install-sources.list"
apt_options=(
    -o "Dir::Etc::sourcelist=$private_sources" -o 'Dir::Etc::sourceparts=-'
    -o "Dir::State::lists=${VR200_STATE_DIR}/lists"
    -o "Dir::Cache::pkgcache=${VR200_STATE_DIR}/pkgcache.bin"
    -o "Dir::Cache::srcpkgcache=${VR200_STATE_DIR}/srcpkgcache.bin"
    -o "Dir::Cache::archives=${VR200_STATE_DIR}/deb-cache"
    -o 'APT::Sandbox::User=root'
)
mkdir -p "${VR200_STATE_DIR}/deb-cache/partial"
apt-get "${apt_options[@]}" -o APT::Update::Error-Mode=any update
apt-get "${apt_options[@]}" --simulate install --reinstall --allow-downgrades --no-remove -- "${archives[@]}" |
    tee "${report_dir}/apt-plan.log"
python3 "$planner" check-simulation "${report_dir}/apt-plan.log" "$plan"
inventory > "${report_dir}/transaction-before.tsv"
apt-get "${apt_options[@]}" install -y --reinstall --allow-downgrades --no-remove -- "${archives[@]}"
inventory > "${report_dir}/packages-after.tsv"
python3 "$planner" verify "${report_dir}/packages-after.tsv" "$plan" "${report_dir}/transaction-before.tsv"
apt-get "${apt_options[@]}" check
audit=$(dpkg --audit)
[[ -z "$audit" ]] || { printf '%s\n' "$audit" >&2; exit 1; }

driver_version=$(dpkg-query -W -f='${Version}' nvidia-dkms-open)
module_version=${driver_version%%-*}
[[ "$(modinfo -F version nvidia)" == "$module_version" ]]
dkms_status=$(dkms status -m nvidia -v "$module_version" -k "$(uname -r)")
printf '%s\n' "$dkms_status"
grep -Eq ': installed( \(Original modules exist\))?$' <<< "$dkms_status"
write_component_version NVIDIA "$module_version"
cuda_release=$(jq -er '.driver.version' <<< "$cuda_metadata")
cuda_version=$(dpkg-query -W -f='${Version}' "cuda-nvcc-${cuda_release//./-}")
write_component_version CUDA "${cuda_version%%-*}"
ldconfig
update-initramfs -u -k all

# Keep the normal CUDA online source available for DCGM only after the repair.
configure_cuda_online_repo "$(jq -er '.driver.distribution' <<< "$cuda_metadata")" sbsa dcgm
echo "Private NVIDIA/CUDA repair complete; reports: ${report_dir}. Reboot before GPU/NCCL validation."
