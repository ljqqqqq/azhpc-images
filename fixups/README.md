# Ubuntu 26.04 VR200 in-place upgrade

`upgrade_ubuntu2604_vr200.sh` updates an existing Ubuntu 26.04 arm64 NVIDIA
VR200 HPC image (`TARGET_NODE_TYPE=azure_vm_regular`) using
`u26_vr200_internal_1_0_0.tar.gz` and the matching entries in `versions.json`.
It requires the running kernel's headers and an existing `mpi/hpcx` module.

| Component | Target from the supplied archive |
| --- | --- |
| NVIDIA driver | 620.62-1ubuntu1 |
| CUDA toolkit | 13.5.0-1 |
| IMEX | 2.0.0.rel47-1 |
| DOCA OFED | 3.3.3-021000 |
| NCCL | 2.32.4gr100+1.0.1-1+cuda13.5 |
| nvbandwidth | nvbandwidth_main_0.10_v6 |

This is an APT in-place upgrade. It does not purge component packages, explicitly
remove DKMS modules, or run a blanket OS/kernel upgrade. Superseded NVIDIA driver
local-repository registration packages are purged after the supplied repository
is installed; its contents are reinstalled even if its package version is unchanged.
Parallel CUDA installations
and old versioned binaries can remain on disk. APT may replace or remove
conflicting packages as required to install the new component stack. Modified
dpkg conffiles use `--force-confnew`; UCF-managed settings use
`UCF_FORCE_CONFFNEW=1`, so package configuration follows the new payload.
DCGM, HPC-X, NVSHMEM, and other HPC components are not explicitly upgraded,
including the NVSHMEM archive bundled with the inputs; dependency changes are
recorded in the before/after package inventories.

## Execution order

1. Check the platform, all six required private input files and SHA256 hashes,
   running-kernel headers, and inherited HPC-X MPI/SHARP/UCX paths.
2. Save package inventory, holds, and the original `policy-rc.d`, if present.
   Temporarily release holds on target component families and suppress
   maintainer-script service restarts with `policy-rc.d`.
3. Call `components/install_doca.sh` to upgrade DOCA OFED and its dependencies
   with `apt-get -y install doca-ofed`, without an explicit package version.
   Record the actual installed version; APT selects the candidate from configured
   repositories. The supplied DOCA repository contains `3.3.3-021000`.
4. Reinstall the local CUDA repository package: its contents changed even
   though the filename and Debian version stayed the same.
5. Run `vr200_refresh/refresh_nvidia_repo.sh` to reinstall the supplied NVIDIA
   driver repository and keep only that repository registration package, then
   refresh APT indexes. Save output as `upgrade/nvidia-repo.log`.
   Call `components/install_nvidiagpudriver.sh` to upgrade the driver, CUDA and
   IMEX. This also rebuilds CUDA samples and GDRCopy using existing metadata.
6. Call `components/install_nccl.sh` to upgrade NCCL and rebuild the RDMA SHARP
   plugin and nccl-tests against the inherited HPC-X. Existing temporary clone
   directories are saved and restored; `/opt/nccl-tests` and
   `/usr/local/nccl-rdma-sharp-plugins` are replaced as whole directories.
7. Call `components/install_nvbandwidth_tool.sh` to install the private binary
   and switch its active symlink in a fresh `/opt/nvidia/nvbandwidth` directory.
   Old installation backups are deleted when the upgrade succeeds.
8. Restore `policy-rc.d` and holds, then refresh the linker cache and initramfs.
9. Run `vr200_refresh/remove_nolpi.sh` to remove `irqchip.gicv3_nolpi` from
   `/etc/default/grub` and `/etc/default/grub.d/*.cfg`, preserving other boot
   arguments. Run `update-grub` and reject generated kernel entries that still
   contain the parameter. Save output as `upgrade/remove-nolpi.log` in the build
   evidence. The change takes effect on the subsequent reboot.
10. Run `vr200_refresh/verify_versions.sh`. Check exact package versions, NVIDIA
    and OFED DKMS versions for the running kernel, on-disk NVIDIA module version,
    nvbandwidth checksum, and APT/dpkg package health. Save the final inventory.
    DOCA installation does not specify a version, but verification requires the
    installed `doca-ofed` version to equal `package_version` in `versions.json`
    (currently `3.3.3-021000`). The OFED DKMS versions must match its installed
    dependencies. DKMS accepts `installed` with the benign
    `(Original modules exist)` suffix, while other warnings or states fail.

