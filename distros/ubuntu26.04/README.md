# Ubuntu 26.04 GB200 镜像说明 / Image Notes

版本基线 / Baseline: `7c720f4` (`add u26 gb200`, 2026-09-03)

## 基本信息 / Scope

| 项目 / Item | 中文 | English |
| --- | --- | --- |
| 操作系统 / OS | Ubuntu 26.04 | Ubuntu 26.04 |
| GPU SKU | NVIDIA GB200 | NVIDIA GB200 |
| 架构 / Architecture | aarch64 | aarch64 |
| 内核 / Kernel | `linux-azure-7.0` | `linux-azure-7.0` |
| AMD GPU | 暂不支持 | Not supported yet |

## 软件与版本 / Software and Versions

| 组件 / Component | 版本 / Version | 中文说明 | English description |
| --- | --- | --- | --- |
| NVIDIA driver | `610.57.04` | NVIDIA GPU 驱动 | NVIDIA GPU driver |
| NVIDIA IMEX | `610.57.04-1` | GB200 多节点 GPU 内存交换服务 | Multi-node GPU memory exchange service for GB200 |
| CUDA toolkit | `13.3` | 使用 `ubuntu2604` 软件源 | Uses the `ubuntu2604` repository |
| DOCA host | `3.5.0` | aarch64 DOCA-OFED，包目标为 `ubuntu2604_arm64` | aarch64 DOCA-OFED package for `ubuntu2604_arm64` |
| HPC-X | `2.51` artifact | CUDA 13 aarch64 制品，提供 MPI 通信栈 | CUDA 13 aarch64 artifact providing the MPI stack |
| NCCL | `2.30.4-1` | NVIDIA 集合通信库 | NVIDIA collective communication library |
| GDRCopy | `2.6-1` | 从提交 `93c606bbcaa10457cbbab93163aa446d902b983d` 编译 | Built from commit `93c606bbcaa10457cbbab93163aa446d902b983d` |
| DCGM | `1:4.6.1-1` | GPU 管理和监控 | GPU management and monitoring |
| NVSHMEM | 构建时确定 / Build-time | 安装 `libnvshmem3-cuda-13`，记录实际包版本 | Installs `libnvshmem3-cuda-13` and records the resolved package version |
| NVLOOM | `2.0.0` | GB200 专属，按 CUDA architecture `100` 编译 | GB200-specific, built for CUDA architecture `100` |
| NVBandwidth | `0.9` | GB200 专属，启用多节点支持 | GB200-specific with multi-node support enabled |
| mpifileutils | `0.12` | 并行文件工具 | Parallel file utilities |
| Docker | 软件源版本 / Repository version | 容器运行时 | Container runtime |
| AzCopy | `10.32.3` | Azure Storage 数据传输工具 | Azure Storage data transfer tool |
| Azure Linux Agent | 软件源版本 / Repository version | Azure VM 代理 | Azure VM agent |
| AZNFS | 软件源版本 / Repository version | Azure NFS 挂载助手 | Azure NFS mount helper |
| Health checks and monitoring | 仓库脚本版本 / Repository scripts | 健康检查、诊断和监控工具 | Health-check, diagnostic, and monitoring tools |

## GB200 验证项 / GB200 Validation

| 类别 / Category | 检查项 / Checks |
| --- | --- |
| 组件 / Components | NVIDIA driver, GDRCopy, CUDA, NCCL, Docker, DCGM, NVLink, NVBandwidth, mpifileutils, NVLOOM |
| 服务和配置 / Services and configuration | NVIDIA persistence, NVIDIA IMEX, SUNRPC TCP settings, persistent RDMA interface naming, SKU customization |

## 注意事项 / Notes

| 中文 | English |
| --- | --- |
| HPC-X aarch64 元数据不一致：`version` 字段为 `2.25.1`，URL 和压缩包名称指向 `2.51`。当前预期制品为 `2.51`，依赖该字段做版本上报或自动化判断前应先修正。 | HPC-X aarch64 metadata is inconsistent: the `version` field is `2.25.1`, while the URL and archive name point to `2.51`. The intended artifact is currently `2.51`; fix the field before using it for reporting or automation. |
| Lustre 暂不在 Ubuntu 26.04 测试矩阵中；共享安装脚本会跳过 kernel 7.0，直到 AMLFS 发布兼容包。 | Lustre is not currently in the Ubuntu 26.04 test matrix; the shared installer skips kernel 7.0 until AMLFS publishes compatible packages. |
| GDRCopy 为 best-effort 支持，从固定提交编译；生成的 Debian 包后缀必须为 `Ubuntu26_04`。 | GDRCopy support is best-effort and built from a pinned commit; the generated Debian package suffix must be `Ubuntu26_04`. |
| NVLOOM 从源码编译，依赖 HPC-X、CUDA、CMake 和 Boost。 | NVLOOM is built from source and depends on HPC-X, CUDA, CMake, and Boost. |
| x86_64 路径使用不同的 NVIDIA、CUDA、DOCA 和 DCGM 版本，不能套用于 aarch64 GB200。 | The x86_64 path uses different NVIDIA, CUDA, DOCA, and DCGM versions and must not be applied to aarch64 GB200. |
| `GPU=AMD` 会直接失败；ROCm、RCCL、AMD HPC-X 元数据和测试矩阵尚未补齐。 | `GPU=AMD` fails immediately; ROCm, RCCL, AMD HPC-X metadata, and the AMD test matrix are not available yet. |

镜像构建以 `versions.json` 为准。 / Image builds use `versions.json` as the source of truth.