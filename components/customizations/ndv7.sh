#!/bin/bash
set -ex

# Place NDv7 customizations under /opt/microsoft/ndv7
mkdir -p /opt/microsoft/ndv7

## load nvidia-peermem module
modprobe nvidia-peermem

# NVIDIA asked for NCCL jobs on VR NVL72 to set each GPU's NVLink-C2C
# bandwidth to its CPU in a topology file until an NCCL fix ships. Without a
# topology file NCCL takes it from NVML: 63423 MB/s per link, 7 links.
C2C_BW=31711    # MB/s per link
C2C_COUNT=7     # links per GPU
TOPO_FILE=/opt/microsoft/ndv7/topo.xml

# The file lists each GPU under its sysfs NUMA node with the C2C bandwidth. It
# is generated at boot because GPU NUMA placement differs between hosts. NCCL
# detects the rest. NICs are left out so NCCL_IB_HCA can set rails and planes;
# NCCL fails init if a file's rail/plane values differ from NCCL_IB_HCA. The
# PCI link attributes are needed when NCCL builds a topology before filling in
# other ranks' GPUs (for example with NCCL_IB_HCA rails).
write_topo_file() {
    local -
    set +x
    local dev numa busid tmp
    local -A gpus=()
    for dev in /sys/bus/pci/devices/*; do
        [[ $(<"$dev/vendor") == 0x10de && $(<"$dev/class") == 0x0302* ]] || continue
        numa=$(<"$dev/numa_node")
        if (( numa < 0 )); then
            echo "GPU ${dev##*/} has no NUMA node; not writing $1" >&2
            return 1
        fi
        gpus[$numa]+="${dev##*/} "
    done
    if (( ${#gpus[@]} == 0 )); then
        echo "No NVIDIA GPU found; not writing $1" >&2
        return 1
    fi

    tmp=$(mktemp "$1.XXXXXX")
    {
        echo '<system version="1">'
        for numa in $(printf '%s\n' "${!gpus[@]}" | sort -n); do
            echo "  <cpu numaid=\"$numa\">"
            for busid in ${gpus[$numa]}; do
                dev=/sys/bus/pci/devices/$busid
                printf '    <pci busid="%s" class="%s" vendor="%s" device="%s" subsystem_vendor="%s" subsystem_device="%s" link_speed="%s" link_width="%s">\n' \
                    "$busid" "$(<"$dev/class")" "$(<"$dev/vendor")" "$(<"$dev/device")" \
                    "$(<"$dev/subsystem_vendor")" "$(<"$dev/subsystem_device")" \
                    "$(<"$dev/current_link_speed")" "$(<"$dev/current_link_width")"
                echo "      <gpu>"
                echo "        <c2c bw=\"$C2C_BW\" count=\"$C2C_COUNT\"/>"
                echo "      </gpu>"
                echo "    </pci>"
            done
            echo "  </cpu>"
        done
        echo '</system>'
    } > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$1"
    echo "Wrote $1"
}
write_topo_file "$TOPO_FILE"

## Set NCCL configuration file for NDv7
cat > /etc/nccl.conf <<EOF
NCCL_TOPO_FILE=$TOPO_FILE
EOF
