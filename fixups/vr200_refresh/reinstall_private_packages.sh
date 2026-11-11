#!/bin/bash
set -euo pipefail
[[ $# -gt 0 ]] || { echo 'Usage: reinstall_private_packages.sh /var/private-repo [...]' >&2; exit 1; }

# Equal versions do not establish provenance. Reinstall matching installed
# packages using explicit archives from the freshly verified private repos.
inventory=$(dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n')
declare -A installed=()
while IFS=$'\t' read -r package version architecture status; do
    if [[ "$status" == installed ]]; then
        installed["${package}:${architecture}"]=$version
    fi
done <<< "$inventory"

shopt -s nullglob
archives=()
for directory in "$@"; do
    [[ "$directory" == /* && -d "$directory" ]] || {
        echo "ERROR: missing absolute private repository directory: ${directory}" >&2; exit 1;
    }
    candidates=("$directory"/*.deb)
    [[ ${#candidates[@]} -gt 0 ]] || {
        echo "ERROR: no package archives in ${directory}" >&2; exit 1;
    }
    for archive in "${candidates[@]}"; do
        metadata=$(dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}\n' "$archive")
        IFS=$'\t' read -r package version architecture <<< "$metadata"
        [[ -n "$package" && -n "$version" && -n "$architecture" ]] || {
            echo "ERROR: incomplete package metadata: ${archive}" >&2; exit 1;
        }
        if [[ "${installed["${package}:${architecture}"]:-}" == "$version" ]]; then
            archives+=("$archive")
            echo "Reinstalling private package: ${package}:${architecture}=${version}"
            sha256sum -- "$archive"
        fi
    done
done

if [[ ${#archives[@]} -eq 0 ]]; then
    echo 'No installed packages at the private archive versions; component installers handle upgrades.'
    exit 0
fi
apt-get install -y --reinstall --no-remove -- "${archives[@]}"
