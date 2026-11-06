#!/bin/bash
# Upgrade installed Brotli and zlib packages and verify their security fixes.
# Usage (Packer): EXTRA_PROVISION_SCRIPT=utils/upgrade_ubuntu_in_place.sh
#                 SKIP_PREREQUISITES=true REFRESH_MODE=true
# Direct use: sudo bash utils/upgrade_ubuntu_in_place.sh
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for script in fix_usn_8956_1_brotli.sh fix_usn_8954_1_zlib.sh; do
    echo "##[section]Ubuntu in-place upgrade: ${script}"
    bash "${SCRIPT_DIR}/${script}"
done

echo 'Brotli and zlib in-place upgrades completed.'
