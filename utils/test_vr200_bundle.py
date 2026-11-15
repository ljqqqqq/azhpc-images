#!/usr/bin/env python3
"""Exercise VR200 APT package selection with mocked installation."""
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class VR200BundleTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="vr200-bundle-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / "calls.log"
        self.data = json.loads((REPO / "versions.json").read_text())
        self.env = dict(os.environ, TOP_DIR=str(self.root), UTILS_DIR=str(self.root),
                        DISTRIBUTION="ubuntu26.04", SKU="VR200", ARCHITECTURE="aarch64",
                        ARCHITECTURE_DISTRO="arm64", TEST_LOG=str(self.log))
        (self.root / "utilities.sh").write_text(r'''
get_component_config() { jq -c --arg component "$1" '.[$component]."ubuntu26.04".aarch64.azure_vm_regular.nvidia_vr200' <<< "$COMPONENT_VERSIONS"; }
_is_mrc_network() { [[ "${TARGET_NODE_TYPE:-}" == baremetal_1p ]]; }
verify_checksum() { [[ -z "${FAIL_CHECKSUM:-}" ]]; }
dpkg-deb() { basename "$2" | cut -d_ -f1; }
configure_cuda_online_repo() {
    printf 'source %s\n' "$*" >> "$TEST_LOG"
    [[ -z "${FAIL_SOURCE:-}" ]]
}
apt() { printf 'apt'; printf ' <%s>' "$@"; printf '\n'; } >> "$TEST_LOG"
apt-get() { printf 'apt-get'; printf ' <%s>' "$@"; printf '\n'; } >> "$TEST_LOG"
dpkg-query() { echo 4.7.0; }
apt-mark() { printf 'apt-mark %s\n' "$*"; } >> "$TEST_LOG"
''')

    def config(self, component):
        return self.data[component]["ubuntu26.04"]["aarch64"]["azure_vm_regular"]["nvidia_vr200"]

    def run_script(self, source):
        script = self.root / "install.sh"
        script.write_text(source)
        env = dict(self.env, COMPONENT_VERSIONS=json.dumps(self.data))
        return subprocess.run(["bash", str(script)], cwd=self.root, env=env,
                              capture_output=True, text=True, timeout=30)

    def run_nccl(self):
        source = (REPO / "components/install_nccl.sh").read_text()
        source = source.split("# Install the nccl rdma sharp plugin.")[0]
        source = source.replace("pushd /tmp", f'pushd "{self.root}"')
        return self.run_script(source)

    def setup_source(self):
        for component, key in (("cuda", "cuda-test-keyring.gpg"),
                               ("nvidia", "nvidia-driver-local-test-keyring.gpg")):
            repo = self.config(component)["driver"]["repo_file"].split("_")[0]
            directory = self.root / "var" / repo
            directory.mkdir(parents=True, exist_ok=True)
            (directory / key).write_text("test keyring")
        (self.root / "etc/apt/preferences.d").mkdir(parents=True, exist_ok=True)
        source = (REPO / "components/configure_nvidia_repositories.sh").read_text()
        return re.sub(r"/(?:var|etc|usr/share/keyrings)(?=[/\"'\s]|$)",
                      lambda match: str(self.root) + match[0], source)

    def run_setup(self):
        return self.run_script(self.setup_source())

    def run_build(self):
        setup = self.root / "setup.sh"
        setup.write_text(self.setup_source())
        setup.chmod(0o755)
        nccl = (REPO / "components/install_nccl.sh").read_text()
        nccl = nccl.split("# Install the nccl rdma sharp plugin.")[0]
        nccl = nccl.replace("pushd /tmp", f'pushd "{self.root}"')
        return self.run_script(f'set -e\n"{setup}"\necho driver >> "$TEST_LOG"\n' + nccl)

    def test_public_nccl_installs_both_exact_versions_and_holds_them(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.log.read_text()
        source = "source ubuntu2604 sbsa dcgm_nccl"
        packages = "apt-get <install> <-y> <libnccl2=2.32.6-1+cuda13.5> <libnccl-dev=2.32.6-1+cuda13.5>"
        self.assertIn(packages, calls)
        self.assertLess(calls.index(source), calls.index(packages))
        self.assertIn("apt-mark hold libnccl2", calls)
        self.assertIn("apt-mark hold libnccl-dev", calls)
        self.assertNotIn("devscripts", calls)
        self.assertNotIn("debhelper", calls)
        self.assertNotIn("<--reinstall>", calls)
        self.assertNotIn("<purge>", calls)
        for component in ("cuda", "nvidia"):
            repo_path = self.root / "internal_bits" / self.config(component)["driver"]["repo_file"]
            self.assertIn(f"apt-get <install> <-y> <{repo_path}>", calls)

    def test_nccl_source_failure_stops_before_nccl_install(self):
        self.env["FAIL_SOURCE"] = "yes"
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("driver", self.log.read_text())
        self.assertNotIn("libnccl2=", self.log.read_text())
        self.assertNotIn("apt-mark hold", self.log.read_text())

    def test_vr200_public_cuda_also_pins_nccl(self):
        self.config("cuda")["driver"]["source"] = "public"
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.log.read_text()
        self.assertIn("apt-get <install> <-y> <libnccl2=2.32.6-1+cuda13.5> <libnccl-dev=2.32.6-1+cuda13.5>", calls)
        self.assertIn("source ubuntu2604 sbsa public", calls)

    def test_non_vr_private_cuda_uses_unpinned_nccl(self):
        self.env["SKU"] = "GB200"
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.log.read_text()
        self.assertIn("source ubuntu2604 sbsa dcgm_nccl", calls)
        self.assertIn("apt-get <install> <-y> <libnccl2> <libnccl-dev>", calls)
        self.assertNotIn("<libnccl2=", calls)

    def test_private_cuda_repo_uses_x86_repository_on_x86(self):
        self.env.update(SKU="H100", ARCHITECTURE="x86_64", ARCHITECTURE_DISTRO="amd64")
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("source ubuntu2604 x86_64 dcgm_nccl", self.log.read_text())

    def test_missing_cuda_source_defaults_to_public(self):
        self.config("cuda")["driver"].pop("source")
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("source ubuntu2604 sbsa public", self.log.read_text())

    def test_imex_uses_pinned_repository_packages_without_standalone_input(self):
        self.assertEqual(self.config("nvidia")["imex"], {"version": "2.0.0.rel49-1"})
        source = (REPO / "components/install_nvidiagpudriver.sh").read_text()
        source = source.split("    # Install NVIDIA IMEX\n")[1].split('    write_component_version "IMEX"')[0]
        result = self.run_script('set -e\nsource "$UTILS_DIR/utilities.sh"\nnvidia_metadata=$(get_component_config nvidia)\n' + source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("apt-get <install> <-y> <libnvidia-imex1=620.70.08-1ubuntu1> <nvidia-imex-direct=2.0.0.rel49-1>",
                      self.log.read_text())

    def test_private_nccl_keeps_dcgm_only_public_allowlist(self):
        self.config("nccl")["source"] = "private"
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("source ubuntu2604 sbsa dcgm\n", self.log.read_text())
        self.assertNotIn("dcgm_nccl", self.log.read_text())

    def test_repository_setup_keeps_driver_and_cuda_source_independent(self):
        self.config("nvidia")["driver"]["source"] = "public"
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.log.read_text()
        self.assertIn("cuda-repo-", calls)
        self.assertNotIn("nvidia-driver-local-repo-", calls)
        self.assertLess(calls.index("source ubuntu2604 sbsa dcgm_nccl"),
                        calls.index("apt-get <install>"))

    def test_mrc_keeps_local_driver_without_explicit_private_source(self):
        self.config("nvidia")["driver"].pop("source")
        self.config("cuda")["driver"]["source"] = "public"
        self.env["TARGET_NODE_TYPE"] = "baremetal_1p"
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("nvidia-driver-local-repo-", self.log.read_text())

    def test_grid_configures_cuda_without_tesla_driver_repository(self):
        self.env["SKU"] = "NCv6"
        self.config("cuda")["driver"]["source"] = "public"
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.log.read_text()
        self.assertIn("source ubuntu2604 sbsa public", calls)
        self.assertNotIn("nvidia-driver-local-repo-", calls)

    def test_checksum_failure_stops_before_repository_install(self):
        self.env["FAIL_CHECKSUM"] = "yes"
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("apt-get <install>", self.log.read_text())

    def test_component_installs_do_not_reconfigure_repository(self):
        result = self.run_nccl()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("source ubuntu2604", self.log.read_text())
        source = (REPO / "components/install_dcgm.sh").read_text()
        source = source[source.index('if [[ $DISTRIBUTION == *"ubuntu"* ]]; then', source.index("# Install DCGM")):]
        source = source[:source.index('elif [[ $DISTRIBUTION == *"azurelinux"* ]]; then')] + "fi\n"
        self.env.update(FAIL_SOURCE="yes", SKU="GB200", CUDA_VERSION="13", SKU_CUDA_VERSION="13")
        result = self.run_script('set -e\nsource "$UTILS_DIR/utilities.sh"\n' + source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("source ubuntu2604", self.log.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
