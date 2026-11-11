#!/usr/bin/env python3
"""Run with python3 utils/test_cuda_apt_repo.py; requires Bash, not root or APT."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CudaAptRepoTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="cuda-apt-repo-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.source = self.sources / "cuda-ubuntu2604-sbsa.list"
        self.modern_source = self.source.with_suffix(".sources")
        self.local_source = self.sources / "nvidia-driver-local.list"
        self.local_source.write_text("deb file:/var/nvidia-driver-local /\n")
        self.original_local_source = self.local_source.read_text()
        self.source.write_text("deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/sbsa/ /\n")
        self.utilities = self.root / "utilities.sh"
        utilities = Path(__file__).with_name("utilities.sh").read_text()
        self.utilities.write_text(utilities.replace("/etc/apt/sources.list.d", self.sources.as_posix()))
        self.log = self.root / "commands"

    def run_mode(self, mode, **overrides):
        env = dict(os.environ, TEST_LOG=self.log.as_posix(),
                   TEST_SOURCE=self.source.as_posix(), TEST_MODE=mode,
                   TEST_OLD_APT="", TEST_FAIL_INDEX="", TEST_FAIL_KEYRING="",
                   TEST_PACKAGES="\n".join([
                       "datacenter-gpu-manager-4-core",
                       "datacenter-gpu-manager-4-module-diag",
                       "datacenter-gpu-manager-4-cuda13",
                       "libdcgm", "dcgmi", "nv-hostengine", "libdcgm",
                       "cuda-toolkit-13-5", "nvidia-dkms-open",
                       "nvidia-imex-direct", "libnccl2", "libnvshmem3-cuda-13",
                   ]))
        env.update(overrides)
        script = r'''
set -e
source "$1"
wget() { printf 'wget %s\n' "$*" >> "$TEST_LOG"; touch "$2"; }
apt() {
    printf 'apt %s\n' "$*" >> "$TEST_LOG"
    if [[ "$TEST_MODE" == dcgm && -f "$TEST_SOURCE" ]]; then
        echo "Unrestricted source still enabled during keyring install" >&2
        return 99
    fi
    echo "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/sbsa/ /" > "$TEST_SOURCE"
    if [[ -n "$TEST_FAIL_KEYRING" ]]; then
        echo "Test keyring installation failure" >&2
        return 43
    fi
}
apt-get() {
    printf 'apt-get %s\n' "$*" >> "$TEST_LOG"
    if [[ "$*" == *Dir::State::lists=* && -n "$TEST_FAIL_INDEX" ]]; then
        echo "Test index download failure" >&2
        return 42
    fi
}
apt-cache() { printf '%s\n' "$TEST_PACKAGES"; }
dpkg-query() { echo 3.2.1; }
dpkg() { [[ -z "$TEST_OLD_APT" ]]; }
cuda_online_repo ubuntu2604 sbsa "$2"
'''
        return subprocess.run(
            [os.environ.get("BASH", "bash"), "-c", script, "bash",
             self.utilities.as_posix(), mode],
            env=env, capture_output=True, text=True,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.local_source.read_text(), self.original_local_source)

    def test_disabled_removes_inherited_public_sources_only(self):
        self.modern_source.write_text("Types: deb\nURIs: https://developer.download.nvidia.com\n")
        self.assert_success(self.run_mode("disabled"))
        self.assertFalse(self.source.exists())
        self.assertFalse(self.modern_source.exists())
        self.assertEqual(self.log.read_text().strip(), "apt-get update")

    def test_public_mode_remains_unrestricted(self):
        self.assert_success(self.run_mode("public"))
        self.assertEqual(self.source.read_text(),
                         "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] "
                         "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/sbsa/ /\n")

    def test_dcgm_mode_allows_only_exact_dcgm_names(self):
        self.assert_success(self.run_mode("dcgm"))
        include = self.source.read_text().split("include=")[1].split("]")[0]
        self.assertEqual(include.split(","), [
            "datacenter-gpu-manager-4-core", "datacenter-gpu-manager-4-cuda13",
            "datacenter-gpu-manager-4-module-diag", "dcgmi", "libdcgm", "nv-hostengine",
        ])
        log = self.log.read_text()
        self.assertIn("Dir::State::lists=", log)
        self.assertIn("Dir::Cache::pkgcache=", log)
        self.assertIn("APT::Update::Error-Mode=any", log)

    def test_dcgm_mode_is_idempotent(self):
        self.assert_success(self.run_mode("dcgm"))
        expected = self.source.read_text()
        self.assert_success(self.run_mode("dcgm"))
        self.assertEqual(self.source.read_text(), expected)

    def test_no_dcgm_packages_fails_closed(self):
        result = self.run_mode("dcgm", TEST_PACKAGES="nvidia-dkms-open\ncuda-toolkit-13-5")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no DCGM packages found", result.stderr)
        self.assertFalse(self.source.exists())

    def test_failed_index_download_fails_closed(self):
        result = self.run_mode("dcgm", TEST_FAIL_INDEX="yes")
        self.assertEqual(result.returncode, 42)
        self.assertIn("Test index download failure", result.stderr)
        self.assertFalse(self.source.exists())

    def test_failed_keyring_install_cannot_leave_public_source_enabled(self):
        result = self.run_mode("dcgm", TEST_FAIL_KEYRING="yes")
        self.assertEqual(result.returncode, 43)
        self.assertIn("Test keyring installation failure", result.stderr)
        self.assertFalse(self.source.exists())

    def test_old_apt_cannot_silently_ignore_include(self):
        result = self.run_mode("dcgm", TEST_OLD_APT="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires APT 3.2", result.stderr)
        self.assertFalse(self.log.exists())

    def test_unknown_mode_is_an_error(self):
        result = self.run_mode("typo")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported CUDA APT repository mode", result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
