#!/bin/bash
set -euo pipefail
# Packer: EXTRA_PROVISION_SCRIPT=fixups/upgrade_ubuntu2604_vr200_nvbandwidth.sh
# Direct use: sudo bash fixups/upgrade_ubuntu2604_vr200_nvbandwidth.sh

[[ $# -eq 0 ]] || { echo "Usage: $0" >&2; exit 1; }
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
jq -e '.source != "private"' <<< "$metadata" >/dev/null
version=$(jq -er '.version' <<< "$metadata")
commit=$(jq -er '.commit' <<< "$metadata")
ref=$(jq -er '.ref' <<< "$metadata")
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'Requires a pinned nvbandwidth source commit.' >&2; exit 1;
}

manifest=/opt/azurehpc/component_versions.txt
if [[ -f "$manifest" ]]; then jq -e 'type == "object"' "$manifest" >/dev/null; fi
# Reuse image build tools, CUDA and HPC-X; this entry point installs no packages.
for tool in git cmake make g++; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
[[ -x /usr/local/cuda/bin/nvcc && -f /etc/profile.d/modules.sh ]] || {
    echo 'Requires the existing CUDA toolkit and HPC-X module environment.' >&2; exit 1;
}

build_dir=$(mktemp -d /tmp/nvbandwidth-refresh.XXXXXX)
trap 'rm -rf -- "$build_dir"' EXIT
cd "$build_dir"

echo "##[section]VR200 in-place refresh: nvbandwidth ${version} only"
bash "${COMPONENT_DIR}/install_nvbandwidth_tool.sh"
[[ -f /opt/nvidia/nvbandwidth/nvbandwidth && -x /opt/nvidia/nvbandwidth/nvbandwidth &&
   ! -L /opt/nvidia/nvbandwidth/nvbandwidth ]]
jq -e --arg version "$version" --arg commit "$commit" --arg ref "$ref" \
    '.NVBANDWIDTH == $version and .NVBANDWIDTH_REPO_COMMIT == $commit and
     .NVBANDWIDTH_REPO_REF == $ref' "$manifest" >/dev/null
echo '##[section]nvbandwidth upgraded in place; no reboot required.'
