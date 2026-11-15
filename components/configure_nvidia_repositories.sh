#!/bin/bash

############################################################################
# Private stacks need selected public HPC packages without exposing competing
# driver/toolkit copies to later APT transactions.
configure_cuda_online_repo() (
    set -euo pipefail
    local distribution=$1 architecture=$2 mode=$3
    local source_name="cuda-${distribution}-${architecture}"
    local source_file="/etc/apt/sources.list.d/${source_name}.list"
    local modern_source_file="/etc/apt/sources.list.d/${source_name}.sources"
    local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/${distribution}/${architecture}"
    local keyring=/usr/share/keyrings/cuda-archive-keyring.gpg
    local work_dir packages package_names

    case "$mode" in
        disabled)
            rm -f "$source_file" "$modern_source_file"
            apt-get update
            return
            ;;
        public|dcgm|dcgm_nccl) ;;
        *)
            echo "ERROR: unsupported CUDA APT repository mode: $mode" >&2
            return 1
            ;;
    esac

    if [[ "$mode" != public ]] &&
       ! dpkg --compare-versions "$(dpkg-query -W -f='${Version}' apt)" ge 3.2; then
        echo "ERROR: Filtered CUDA repository requires APT 3.2 or newer for Include filtering." >&2
        return 1
    fi

    if [[ "$mode" != public ]]; then
        rm -f "$source_file" "$modern_source_file"
        apt-get update
    fi

    work_dir=$(mktemp -d)
    trap 'rc=$?; if [[ "$mode" != public && "$rc" -ne 0 ]]; then rm -f "$source_file" "$modern_source_file"; fi; rm -rf "$work_dir"; exit "$rc"' EXIT
    wget -O "$work_dir/cuda-keyring.deb" "${repo_url}/cuda-keyring_1.1-1_all.deb"
    apt install -y "$work_dir/cuda-keyring.deb"
    rm -f "$source_file" "$modern_source_file"

    if [[ "$mode" == public ]]; then
        printf 'deb [signed-by=%s] %s/ /\n' "$keyring" "$repo_url" > "$source_file"
    else
        # Isolated indexes keep the unrestricted source out of installation
        # transactions while the exact package allowlist is being discovered.
        mkdir -p "$work_dir/lists/partial"
        printf 'deb [signed-by=%s] %s/ /\n' "$keyring" "$repo_url" > "$work_dir/cuda.list"
        local -a apt_options=(
            -o "Dir::Etc::sourcelist=$work_dir/cuda.list"
            -o "Dir::Etc::sourceparts=-"
            -o "Dir::State::lists=$work_dir/lists"
            -o "Dir::Cache::pkgcache=$work_dir/pkgcache.bin"
            -o "Dir::Cache::srcpkgcache=$work_dir/srcpkgcache.bin"
        )
        apt-get "${apt_options[@]}" -o APT::Update::Error-Mode=any update
        package_names=$(apt-cache "${apt_options[@]}" pkgnames)
        packages=$(awk '/^datacenter-gpu-manager-/ || /^libdcgm([0-9]+)?(-[a-z0-9-]+)?$/ || /^(dcgmi|nv-hostengine)$/' \
            <<< "$package_names" | sort -u | paste -sd ',')
        if [[ -z "$packages" ]]; then
            echo "ERROR: no DCGM packages found in $repo_url" >&2
            return 1
        fi
        if [[ "$mode" == dcgm_nccl ]]; then
            local package
            for package in libnccl2 libnccl-dev; do
                if ! grep -Fxq "$package" <<< "$package_names"; then
                    echo "ERROR: required NCCL package $package is missing from $repo_url" >&2
                    return 1
                fi
            done
            packages+=",libnccl2,libnccl-dev"
        fi
        printf 'deb [signed-by=%s include=%s] %s/ /\n' "$keyring" "$packages" "$repo_url" > "$source_file"
    fi
    apt-get update
)

install_local_repository() {
    local kind=$1 metadata=$2
    local repo_file repo_path repo_package key_pattern inventory package status
    local -a obsolete_repos=()
    repo_file=$(jq -er '.driver.repo_file' <<< "$metadata")
    repo_path="${TOP_DIR}/internal_bits/${repo_file}"
    verify_checksum "$repo_path" "$(jq -er '.driver.sha256' <<< "$metadata")"
    repo_package=$(dpkg-deb -f "$repo_path" Package)
    case "$kind:$repo_package" in
        nvidia:nvidia-driver-local-repo-*) key_pattern=nvidia-driver-local- ;;
        cuda:cuda-repo-*-local) key_pattern=cuda- ;;
        *) echo "ERROR: unexpected ${kind^^} repository package: $repo_package" >&2; return 1 ;;
    esac

    if [[ "$kind" == nvidia && "$refresh" == true ]]; then
        inventory=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n')
        while IFS=$'\t' read -r package status; do
            if [[ "$package" == nvidia-driver-local-repo-* &&
                  "${package%%:*}" != "$repo_package" && "$status" != not-installed ]]; then
                obsolete_repos+=("$package")
            fi
        done <<< "$inventory"
    fi

    # Supplied repositories can change payload without changing their DEB version.
    apt-get install -y --reinstall "$repo_path"
    install -d /usr/share/keyrings
    install -m 0644 /var/"$repo_package"/"$key_pattern"*-keyring.gpg /usr/share/keyrings/
    if [[ "$kind" == nvidia ]]; then
        cat > /etc/apt/preferences.d/00-nvidia-prefer <<'EOF'
Package: *
Pin: origin ""
Pin-Priority: 1001
EOF
    fi
    if [[ ${#obsolete_repos[@]} -gt 0 ]]; then
        echo "Removing superseded NVIDIA local repositories: ${obsolete_repos[*]}"
        apt-get purge -y -- "${obsolete_repos[@]}"
    fi
    apt-get update
}

configure_nvidia_repositories() (
    set -euo pipefail

    source "${UTILS_DIR}/utilities.sh"

    refresh=false
    if [[ $# -eq 1 && "$1" == --refresh ]]; then
        refresh=true
    elif [[ $# -ne 0 ]]; then
        echo "Usage: $0 [--refresh]" >&2
        exit 1
    fi
    [[ "$DISTRIBUTION" == ubuntu* ]] || { echo 'Requires Ubuntu.' >&2; exit 1; }

    cuda_metadata=$(get_component_config cuda)
    cuda_distribution=$(jq -er '.driver.distribution' <<< "$cuda_metadata")
    cuda_source=$(jq -r '.driver.source // "public"' <<< "$cuda_metadata")
    if [[ "$ARCHITECTURE" == aarch64 ]]; then
        cuda_architecture=sbsa
    else
        cuda_architecture=x86_64
    fi

    repo_mode=public
    if [[ "$cuda_source" == private ]]; then
        repo_mode=dcgm
        if [[ "$DISTRIBUTION" == ubuntu26.04 &&
              $(get_component_config nccl | jq -r '.source // "public"') == public ]]; then
            repo_mode=dcgm_nccl
        fi
    fi
    configure_cuda_online_repo "$cuda_distribution" "$cuda_architecture" "$repo_mode"
    if [[ "$cuda_source" == private ]]; then
        install_local_repository cuda "$cuda_metadata"
    fi

    if [[ "$SKU" != NCv6 ]]; then
        nvidia_metadata=$(get_component_config nvidia)
        if _is_mrc_network || [[ $(jq -r '.driver.source // "public"' <<< "$nvidia_metadata") == private ]]; then
            install_local_repository nvidia "$nvidia_metadata"
        fi
    fi
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    configure_nvidia_repositories "$@"
fi
