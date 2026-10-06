#!/bin/bash
set -ex

source ${UTILS_DIR}/utilities.sh

#
# install rdma_rename with NAME_FIXED option
#
rdma_core_metadata=$(get_component_config "rdma_core")
RDMA_CORE_VERSION=$(jq -r '.version' <<< $rdma_core_metadata)
RDMA_CORE_SHA=$(jq -r '.sha256' <<< $rdma_core_metadata)

TARBALL="v${RDMA_CORE_VERSION}.tar.gz"
RDMA_CORE_DOWNLOAD_URL=https://github.com/linux-rdma/rdma-core/archive/refs/tags/${TARBALL}
download_and_verify ${RDMA_CORE_DOWNLOAD_URL} ${RDMA_CORE_SHA} /tmp

pushd /tmp
mkdir rdma-core && tar -xvf $TARBALL --strip-components=1 -C rdma-core 

pushd rdma-core
EXTRA_CMAKE_FLAGS="-DNO_MAN_PAGES=1 -DNO_PYVERBS=1" bash build.sh
install -m 0755 build/bin/rdma_rename /usr/sbin/rdma_rename_$RDMA_CORE_VERSION
popd
rm -rf rdma-core
popd

#
# setup systemd service
#

cat <<EOF >/usr/sbin/azure_persistent_rdma_naming.sh
#!/bin/bash
set -euo pipefail

rdma_rename=/usr/sbin/rdma_rename_${RDMA_CORE_VERSION}

for command_name in ibdev2netdev ibv_devinfo; do
	command -v "\$command_name" >/dev/null
done

mapfile -t all_devices < <(
	ibdev2netdev -v | sort -V | awk '{print \$2}' | awk 'NF' | awk '!seen[\$0]++'
)

is_mlx5_device() {
	local device=\$1
	local driver
	driver=\$(basename "\$(readlink -f "/sys/class/infiniband/\${device}/device/driver")")
	[[ "\$driver" == "mlx5_core" ]]
}

needs_renaming() {
	local device
	for device in "\${all_devices[@]}"; do
		is_mlx5_device "\$device" || continue
		[[ "\$device" =~ ^mlx5_(ib|an)[0-9]+\$ ]] || return 0
	done
	return 1
}

if [[ "\${1:-}" == "--needs-renaming" ]]; then
	if needs_renaming; then
		exit 0
	fi
	exit 1
fi

next_index() {
	local prefix=\$1
	local max_index=-1
	local dev suffix

	for dev in "\${all_devices[@]}"; do
		suffix=\${dev#\$prefix}
		if [[ "\$dev" == "\$prefix"* && "\$suffix" =~ ^[0-9]+$ && "\$suffix" -gt "\$max_index" ]]; then
			max_index=\$suffix
		fi
	done

	echo \$((max_index + 1))
}

an_index=\$(next_index mlx5_an)
ib_index=\$(next_index mlx5_ib)

for old_device in "\${all_devices[@]}"; do
	is_mlx5_device "\$old_device" || continue

	[[ "\$old_device" =~ ^mlx5_(ib|an)[0-9]+\$ ]] && continue

	link_layer=\$(ibv_devinfo -d \$old_device | sed -n 's/^[\ \t]*link_layer:[\ \t]*\([a-zA-Z]*\)\$/\1/p')
	
	if [ "\$link_layer" = "InfiniBand" ]; then
		
		\$rdma_rename \$old_device NAME_FIXED mlx5_ib\${ib_index}
		ib_index=\$((\$ib_index + 1))
		
	elif [ "\$link_layer" = "Ethernet" ]; then
	
		\$rdma_rename \$old_device NAME_FIXED mlx5_an\${an_index}
		an_index=\$((\$an_index + 1))
		
	else
	
		echo "Unknown link layer '\$link_layer' for \$old_device." >&2
		exit 1
		
	fi
	
done
EOF
chmod 755 /usr/sbin/azure_persistent_rdma_naming.sh

cat <<EOF >/etc/systemd/system/azure_persistent_rdma_naming.service
[Unit]
Description=Azure persistent RDMA naming
After=network.target rdma-hw.target
Wants=rdma-hw.target

[Service]
Type=oneshot
ExecCondition=/usr/sbin/azure_persistent_rdma_naming.sh --needs-renaming
ExecStart=/usr/sbin/azure_persistent_rdma_naming.sh
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/azure_persistent_rdma_naming.timer
[Unit]
Description=Retry Azure persistent RDMA naming

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=azure_persistent_rdma_naming.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable azure_persistent_rdma_naming.service
systemctl enable azure_persistent_rdma_naming.timer
systemctl start azure_persistent_rdma_naming.service
systemctl start azure_persistent_rdma_naming.timer
