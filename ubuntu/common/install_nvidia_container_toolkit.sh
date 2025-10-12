#!/bin/bash
set -ex

# Install NVIDIA Container Toolkit
# Reference: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html
# Setting up NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/experimental/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

nvidia_toolkit_version="1.18.0~rc.5-1"

apt-get update
# Install NVIDIA container toolkit and mark NVIDIA packages on hold
sudo apt-get install -y libnvidia-container1=$nvidia_toolkit_version
sudo apt-get install -y libnvidia-container-tools=$nvidia_toolkit_version
sudo apt-get install -y nvidia-container-toolkit-base=$nvidia_toolkit_version
sudo apt-get install -y nvidia-container-toolkit=$nvidia_toolkit_version

apt-mark hold nvidia-container-toolkit
apt-mark hold libnvidia-container-tools
apt-mark hold libnvidia-container1

# Configure NVIDIA Container Toolkit
nvidia-ctk runtime configure --runtime=docker

# Configure containerd to use NVIDIA runtime
mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
nvidia-ctk runtime configure --runtime=containerd --set-as-default
sed -i 's/enable_cdi = false/enable_cdi = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
# sed -i 's/disabled_plugins = \[\]/disabled_plugins = \["cri", "zfs", "aufs", "btrfs", "devmapper"\]/g' /etc/containerd/config.toml

# Remove unwanted repos
rm -f /etc/apt/sources.list.d/nvidia*