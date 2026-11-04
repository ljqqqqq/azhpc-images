#!/bin/bash
set -euo pipefail
: "${TOP_DIR:?Run through upgrade_ubuntu2604_vr200.sh}"
: "${UTILS_DIR:?Run through upgrade_ubuntu2604_vr200.sh}"
: "${AZHPC_IMAGES_TEST_DIR:?Run through upgrade_ubuntu2604_vr200.sh}"

# Reapply image fixes without rerunning hpc-tuning.sh or changing its other
# unrelated sysctl, limits, service or network settings. Hyper-V KVP is out of scope.

# d06adf5 / f0334f4: udev needs $$4 to pass a literal $4 to awk. The base image
# retains the old rule because the upgrade does not rerun hpc-tuning.sh.
cat > /etc/udev/rules.d/90-nfs-readahead.rules <<'EOF'
SUBSYSTEM=="bdi", \
ACTION=="add", \
PROGRAM="/usr/bin/awk -v bdi=$kernel 'BEGIN{ret=1} {if ($$4 == bdi) {ret=0}} END{exit ret}' /proc/fs/nfsfs/volumes", \
ATTR{read_ahead_kb}="15380"
EOF
udevadm control --reload
echo 'Applied NFS read-ahead rule escaping fix.'

# Remove the mask inherited from the base image. Keep the existing systemd
# validation scope, and leave the service's enable/start policy unchanged.
systemctl unmask unattended-upgrades.service
echo 'Removed the unattended-upgrades.service mask.'

# 3f7095c: the driver calls configure_nvidia_persistence.sh, but that script
# creates the unit only if absent. Migrate the existing unit's two paths.
unit=/etc/systemd/system/nvidia-persistenced.service
[[ -f "$unit" ]] || { echo "ERROR: missing persistence unit: ${unit}" >&2; exit 1; }
sed -i --follow-symlinks \
    -e '/^PIDFile=/s|/var/run/nvidia-persistenced/|/run/nvidia-persistenced/|g' \
    -e '/^ExecStopPost=/s|/var/run/nvidia-persistenced|/run/nvidia-persistenced|g' \
    "$unit"
systemctl daemon-reload
echo 'Migrated NVIDIA persistence paths; service is not restarted.'

# f8d98b7 already runs through install_nvidiagpudriver.sh -> install_cuda_samples.sh.
# If an inherited sample still lacks its data, install the PPM assets from the
# same checksum-verified source archive, without recompiling the samples again.
for sample in segmentationTreeThrust radixSortThrust; do
    [[ -x "/usr/local/cuda/samples/${sample}" ]] || {
        echo "ERROR: missing CUDA sample executable after driver install: ${sample}" >&2; exit 1;
    }
done
if [[ ! -s /usr/local/cuda/samples/test.ppm ]]; then
    source "${UTILS_DIR}/utilities.sh"
    cuda_metadata=$(get_component_config cuda)
    samples_version=$(jq -r '.samples.version' <<< "$cuda_metadata")
    samples_checksum=$(jq -r '.samples.sha256' <<< "$cuda_metadata")
    assets_dir=$(mktemp -d "${VR200_STATE_DIR:-/var/tmp}/cuda-sample-assets.XXXXXX")
    trap 'rm -rf -- "$assets_dir"' EXIT
    (
        cd "$assets_dir"
        archive="v${samples_version}.tar.gz"
        download_and_verify "https://github.com/NVIDIA/cuda-samples/archive/refs/tags/${archive}" "$samples_checksum" ''
        tar -xzf "$archive" --wildcards \
            "cuda-samples-${samples_version}/cpp/2_Concepts_and_Techniques/segmentationTreeThrust/data/*.ppm"
        install -m 0644 cuda-samples-*/cpp/2_Concepts_and_Techniques/segmentationTreeThrust/data/*.ppm \
            /usr/local/cuda/samples/
    )
fi
[[ -s /usr/local/cuda/samples/test.ppm ]] || {
    echo 'ERROR: CUDA sample data install did not provide test.ppm.' >&2; exit 1;
}
echo 'CUDA sample executables and segmentationTreeThrust data are present.'

# write_component_version in utils normalizes manifest keys, including inherited
# entries. Deploy the checkout's original tests for direct upgrades as well;
# Packer repeats this copy after its extra-script hook.
install -d /opt/azurehpc/test
cp "${AZHPC_IMAGES_TEST_DIR}/"*.* /opt/azurehpc/test/
echo 'Refreshed VM tests from checkout; original runner and systemd checks retained.'
