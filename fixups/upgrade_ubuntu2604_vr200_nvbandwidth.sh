#!/bin/bash
set -euo pipefail
# Packer: EXTRA_PROVISION_SCRIPT=fixups/upgrade_ubuntu2604_vr200_nvbandwidth.sh
# Direct use: sudo bash fixups/upgrade_ubuntu2604_vr200_nvbandwidth.sh [local-binary]

[[ $# -le 1 ]] || { echo "Usage: $0 [local-binary]" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TOP_DIR
export COMPONENT_DIR="${TOP_DIR}/components" UTILS_DIR="${TOP_DIR}/utils"
export GPU="${GPU:-NVIDIA}" SKU="${SKU:-${GPU_SKU:-VR200}}"
export TARGET_NODE_TYPE="${TARGET_NODE_TYPE:-azure_vm_regular}"
DISTRIBUTION="$(. /etc/os-release; printf '%s%s' "$ID" "$VERSION_ID")"
ARCHITECTURE="$(uname -m)"
export DISTRIBUTION ARCHITECTURE
[[ "$DISTRIBUTION" == ubuntu26.04 && "$ARCHITECTURE" == aarch64 &&
   "$GPU" == NVIDIA && "$SKU" == VR200 && "$TARGET_NODE_TYPE" == azure_vm_regular ]] || {
    echo 'Requires Ubuntu 26.04 aarch64 NVIDIA VR200 azure_vm_regular.' >&2; exit 1;
}

# Avoid set_properties.sh, which performs a system package upgrade.
COMPONENT_VERSIONS=$(jq -c . "${TOP_DIR}/versions.json")
export COMPONENT_VERSIONS
source "${UTILS_DIR}/utilities.sh"
metadata=$(get_component_config nvbandwidth)
jq -e '.source == "private"' <<< "$metadata" >/dev/null
binary_file=$(jq -er '.binary_file' <<< "$metadata")
version=$(jq -er '.version' <<< "$metadata")
checksum=$(jq -er '.sha256' <<< "$metadata")
[[ "$binary_file" != */* && "$binary_file" != . && "$binary_file" != .. ]] || {
    echo 'Expected a plain nvbandwidth binary filename.' >&2; exit 1;
}

manifest=/opt/azurehpc/component_versions.txt
if [[ -f "$manifest" ]]; then jq -e 'type == "object"' "$manifest" >/dev/null; fi
binary_path="${TOP_DIR}/internal_bits/${binary_file}"
if [[ -n "${1:-}" ]]; then
    verify_checksum "$1" "$checksum"
    install -d "${TOP_DIR}/internal_bits"
    if [[ ! "$1" -ef "$binary_path" ]]; then install -m 0755 "$1" "$binary_path"; fi
fi
verify_checksum "$binary_path" "$checksum"

echo "##[section]VR200 in-place refresh: nvbandwidth ${version} only"
bash "${COMPONENT_DIR}/install_nvbandwidth_tool.sh"
verify_checksum "/opt/nvidia/nvbandwidth/${binary_file}" "$checksum"
[[ "$(readlink /opt/nvidia/nvbandwidth/nvbandwidth)" == "/opt/nvidia/nvbandwidth/${binary_file}" ]]
jq -e --arg version "$version" '.NVBANDWIDTH == $version' "$manifest" >/dev/null
echo '##[section]nvbandwidth upgraded in place; no reboot required.'
