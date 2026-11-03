#!/bin/bash
# Manage only temporary service-start policy and package holds. Component
# configuration is left as written by the package and component installers.
policy_rc_path=/usr/sbin/policy-rc.d

snapshot_image_settings() {
    if [[ -e "$policy_rc_path" || -L "$policy_rc_path" ]]; then
        cp -a -- "$policy_rc_path" "${VR200_STATE_DIR}/original-policy-rc.d"
    fi
    apt-mark showhold | sort > "${VR200_STATE_DIR}/original-holds.txt"
}

prepare_image_settings() {
    local package
    # Temporarily unhold only packages within the component families being
    # upgraded, including already-held OFED/driver dependencies.
    while IFS= read -r package; do
        case "$package" in
            nvidia-container*|libnvidia-container*) continue ;;
            nvidia-*|libnvidia-*|cuda-*|doca-*|mlnx-*|libnccl*|gdrdrv-dkms*|libgdrapi*|gdrcopy*|\
            rdma-core*|libibverbs*|ibverbs-*|librdmacm*|libibumad*|libibmad*|iser-dkms*|isert-dkms*|srp-dkms*)
                apt-mark unhold "$package" ;;
        esac
    done < "${VR200_STATE_DIR}/original-holds.txt"
    # Suppress maintainer-script restarts; preserve the original file/symlink.
    printf '#!/bin/sh\nexit 101\n' > "${VR200_STATE_DIR}/policy-rc.d"
    rm -f -- "$policy_rc_path"
    install -m 0755 "${VR200_STATE_DIR}/policy-rc.d" "$policy_rc_path"
}

restore_image_settings() {
    local package
    local rc=0
    if [[ -e "${VR200_STATE_DIR}/original-policy-rc.d" || -L "${VR200_STATE_DIR}/original-policy-rc.d" ]]; then
        cp -a --remove-destination -- "${VR200_STATE_DIR}/original-policy-rc.d" "$policy_rc_path" || rc=1
    else
        rm -f -- "$policy_rc_path" || rc=1
    fi
    apt-mark showhold | sort > "${VR200_STATE_DIR}/current-holds.txt" || rc=1
    while IFS= read -r package; do apt-mark unhold "$package" || rc=1; done < <(
        comm -13 "${VR200_STATE_DIR}/original-holds.txt" "${VR200_STATE_DIR}/current-holds.txt")
    while IFS= read -r package; do
        if [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) == installed ]]; then
            apt-mark hold "$package" || rc=1
        else
            echo "Not restoring hold on removed package: ${package}"
        fi
    done < <(
        comm -23 "${VR200_STATE_DIR}/original-holds.txt" "${VR200_STATE_DIR}/current-holds.txt")
    return "$rc"
}
