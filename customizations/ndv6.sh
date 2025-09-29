#!/bin/bash
set -ex

# Place NDv6 customizations under /opt/microsoft/ndv6
mkdir -p /opt/microsoft/ndv6

# Link the NDv6 topology file into /opt/microsoft/ndv6/
ln -sf /opt/microsoft/ndv6-topo.xml /opt/microsoft/ndv6/topo.xml

## Set NCCL configuration file for NDv6
bash -c "cat > /etc/nccl.conf" <<'EOF'
NCCL_IB_PCI_RELAXED_ORDERING=1
NCCL_TOPO_FILE=/opt/microsoft/ndv6/topo.xml
NCCL_IGNORE_CPU_AFFINITY=1
EOF

## NVIDIA Fabric manager
systemctl enable nvidia-fabricmanager
systemctl start nvidia-fabricmanager
systemctl is-active --quiet nvidia-fabricmanager

error_code=$?
if [ ${error_code} -ne 0 ]
then
    echo "NVIDIA Fabic Manager Inactive!"
    exit ${error_code}
fi

## load nvidia-peermem module
modprobe nvidia-peermem
