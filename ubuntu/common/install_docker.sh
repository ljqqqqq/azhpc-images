#!/bin/bash
set -ex

# Install Moby Engine and CLI
apt-get install -y moby-engine
apt-get install -y moby-cli

$UBUNTU_COMMON_DIR/install_nvidia_container_toolkit.sh

# enable and restart the docker daemon to complete the installation
systemctl enable docker
systemctl restart docker

# status of containerd snapshotter plugins
ctr plugin ls

# Write the docker version to components file
docker_version=$(docker --version | awk -F' ' '{print $3}')
$COMMON_DIR/write_component_version.sh "DOCKER" ${docker_version::-1}

moby_engine_version=$(apt list --installed | grep moby-engine | awk -F' ' '{print $2}')
moby_cli_version=$(apt list --installed | grep moby-cli | awk -F' ' '{print $2}')
moby_runc_version=$(apt list --installed | grep moby-runc | awk -F' ' '{print $2}')
$COMMON_DIR/write_component_version.sh "MOBY_ENGINE" ${moby_engine_version}
$COMMON_DIR/write_component_version.sh "MOBY_CLI" ${moby_cli_version}
$COMMON_DIR/write_component_version.sh "MOBY_RUNC" ${moby_runc_version}