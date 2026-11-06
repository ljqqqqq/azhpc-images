#!/bin/bash
set -euo pipefail

# Remove Azure HPC Health Checks from an existing image.
#
# Direct use:
#   sudo bash fixups/upgrade_remove_aznhc.sh
#
# Packer use:
#   EXTRA_PROVISION_SCRIPT=fixups/upgrade_remove_aznhc.sh

[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq is required.' >&2; exit 1; }

readonly azhpc_root="${AZHPC_ROOT:-/opt/azurehpc}"
[[ "$azhpc_root" == /* && "$azhpc_root" != / ]] || {
    echo "AZHPC_ROOT must be an absolute non-root path: ${azhpc_root}" >&2
    exit 1
}
readonly test_root="${azhpc_root}/test"
readonly health_checks_dir="${test_root}/azurehpc-health-checks"
readonly component_versions_file="${azhpc_root}/component_versions.txt"

aznhc_version=''
updated_manifest=''
cleanup() {
    [[ -z "$updated_manifest" ]] || rm -f -- "$updated_manifest"
}
trap cleanup EXIT

# Validate and prepare the manifest update before removing installed content.
if [[ -f "$component_versions_file" ]]; then
    jq -e 'type == "object"' "$component_versions_file" >/dev/null
    aznhc_version=$(jq -r '.AZ_HEALTH_CHECKS // empty' "$component_versions_file")
    updated_manifest=$(mktemp "${component_versions_file}.tmp.XXXXXX")
    jq 'del(.AZ_HEALTH_CHECKS)' "$component_versions_file" > "$updated_manifest"
    chmod 0644 "$updated_manifest"
fi

if [[ -d "$health_checks_dir" || -L "$health_checks_dir" ]]; then
    rm -rf -- "$health_checks_dir"
    echo "Removed ${health_checks_dir}"
else
    echo "Azure HPC Health Checks directory is already absent."
fi

# install_health_checks.sh leaves its downloaded release archive beside the
# extracted directory. Remove only the version recorded by this image.
if [[ -n "$aznhc_version" ]]; then
    if [[ "$aznhc_version" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        archive="${test_root}/v${aznhc_version}.tar.gz"
        if [[ -f "$archive" ]]; then
            rm -f -- "$archive"
            echo "Removed ${archive}"
        fi
    else
        echo "WARNING: not removing an AZNHC archive for unsafe version value: ${aznhc_version}" >&2
    fi
fi

# AZNHC pulls these images during installation. Remove only its exact image
# tags; do not prune unrelated or shared container images.
if command -v docker >/dev/null; then
    for image in mcr.microsoft.com/aznhc/aznhc-nv mcr.microsoft.com/aznhc/aznhc-rocm; do
        if docker image inspect "$image" >/dev/null 2>&1; then
            if docker image rm "$image"; then
                echo "Removed container image ${image}"
            else
                echo "WARNING: could not remove container image ${image}; it may be in use." >&2
            fi
        fi
    done
fi

if [[ -n "$updated_manifest" ]]; then
    mv -f -- "$updated_manifest" "$component_versions_file"
    updated_manifest=''
    echo "Removed AZ_HEALTH_CHECKS from ${component_versions_file}"
else
    echo "Component manifest is already absent."
fi

echo 'Azure HPC Health Checks removal complete.'
