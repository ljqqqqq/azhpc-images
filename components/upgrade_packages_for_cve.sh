#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: run this script as root or with sudo." >&2
    exit 1
fi

for command_name in apt-cache apt-get apt-mark dpkg dpkg-query ldd realpath; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $command_name" >&2
        exit 1
    fi
done

packages=(
    attr bind9-dnsutils bind9-host bind9-libs bison bsdextrautils bsdutils
    coreutils diffutils eject fdisk gir1.2-glib-2.0 libaom3 libattr1
    libattr1-dev libblkid-dev libblkid1 libc-bin libc-dev-bin libc-devtools
    libc6 libc6-dev libevent-2.1-7t64 libevent-core-2.1-7t64 libevent-dev
    libevent-extra-2.1-7t64 libevent-openssl-2.1-7t64
    libevent-pthreads-2.1-7t64 libexpat1 libexpat1-dev libfdisk1 libgcrypt20
    libglib2.0-0t64 libglib2.0-bin libglib2.0-data libheif-plugin-aomdec
    libheif-plugin-aomenc libheif1 libmount-dev libmount1 libp11-kit0
    libperl5.38t64 libpolkit-agent-1-0 libpolkit-gobject-1-0
    libpython3.12-dev libpython3.12-minimal libpython3.12-stdlib
    libpython3.12t64 libsmartcols1 libsqlite3-0 libssh-4 libssh2-1t64
    libssl-dev libssl3t64 libudisks2-0 libuuid1 libxml2 libxml2-dev locales
    mount openssh-client openssh-server openssh-sftp-server openssl perl
    perl-base perl-modules-5.38 pkexec polkitd python3-pip python3-pyasn1
    python3-wheel python3.12 python3.12-dev python3.12-minimal rsyslog sudo
    udisks2 util-linux uuid-dev uuid-runtime vim vim-common vim-runtime
    vim-tiny xxd zlib1g zlib1g-dev
)

restore_holds() {
    echo "Restoring PMIx-related package holds..."
    apt-mark hold pmix libevent-dev libhwloc-dev
}
trap restore_holds EXIT

export DEBIAN_FRONTEND=noninteractive

apt-get update

echo "Temporarily removing the libevent-dev hold..."
apt-mark unhold libevent-dev

echo "Upgrading installed packages from the requested list..."
apt-get install -y --only-upgrade "${packages[@]}"

echo
echo -e "Package\tInstalled\tCandidate\tStatus"
upgrade_incomplete=0
for package_name in "${packages[@]}"; do
    installed=$(dpkg-query -W -f='${Version}' "$package_name" 2>/dev/null || true)
    candidate=$(LC_ALL=C apt-cache policy "$package_name" | awk '$1 == "Candidate:" {print $2}')

    if [[ -z "$installed" ]]; then
        status=NOT_INSTALLED
    elif [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
        status=NO_CANDIDATE
    elif dpkg --compare-versions "$candidate" gt "$installed"; then
        status=UPGRADE_STILL_AVAILABLE
        upgrade_incomplete=1
    else
        status=UP_TO_DATE
    fi

    printf '%s\t%s\t%s\t%s\n' \
        "$package_name" "${installed:-N/A}" "${candidate:-N/A}" "$status"
done

if (( upgrade_incomplete != 0 )); then
    echo "ERROR: one or more installed packages still have an upgrade available." >&2
    exit 1
fi

echo
echo "Checking PMIx shared-library resolution..."
pmix_broken=0
while IFS= read -r pmix_library; do
    [[ -f "$pmix_library" ]] || continue
    resolved_library=$(realpath "$pmix_library")
    missing=$(ldd "$resolved_library" 2>/dev/null | grep 'not found' || true)
    if [[ -n "$missing" ]]; then
        echo "BROKEN: $pmix_library" >&2
        echo "$missing" >&2
        pmix_broken=1
    fi
done < <(dpkg-query -L pmix | grep -E '\.so($|\.)' | sort -u)

if (( pmix_broken != 0 )); then
    echo "ERROR: PMIx has unresolved shared-library dependencies after upgrade." >&2
    exit 1
fi

trap - EXIT
restore_holds
echo "Package upgrade and PMIx linkage checks completed successfully."