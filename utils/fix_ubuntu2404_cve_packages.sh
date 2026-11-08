#!/bin/bash
# Fix the 13 non-ESM packages reported for GB200 image 2611.06.4665:
# Twisted, APT, MSPack, BIND9 and PCRE2. Upgrade installed packages only.
# Fixed versions are minimums; accept newer standard-repository updates.
# https://ubuntu.com/security/CVE-2026-106454
# https://ubuntu.com/security/CVE-2026-109518
# https://ubuntu.com/security/CVE-2026-110602
# https://ubuntu.com/security/CVE-2026-97313
# https://ubuntu.com/security/CVE-2026-103111
# Usage: sudo bash utils/upgrade_ubuntu_in_place.sh
set -euo pipefail

. /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 24.04 ]]; then
    echo 'Skipping scan package fixes: this script applies to Ubuntu 24.04 only.'
    exit 0
fi

PACKAGES=(
    python3-twisted
    apt apt-utils libapt-pkg6.0t64
    libmspack0t64
    bind9-host bind9-dnsutils bind9-libs
    libpcre2-8-0 libpcre2-16-0 libpcre2-32-0 libpcre2-posix3 libpcre2-dev
)
declare -A FIXED_VERSIONS=(
    [python3-twisted]='24.3.0-1ubuntu0.3'
    [apt]='2.8.4ubuntu0.1'
    [apt-utils]='2.8.4ubuntu0.1'
    [libapt-pkg6.0t64]='2.8.4ubuntu0.1'
    [libmspack0t64]='0.11-1.1ubuntu0.24.04.1'
    [bind9-host]='1:9.18.39-0ubuntu0.24.04.9'
    [bind9-dnsutils]='1:9.18.39-0ubuntu0.24.04.9'
    [bind9-libs]='1:9.18.39-0ubuntu0.24.04.9'
    [libpcre2-8-0]='10.42-4ubuntu2.2'
    [libpcre2-16-0]='10.42-4ubuntu2.2'
    [libpcre2-32-0]='10.42-4ubuntu2.2'
    [libpcre2-posix3]='10.42-4ubuntu2.2'
    [libpcre2-dev]='10.42-4ubuntu2.2'
)

export DEBIAN_FRONTEND=noninteractive LC_ALL=C
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confnew)
INSTALLED_PACKAGES=()
for package in "${PACKAGES[@]}"; do
    if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" == installed ]]; then
        INSTALLED_PACKAGES+=("$package")
    else
        echo "${package} is not installed; skipping."
    fi
done
if [[ ${#INSTALLED_PACKAGES[@]} -eq 0 ]]; then
    echo 'No affected packages installed; nothing to do.'
    exit 0
fi

apt-get "${APT_OPTS[@]}" update
# Check every target before installing any of them.
for package in "${INSTALLED_PACKAGES[@]}"; do
    candidate_version=$(apt-cache policy "$package" | awk '/Candidate:/ { print $2 }')
    fixed_version=${FIXED_VERSIONS[$package]}
    if [[ -z "$candidate_version" || "$candidate_version" == '(none)' ]]; then
        echo "ERROR: no upgrade candidate available for ${package}." >&2
        exit 1
    fi
    if [[ "$candidate_version" == *esm* ]]; then
        echo "ERROR: ${package} candidate ${candidate_version} requires Ubuntu Pro/ESM." >&2
        exit 1
    fi
    if ! dpkg --compare-versions "$candidate_version" ge "$fixed_version"; then
        echo "ERROR: ${package} candidate ${candidate_version} is older than required ${fixed_version}." >&2
        exit 1
    fi
    installed_version=$(dpkg-query -W -f='${Version}' "$package")
    echo "${package} before: ${installed_version}; candidate: ${candidate_version}; fixed: ${fixed_version}"
done

apt-get "${APT_OPTS[@]}" install -y --only-upgrade "${INSTALLED_PACKAGES[@]}"

for package in "${INSTALLED_PACKAGES[@]}"; do
    installed_version=$(dpkg-query -W -f='${Version}' "$package")
    fixed_version=${FIXED_VERSIONS[$package]}
    if [[ "$installed_version" == *esm* ]] || ! dpkg --compare-versions "$installed_version" ge "$fixed_version"; then
        echo "ERROR: ${package} after upgrade is ${installed_version}; required non-ESM version >= ${fixed_version}." >&2
        exit 1
    fi
    echo "Verified ${package}: ${installed_version} >= ${fixed_version}"
done

echo "Ubuntu 24.04 scan package fixes completed: ${INSTALLED_PACKAGES[*]}"
