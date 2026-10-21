#!/bin/bash

set -euo pipefail
set -x

# Upgrade Ubuntu 24.04 packages whose security fixes are available from the
# standard Ubuntu repositories. Do not pull Ubuntu Pro/ESM packages into the
# image. Packages that are not installed are not vulnerable and are skipped.

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "Skipping CVE package upgrades: this component only applies to Ubuntu 24.04."
    exit 0
fi

declare -a PACKAGES=(
    u-boot-tools
    python3-urllib3
    curl
    libcurl3t64-gnutls
    libcurl4t64
    openssh-sftp-server
    openssh-client
    openssh-server
    python3-jwt
    libx11-6
    libx11-data
    libx11-xcb1
)

declare -A MINIMUM_FIXED_VERSIONS=(
    [u-boot-tools]="2025.10-0ubuntu0.24.04.4"
    [python3-urllib3]="2.0.7-1ubuntu0.8"
    [curl]="8.5.0-2ubuntu10.16"
    [libcurl3t64-gnutls]="8.5.0-2ubuntu10.16"
    [libcurl4t64]="8.5.0-2ubuntu10.16"
    [openssh-sftp-server]="1:9.6p1-3ubuntu13.20"
    [openssh-client]="1:9.6p1-3ubuntu13.20"
    [openssh-server]="1:9.6p1-3ubuntu13.20"
    [python3-jwt]="2.7.0-1ubuntu0.3"
    [libx11-6]="2:1.8.7-1ubuntu0.1"
    [libx11-data]="2:1.8.7-1ubuntu0.1"
    [libx11-xcb1]="2:1.8.7-1ubuntu0.1"
)

declare -a INSTALLED_PACKAGES=()

for package in "${PACKAGES[@]}"; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null | grep -q '^ii '; then
        INSTALLED_PACKAGES+=("${package}")
    else
        echo "${package} is not installed; skipping."
    fi
done

if (( ${#INSTALLED_PACKAGES[@]} == 0 )); then
    echo "None of the affected packages are installed; no upgrade is required."
    exit 0
fi

apt-get update

# Fail before changing the image if an enabled repository cannot provide every
# required standard-repository fix or would resolve the package to an ESM build.
for package in "${INSTALLED_PACKAGES[@]}"; do
    candidate_version=$(apt-cache policy "${package}" | awk '/Candidate:/ { print $2; exit }')
    minimum_version=${MINIMUM_FIXED_VERSIONS[${package}]}

    if [[ -z "${candidate_version}" || "${candidate_version}" == "(none)" ]]; then
        echo "ERROR: no upgrade candidate is available for ${package}." >&2
        exit 1
    fi

    if [[ "${candidate_version}" == *esm* ]]; then
        echo "ERROR: ${package} candidate ${candidate_version} is from Ubuntu Pro/ESM; refusing it." >&2
        exit 1
    fi

    if ! dpkg --compare-versions "${candidate_version}" ge "${minimum_version}"; then
        echo "ERROR: ${package} candidate ${candidate_version} is older than required fix ${minimum_version}." >&2
        exit 1
    fi
done

DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${INSTALLED_PACKAGES[@]}"

for package in "${INSTALLED_PACKAGES[@]}"; do
    installed_version=$(dpkg-query -W -f='${Version}' "${package}")
    minimum_version=${MINIMUM_FIXED_VERSIONS[${package}]}

    if ! dpkg --compare-versions "${installed_version}" ge "${minimum_version}"; then
        echo "ERROR: ${package} remains at ${installed_version}; expected ${minimum_version} or newer." >&2
        exit 1
    fi

    echo "Verified ${package} ${installed_version} (minimum fixed version: ${minimum_version})."
done
