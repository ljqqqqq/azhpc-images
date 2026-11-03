#!/bin/bash
set -euo pipefail
: "${TOP_DIR:?Run through upgrade_ubuntu2604_vr200.sh}"
source "${UTILS_DIR}/utilities.sh"

nvidia_metadata=$(get_component_config nvidia)
repo_path="${TOP_DIR}/internal_bits/$(jq -r '.driver.repo_file' <<< "$nvidia_metadata")"
verify_checksum "$repo_path" "$(jq -r '.driver.sha256' <<< "$nvidia_metadata")"
repo_package=$(dpkg-deb -f "$repo_path" Package)
[[ "$repo_package" == nvidia-driver-local-repo-* ]] || {
    echo "ERROR: unexpected NVIDIA repository package: ${repo_package}" >&2; exit 1;
}

# Only repository registration packages are removed; driver packages stay in place.
inventory=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n')
obsolete_repos=()
while IFS=$'\t' read -r package status; do
    if [[ "$package" == nvidia-driver-local-repo-* &&
          "${package%%:*}" != "$repo_package" && "$status" != not-installed ]]; then
        obsolete_repos+=("$package")
    fi
done <<< "$inventory"

# Re-extract the supplied repository even when its Debian version is unchanged.
apt-get install -y --reinstall "$repo_path"
install -d /usr/share/keyrings
install -m 0644 /var/"$repo_package"/nvidia-driver-local-*-keyring.gpg /usr/share/keyrings/
if [[ ${#obsolete_repos[@]} -gt 0 ]]; then
    echo "Removing superseded NVIDIA local repositories: ${obsolete_repos[*]}"
    apt-get purge -y -- "${obsolete_repos[@]}"
fi
apt-get update
echo "Active NVIDIA local repository: ${repo_package}"