Each installer runs in an isolated work directory because the driver installer
cleans files from its current directory. Public repositories, CUDA samples,
GDRCopy, plugin/test sources and build dependencies are still required; this
is not an offline upgrade.

## Temporary installation state

`vr200_refresh/preserve_settings.sh` manages only the temporary service-start
policy and package holds. An existing `policy-rc.d` file or symlink is restored
with its original metadata; if it was absent, the temporary policy is removed.
Original holds are restored for packages still installed. Component configuration,
including modprobe options, CUDA environment, RDMA settings, library paths and APT
pins, is left as written by the package and component installers. There is no
component-config snapshot or restoration, regardless of package ownership.

Service unit files, drop-ins and enablement are left to the existing component
installers. The helper does not snapshot or restore service links, aliases or
masks, and does not unmask services. An installer attempting to enable an
already-masked service can therefore fail with systemd's normal error.

The wrapper suppresses service starts through `policy-rc.d` and needrestart's
list-only mode until reboot. Loaded GPU/RDMA modules are not replaced in the
running kernel by this wrapper.

Package-managed binaries, repository registrations/keyrings, component-version
entries and rebuilt test/plugin artifacts change as part of the upgrade.
New package defaults and vendor maintainer-script behavior still require
validation on the actual base image; this wrapper is not a full filesystem
or configuration rollback mechanism.

## Packer

```text
REFRESH_MODE=true
REFRESH_BASE_IMAGE_ID=<previous HPC SIG image version resource ID>
SKIP_PREREQUISITES=true
EXTRA_PROVISION_SCRIPT=fixups/upgrade_ubuntu2604_vr200.sh
```

Keep `skip_hpc=false` and validation enabled. `SKIP_PREREQUISITES=true` is required
for this use case to retain the inherited kernel and avoid the earlier system
package update step. That setting also skips Packer's generic component-version
detector; the called component installers update their own manifest entries.
The generic detector now follows the extra script when it is enabled.

Either configure the normal internal-bits blob download, which now also works
in refresh mode, or stage the supplied local archive before starting Packer:

```powershell
tar -xzf "C:\Users\ljiaqi\Downloads\u26_vr200_internal_1_0_0.tar.gz" -C "C:\Repo\hpcimagebuild\jq-official\azhpc-images"
```

For locally staged bits, leave `INTERNAL_BITS_CONTAINER_NAME` and
`INTERNAL_BITS_BLOB_NAME` unset/`None`. Packer uploads `internal_bits/` with the
repository and then removes local staging. These files are ignored by Git;
stage them again before another local build.

Packer performs the final reboot, configured tests, evidence export, and image
capture. Upgrade inventories, installer logs and version checks are included
under `/var/tmp/azhpc-image-evidence/<image-version>/upgrade/` in the normal
build evidence archive. A failed provisioner stops before the normal evidence
export, so retrieve its reports from the failed build VM if retained.

## Direct invocation on the Linux build VM

```bash
sudo bash fixups/upgrade_ubuntu2604_vr200.sh /path/to/u26_vr200_internal_1_0_0.tar.gz
```

Omit the argument when `internal_bits/` is already staged. Direct reports default
to `/var/tmp/azhpc-image-evidence/vr200-refresh/upgrade/`. Reboot before validating
the loaded driver, IMEX/persistence services, RDMA, NCCL collectives and
nvbandwidth on the target hardware. The wrapper's checks run before reboot and
do not establish runtime compatibility with inherited HPC-X/DCGM/NVSHMEM.

On failure, the exit handler attempts to restore `policy-rc.d` and holds and
retains the work directory for diagnosis. If the NCCL installer fails, the old
nccl-tests and RDMA SHARP plugin directories are restored. If the nvbandwidth
installer fails, its old directory is restored. Completed package upgrades and
successful directory replacements are not rolled back; discard
the failed build VM and rebuild from the base image for image delivery.

Run the mock regression checks on Linux (no system package installation):

```bash
python3 fixups/vr200_refresh/test_upgrade.py
```
