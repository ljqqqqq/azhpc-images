# Build 40806: private NVIDIA/CUDA package audit

Source build: [40806 / 2611.11.4690](https://dev.azure.com/hpc-platform-team/hpc-image-val/_build/results?buildId=40806).
Code revision: `2d21a9c0ed57d90e56fa96e486928cc2b2fd2ea4`.
Inputs: `u26_vr200_internal_1_0_0_DEV2.tar.gz`; the comparison versions below are from its private CUDA `Packages` index.
Installed versions are from the build evidence `build/packages.tsv`; confirmed download sources are from `upgrade/nvidia.log`.

## Confirmed public NVIDIA/IMEX downloads

These five packages were fetched from `https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/sbsa` during this build. Their private counterparts have the same version numbers, so a version-only verification could not detect the mixed payloads. Reinstall them from the supplied private DEBs.

| Package | Installed / private target |
| --- | --- |
| `nvidia-dkms-open` | `620.70.06-1ubuntu1` |
| `nvidia-modprobe` | `620.70.06-1ubuntu1` |
| `nvidia-persistenced` | `620.70.06-1ubuntu1` |
| `nvidia-headless-open` | `620.70.06-1ubuntu1` |
| `nvidia-imex-direct` | `2.0.0.rel49-1` |

The same transaction fetched seven other driver packages from the private driver repository: `nvidia-headless-no-dkms-open`, `nvidia-kernel-common`, `nvidia-firmware`, `libnvidia-compute`, `libnvidia-gpucomp`, `libnvidia-cfg1`, and `libnvidia-imex1`. These already-private packages are outside the repair target list.

## CUDA package coverage

The private CUDA repository contains 75 package records. 64 are already installed in this image: **54 differ from the private comparison version**, and **10 have the same version**. These version comparisons do not establish which repository originally installed the payload. This repair leaves these 64 packages unchanged; they are not classified as public downloads without source evidence.

| Package | Installed in 2611.11.4690 | DEV2 private comparison | Repair |
| --- | --- | --- | --- |
| `cccl-13-5` | `13.3.5.0.2-1` | `13.3.5.0.6-1` | Unchanged |
| `cuda-command-line-tools-13-5` | `13.5.0-1` | `13.5.0-1` | Unchanged |
| `cuda-compiler-13-5` | `13.5.0-1` | `13.5.0-1` | Unchanged |
| `cuda-crt-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-ctadvisor-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-cudart-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-cudart-dev-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-culibos-dev-13-5` | `13.5.18-1` | `13.5.25-1` | Unchanged |
| `cuda-cuobjdump-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-cupti-13-5` | `13.5.18-1` | `13.5.25-1` | Unchanged |
| `cuda-cupti-dev-13-5` | `13.5.18-1` | `13.5.25-1` | Unchanged |
| `cuda-cuxxfilt-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-driver-dev-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-gdb-13-5` | `13.5.18-1` | `13.5.25-1` | Unchanged |
| `cuda-libraries-13-5` | `13.5.0-1` | `13.5.0-1` | Unchanged |
| `cuda-libraries-dev-13-5` | `13.5.0-1` | `13.5.0-1` | Unchanged |
| `cuda-nsight-compute-13-5` | `13.5.0-1` | `13.5.0-1` | Unchanged |
| `cuda-nsight-systems-13-5` | `13.5.0-1` | `13.5.0-1` | Unchanged |
| `cuda-nvcc-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-nvdisasm-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-nvml-dev-13-5` | `13.5.37-1` | `13.5.37-1` | Unchanged |
| `cuda-nvprune-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-nvrtc-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-nvrtc-dev-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-nvtx-13-5` | `13.5.17-1` | `13.5.25-1` | Unchanged |
| `cuda-profiler-api-13-5` | `13.5.18-1` | `13.5.25-1` | Unchanged |
| `cuda-sandbox-dev-13-5` | `13.5.18-1` | `13.5.25-1` | Unchanged |
| `cuda-sanitizer-13-5` | `13.5.18-1` | `13.5.25-1` | Unchanged |
| `cuda-tileiras-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-toolkit-13-5-config-common` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-toolkit-13-5` | `13.5.0-1` | `13.5.0-1` | Unchanged |
| `cuda-toolkit-13-config-common` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-toolkit-config-common` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `cuda-tools-13-5` | `13.5.0-1` | `13.5.0-1` | Unchanged |
| `cuda-visual-tools-13-5` | `13.5.0-1` | `13.5.0-1` | Unchanged |
| `gds-tools-13-5` | `1.20.0.102-1` | `1.20.0.107-1` | Unchanged |
| `libcublas-13-5` | `13.9.0.1-1` | `13.10.0.20-1` | Unchanged |
| `libcublas-dev-13-5` | `13.9.0.1-1` | `13.10.0.20-1` | Unchanged |
| `libcudla-13-5` | `13.5.18-1` | `13.5.25-1` | Unchanged |
| `libcudla-dev-13-5` | `13.5.18-1` | `13.5.25-1` | Unchanged |
| `libcufft-13-5` | `12.5.0.7-1` | `12.5.0.14-1` | Unchanged |
| `libcufft-dev-13-5` | `12.5.0.7-1` | `12.5.0.14-1` | Unchanged |
| `libcufile-13-5` | `1.20.0.102-1` | `1.20.0.107-1` | Unchanged |
| `libcufile-dev-13-5` | `1.20.0.102-1` | `1.20.0.107-1` | Unchanged |
| `libcuobjclient-13-5` | `1.4.0.102-1` | `1.4.0.107-1` | Unchanged |
| `libcuobjclient-dev-13-5` | `1.4.0.102-1` | `1.4.0.107-1` | Unchanged |
| `libcurand-13-5` | `10.4.5.18-1` | `10.4.5.25-1` | Unchanged |
| `libcurand-dev-13-5` | `10.4.5.18-1` | `10.4.5.25-1` | Unchanged |
| `libcusolver-13-5` | `12.3.5.15-1` | `12.4.1.2-1` | Unchanged |
| `libcusolver-dev-13-5` | `12.3.5.15-1` | `12.4.1.2-1` | Unchanged |
| `libcusparse-13-5` | `12.9.2.2-1` | `12.9.4.2-1` | Unchanged |
| `libcusparse-dev-13-5` | `12.9.2.2-1` | `12.9.4.2-1` | Unchanged |
| `libnpp-13-5` | `13.2.0.86-1` | `13.2.0.93-1` | Unchanged |
| `libnpp-dev-13-5` | `13.2.0.86-1` | `13.2.0.93-1` | Unchanged |
| `libnvfatbin-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `libnvfatbin-dev-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `libnvjitlink-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `libnvjitlink-dev-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `libnvjpeg-13-5` | `13.3.0.36-1` | `13.3.2.43-1` | Unchanged |
| `libnvjpeg-dev-13-5` | `13.3.0.36-1` | `13.3.2.43-1` | Unchanged |
| `libnvptxcompiler-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `libnvvm-13-5` | `13.5.18-1` | `13.5.37-1` | Unchanged |
| `nsight-compute-2026.4.0` | `2026.4.0.7-1` | `2026.4.0.10-1` | Unchanged |
| `nsight-systems-2026.5.2` | `2026.5.2.260-265238937671v0` | `2026.5.2.323-265239015215v0` | Unchanged |

## Cause and repair scope

The old entry point installed the exact driver metapackage versions and `cuda-toolkit-13-5=13.5.0-1`, while the unrestricted public CUDA source was enabled. APT could choose a public copy of the exact driver version. Installing an unchanged toolkit metapackage did not force its already-satisfied dependencies to move to the newer private versions.

Use `fixups/upgrade_ubuntu2604_vr200_private_nvidia_cuda.sh` with this image as the base and the same DEV2 inputs. It selects only the five public downloads listed above, requires the current versions to match that source evidence, and prefers a private DEB at the same installed version even if a newer private version is available. The current DEV2 inputs provide same-version private replacements for all five. Only the two signed private repositories are visible to the component transaction, using fresh package indexes and an empty archive cache. The simulation rejects any change outside the five selected packages, and the post-install check also verifies unchanged non-target package versions.

The audit distinguishes observed public downloads from stale versions and equal-version packages with unproven provenance. DCGM and NVIDIA container toolkit use their own sources; they are outside the two private repository payloads and this repair does not reinstall them. DOCA, NCCL, nvbandwidth, the kernel and test/plugin builds are not rerun by this separate entry point.
