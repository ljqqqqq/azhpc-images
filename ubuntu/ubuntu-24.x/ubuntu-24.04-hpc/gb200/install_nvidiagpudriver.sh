#!/bin/bash
############################################################################
# @Brief   : Installs NVIDIA GPU driver and CUDA toolkit on Ubuntu 24.04.
# @Details : This script installs the NVIDIA GPU driver and CUDA toolkit on
#            Ubuntu 24.04 using the package manager. It also configures the
#            NVIDIA persistence daemon and IMEX service.
# @Usage   : Run this script in the VM to install the NVIDIA GPU driver and
#            CUDA toolkit.
# @Args    : None
############################################################################

set -ex
source ${COMMON_DIR}/utilities.sh
cuda_metadata=$(get_component_config "cuda")
cuda_version=$(jq -r '.driver.version' <<< $cuda_metadata)
cuda_keyring=$(jq -r '.driver.keyring' <<< $cuda_metadata)
cuda_download_url=$(jq -r '.driver.url' <<< $cuda_metadata)
cuda_file=$(basename ${cuda_download_url})

# Dependency for kernel build packages
apt install -y gcc dkms make cmake build-essential

# Using package manager installation
wget $cuda_download_url
dpkg -i $cuda_file
curl -fsSL $cuda_keyring | gpg --batch --yes --dearmor -o /usr/share/keyrings/cuda-archive-keyring.gpg

# Pin the repository to prefer the local repository
cat <<EOF > /etc/apt/preferences.d/00-nvidia-prefer
Package: *
Pin: origin ""
Pin-Priority: 1001
EOF

apt-get update
apt-get -y install cuda-toolkit-$cuda_version

# Set CUDA related environment variables to /etc/bash.bashrc
echo 'export CUDA_HOME=/usr/local/cuda' | tee -a /etc/profile
echo 'export PATH=$CUDA_HOME/bin:$PATH' | tee -a /etc/profile
echo 'export LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH' | tee -a /etc/profile

# Install NVIDIA GPU driver
nvidia_gpu_driver_metadata=$(get_component_config "nvidia")
nvidia_gpu_driver_major_version=$(jq -r '.driver.major_version' <<< $nvidia_gpu_driver_metadata)
nvidia_gpu_driver_version=$(jq -r '.driver.version' <<< $nvidia_gpu_driver_metadata)
nvidia_gpu_driver_download_url=$(jq -r '.driver.url' <<< $nvidia_gpu_driver_metadata)
nvidia_gpu_driver_file=$(basename ${nvidia_gpu_driver_download_url})

# Download and install the NVIDIA GPU driver
# azcopy login --identity
# azcopy copy $nvidia_gpu_driver_download_url ./
# dpkg -i $nvidia_gpu_driver_file
# # Copy the keyring file to the appropriate directory
# distribution=$(. /etc/os-release; echo $ID$VERSION_ID | tr -d '.')
# cp /var/nvidia-driver-local-repo-$distribution-$nvidia_gpu_driver_version/nvidia-driver-local-*-keyring.gpg /usr/share/keyrings/
# # Update the package lists to include the new repository
# apt update

# Install the NVIDIA driver and related packages
apt install nvidia-dkms-$nvidia_gpu_driver_major_version-open nvidia-driver-$nvidia_gpu_driver_major_version-open nvidia-modprobe -y

# remove unused configuration file if the file was created by the NVIDIA driver
rm /etc/modprobe.d/nvidia-graphics-drivers-kms.conf

# Apply nvprofiling settings
echo 'options nvidia NVreg_RestrictProfilingToAdminUsers=0' | tee /etc/modprobe.d/nvprofiling.conf

# Configuring nvidia persistenced daemon
if [ ! -f /etc/systemd/system/nvidia-persistenced.service ]; then
    cat <<EOF > /etc/systemd/system/nvidia-persistenced.service
[Unit]
Description=NVIDIA Persistence Daemon
Wants=syslog.target
 
[Service]
Type=forking
PIDFile=/var/run/nvidia-persistenced/nvidia-persistenced.pid
Restart=always
ExecStart=/usr/bin/nvidia-persistenced --verbose --persistence-mode
ExecStopPost=/bin/rm -rf /var/run/nvidia-persistenced
 
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nvidia-persistenced.service
fi

systemctl restart nvidia-persistenced.service
systemctl status nvidia-persistenced.service
if ! systemctl is-active --quiet nvidia-persistenced.service; then
    echo "nvidia-persistenced service is not running. Exiting."
    exit 1
fi

# Verify the installation
nvidia-smi

# Write the driver versions to the component versions file
nvidia_driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)
$COMMON_DIR/write_component_version.sh "NVIDIA" $nvidia_driver_version
cuda_version=$(source /etc/profile; nvcc --version | grep release | awk '{print $6}' | cut -c2-)
$COMMON_DIR/write_component_version.sh "CUDA" $cuda_version

$UBUNTU_COMMON_DIR/install_gdrcopy.sh

# Install NVIDIA IMEX
apt-get install nvidia-imex-$nvidia_gpu_driver_major_version -y

# Add configuration to /etc/modprobe.d/nvidia.conf
cat <<EOF >> /etc/modprobe.d/nvidia.conf
options nvidia NVreg_CreateImexChannel0=1
EOF

sudo update-initramfs -u -k all

# Configuring nvidia-imex service
systemctl enable nvidia-imex.service

nvidia_imex_version=$(nvidia-imex --version | grep -oP 'IMEX version is: \K[0-9.]+')
$COMMON_DIR/write_component_version.sh "IMEX" $nvidia_imex_version
