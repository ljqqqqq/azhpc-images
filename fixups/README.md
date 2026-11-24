# Ubuntu 26.04 VR200 NVIDIA driver in-place refresh

`upgrade_ubuntu2604_vr200.sh` now updates only NVIDIA driver packages on an
existing Ubuntu 26.04 arm64 VR200 HPC image (`TARGET_NODE_TYPE=azure_vm_regular`).
The driver version, private repository filename and SHA256 come from the VR200
NVIDIA entry in `versions.json` (currently `620.70.10-1ubuntu1`).

The script does not run the full `install_nvidiagpudriver.sh`, which also installs
CUDA, CUDA samples, GDRCopy and standalone IMEX. DOCA/OFED, NCCL, nvbandwidth,
HPC-X, DCGM, NVSHMEM, the OS/kernel, SKU customizations and GRUB arguments are
not refreshed by this entry point. `libnvidia-imex1` is updated as a versioned
driver library; `nvidia-imex-direct` and its service configuration are retained.

## Execution

1. Check the platform, the private driver repository checksum and running-kernel
   headers. Only the driver DEB is required in `internal_bits/`; the other private
   component archives and an HPC-X module are not required.
2. Save the package inventory, original holds and `policy-rc.d`. Release only
   driver-package holds and temporarily suppress maintainer-script service starts.
3. Import the new NVIDIA local repository and keyring, removing superseded NVIDIA
   repository registrations. CUDA and public repository configuration are retained.
4. Simulate the exact-version driver installation with `--no-remove` and
   `--no-install-recommends`. Reject plans that remove a package or install/upgrade
   anything outside the explicit driver package list.
5. Install the driver packages, restore holds and `policy-rc.d`, then refresh
   the linker cache and initramfs.
6. Check the driver package versions, NVIDIA DKMS installation for the running
   kernel, on-disk module version and APT/dpkg health. Update only the NVIDIA
   component record and save the final package inventory.

Reports are written under
`/var/tmp/azhpc-image-evidence/<image-version>/upgrade/`, including
`nvidia-repository.log`, `nvidia-plan.log`, `nvidia.log`, `verify-versions.log`
and before/after package inventories. The script does not reboot or replace
loaded modules; run GPU/RDMA runtime validation after reboot. On failure, temporary
holds and service policy are restored, but completed package changes are not
rolled back. Rebuild a failed image from the base image.

## Packer

Keep the existing extra-provision-script path:

```text
REFRESH_MODE=true
REFRESH_BASE_IMAGE_ID=<previous HPC SIG image version resource ID>
SKIP_PREREQUISITES=true
EXTRA_PROVISION_SCRIPT=fixups/upgrade_ubuntu2604_vr200.sh
```

`SKIP_PREREQUISITES=true` retains the inherited OS/kernel and avoids the generic
system package upgrade. Packer stages `internal_bits/` through the configured
internal-bits blob or a locally staged directory, then performs its normal final
reboot, validation, evidence export and image capture.

For direct invocation with already-staged driver bits:

```bash
sudo bash fixups/upgrade_ubuntu2604_vr200.sh
```

An optional local archive can be supplied as the first argument. Its
`internal_bits/` directory must contain the new driver repository DEB.

The separate SKU customization refresh remains available as
`EXTRA_PROVISION_SCRIPT=fixups/refresh_sku_customizations.sh`.

Run the mock regression checks on Linux (no system package changes):

```bash
python3 fixups/vr200_refresh/test_upgrade.py
```
