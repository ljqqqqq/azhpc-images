#!/bin/bash
set -euo pipefail

# Standalone Packer fix-up for refreshing the SKU customization dispatcher and
# scripts without rerunning the full distro installer.
export TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export COMPONENT_DIR="${TOP_DIR}/components"
export DISTRIBUTION="$(. /etc/os-release; printf '%s%s' "$ID" "$VERSION_ID")"
export GPU="${GPU:-NVIDIA}"
export SKU="${SKU:-${GPU_SKU:-VR200}}"

exec bash "${COMPONENT_DIR}/setup_sku_customizations.sh"
