#!/bin/bash
set -e

# Hyper-V KVP is an Azure VM platform integration. Bare-metal images do not
# expose the Hyper-V KVP device and do not need its daemon or udev rules.
if [[ "${TARGET_NODE_TYPE:-azure_vm_regular}" != azure_vm_* ]]; then
    exit 0
fi

if [[ "$DISTRIBUTION" == ubuntu* ]]; then
    apt-get install -y linux-cloud-tools-common
    kvp_service=hv-kvp-daemon.service
else
    dnf install -y hypervkvpd
    kvp_service=hypervkvpd.service
fi

# Use the distro-native daemon when the Hyper-V KVP device appears.
cat > /etc/udev/rules.d/99-hyperv-kvp.rules <<EOF
SUBSYSTEM=="misc", KERNEL=="vmbus!hv_kvp", TAG+="systemd", ENV{SYSTEMD_WANTS}+="${kvp_service}"
EOF

systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger
