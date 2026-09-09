# Ubuntu 26.04 GB200 Image Component List And Note

The following values are the actual tags reported by the first GB200 U26 image.

| Tag | Value |
| --- | --- |
| `ImageVersion` | `2609.09.3907` |
| `Date` | `09/09/2026` |
| `BuildId` | `37898` |
| `CommitID` | `c9fe7f28ef121543abdc39e6c02b3fa470eede2a` |
| `KERNEL` | `7.0.0-1012-azure` |
| `NVIDIA` | `610.57.04` |
| `IMEX` | `610.57.04-1` |
| `CUDA` | `13.3.73` |
| `DOCA` | `3.5.0` |
| `OFED` | `26.07-0.7.7` |
| `HPCX` | `2.25.1` |
| `OMPI` | `5.0.10` |
| `PMIX` | `5.0.11rc1` |
| `NCCL` | `2.30.4-1` |
| `NCCL-RDMA_SHARP_PLUGIN` | `master` |
| `GDRCOPY` | `2.6-1` |
| `NVSHMEM` | `3.7.2-1` |
| `NVLOOM` | `2.0.0` |
| `NVBANDWIDTH` | `0.9` |
| `DCGM` | `1:4.6.1-1` |
| `DOCKER` | `29.1.3` |
| `MOBY_ENGINE` | `29.1.3-0ubuntu4.1` |
| `MPIFILEUTILS` | `0.12` |
| `AZ_HEALTH_CHECKS` | `0.4.5` |
| `MONEO` | `0.3.5` |
| `WAAGENT` | `2.15.0.1` |
| `WAAGENT_EXTENSIONS` | `2.15.0.1` |
| `dynolog` | `1.0.0` |
| `dyno_relay_logger` | `1.0.0` |

## Notes

-  The upstream MDE (Microsoft Defender for Endpoint) installer does not yet recognize Ubuntu 26.04 and wrongly identify it as 18.04, so the image build temporarily downloaded and modified the installer script of MDE and make it accept Ubuntu 26.04 and handle it through the Debian 13-compatible path.
-  NVIDIA computation stack upgrade: upgraded NVIDIA driver `580.167.08` to `610.57.04`, IMEX from `580.167.08-1` to `610.57.04-1`, and CUDA from `13.0` to `13.3`. The reason is that CUDA repo for Ubuntu26.04 only contains cuda-toolkit-13-3, whose compatability matrix indicates driver 610 should be used. 610 is a new feature branch.
- CUDA Samples 13.3 renamed the top-level build output directory from `Samples` to `cpp`; the installer now selects the directory by version and fails with a clear error if the expected output is missing.
- The fixed cargo and rustc version 1.82 are not available in Ubuntu26.04. We kept the fixed-version logic and selected the versions according to the Ubuntu distro version.
- Kernel parameter `iommu.passthrough=1 irqchip.gicv3_nolpi=y arm_smmu_v3.disable_msipolling=1 init_on_alloc=0 net.ifnames=0` is kept for gpu detection and performance tuning. Especially, without `irqchip.gicv3_nolpi=y` GPU cannot be detected with the following error: 

`[   22.977979] NVRM: GPU 0019:01:00.0: Failed to enable MSI-X.
[   22.977999] NVRM: GPU 0019:01:00.0: No interrupts of any type are available. Cannot use this GPU.`
