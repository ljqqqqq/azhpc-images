#!/usr/bin/env python3
"""Run the isolated fixes in a temporary filesystem; no package/GPU operations.

Linux: python3 fixups/vr200_refresh/test_image_fixes.py
"""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
TOOLS = r'''#!/bin/bash
set -eu
name=$(basename "$0")
echo "$name $*" >> "$MOCK_ROOT/calls"
case "$name" in
    systemctl)
        case "$*" in
            daemon-reload) ;;
            'unmask unattended-upgrades.service')
                [[ "${FAIL_UNMASK:-}" != 1 ]] || exit 42
                mask="$MOCK_ROOT/etc/systemd/system/unattended-upgrades.service"
                if [[ -L "$mask" && "$(readlink "$mask")" == /dev/null ]]; then rm "$mask"; fi ;;
            *) exit 99 ;;
        esac ;;
    udevadm) [[ "$*" == 'control --reload' && "${FAIL_RELOAD:-}" != 1 ]] ;;
    systemd-delta) printf '%s\n' "${MOCK_DELTA:-}" ;;
    systemd-analyze)
        if [[ "${FAIL_UNIT:-}" == 1 ]]; then echo 'Invalid generated unit' >&2; exit 1; fi ;;
    wget) cp "$MOCK_ARCHIVE" "$(basename "${@: -1}")" ;;
    *) exit 99 ;;
esac
'''


class ImageFixesTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="vr200-image-fixes-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / "var/tmp").mkdir(parents=True)
        self.env = dict(os.environ, MOCK_ROOT=str(self.root),
                        TOP_DIR=str(self.root / "repo"), UTILS_DIR=str(self.root / "repo/utils"),
                        AZHPC_IMAGES_TEST_DIR=str(self.root / "repo/tests"),
                        DISTRIBUTION="ubuntu26.04", ARCHITECTURE="aarch64", ID="ubuntu", HPC_DEBUG="")
        self.env["PATH"] = str(self.root / "bin") + os.pathsep + os.environ["PATH"]
        tool = self.put("bin/mock-tool", TOOLS, 0o755)
        for name in ("systemctl", "udevadm", "systemd-delta", "systemd-analyze", "wget"):
            (self.root / "bin" / name).symlink_to(tool)
        for file in ("fixups/vr200_refresh/apply_image_fixes.sh", "utils/utilities.sh",
                     "tests/run-tests.sh", "tests/test-definitions.sh"):
            source = (REPO / file).read_text()
            source = re.sub(r"/(?:var/tmp|etc|opt|usr/local)(?=[/\"'\s]|$)",
                            lambda match: str(self.root) + match[0], source)
            self.put("repo/" + file, source)
        self.original_definitions = (self.root / "repo/tests/test-definitions.sh").read_bytes()
        self.unit = self.put("etc/systemd/system/nvidia-persistenced.service",
                             '[Service]\nPIDFile=/var/run/nvidia-persistenced/nvidia-persistenced.pid\n'
                             'ExecStopPost=/bin/rm -rf /var/run/nvidia-persistenced\nRestart=on-failure\n', 0o640)
        self.mask = self.root / "etc/systemd/system/unattended-upgrades.service"
        self.mask.symlink_to("/dev/null")
        (self.root / "etc/systemd/system/nvidia-imex.service").symlink_to("/dev/null")
        self.put("etc/udev/rules.d/90-nfs-readahead.rules", 'PROGRAM="awk \'{print $4}\'"\n')
        self.put("etc/sysctl.conf", "vm.zone_reclaim_mode = 0\n")
        self.put("opt/azurehpc/test/run-tests.sh", "old runner\n")
        self.put("opt/azurehpc/test/health_checks/benchmark", "existing benchmark\n")
        for name in ("segmentationTreeThrust", "radixSortThrust"):
            self.put("usr/local/cuda/samples/" + name, "#!/bin/sh\nexit 0\n", 0o755)
        self.asset = self.put("usr/local/cuda/samples/test.ppm", "existing data\n")
        archive = self.root / "source.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for name in ("test.ppm", "reference.ppm"):
                data = ("source " + name).encode()
                member = tarfile.TarInfo("cuda-samples-test/cpp/2_Concepts_and_Techniques/segmentationTreeThrust/data/" + name)
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
        self.env["MOCK_ARCHIVE"] = str(archive)
        self.env["COMPONENT_VERSIONS"] = json.dumps({"cuda": {"common": {"samples": {
            "version": "test", "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}}}})

    def put(self, path, text, mode=0o644):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(mode)
        return path

    def run_fixes(self, **overrides):
        return subprocess.run(["bash", str(self.root / "repo/fixups/vr200_refresh/apply_image_fixes.sh")],
                              env=dict(self.env, **overrides), capture_output=True, text=True, timeout=30)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fixes_are_idempotent_and_preserve_unrelated_settings(self):
        for _ in range(2):
            self.assert_success(self.run_fixes())
        self.assertEqual(self.unit.read_text(),
                         '[Service]\nPIDFile=/run/nvidia-persistenced/nvidia-persistenced.pid\n'
                         'ExecStopPost=/bin/rm -rf /run/nvidia-persistenced\nRestart=on-failure\n')
        self.assertEqual(self.unit.stat().st_mode & 0o777, 0o640)
        self.assertEqual((self.root / "etc/sysctl.conf").read_text(), "vm.zone_reclaim_mode = 0\n")
        self.assertEqual(self.asset.read_text(), "existing data\n")
        calls = (self.root / "calls").read_text()
        self.assertNotIn("wget", calls)
        self.assertNotIn("systemctl start", calls)
        self.assertNotIn("systemctl restart", calls)
        self.assertIn("systemctl unmask unattended-upgrades.service", calls)
        self.assertFalse(os.path.lexists(self.mask))
        self.assertEqual(os.readlink(self.root / "etc/systemd/system/nvidia-imex.service"), "/dev/null")
        self.assertNotIn("systemctl enable", calls)
        self.assertEqual((self.root / "opt/azurehpc/test/health_checks/benchmark").read_text(), "existing benchmark\n")

    def test_generated_nfs_rule_passes_real_udev_parser(self):
        self.assert_success(self.run_fixes())
        rule = self.root / "etc/udev/rules.d/90-nfs-readahead.rules"
        self.assertIn("bdi=$kernel", rule.read_text())
        self.assertIn("if ($$4 == bdi)", rule.read_text())
        udevadm = shutil.which("udevadm")
        if not udevadm or "verify" not in subprocess.run([udevadm, "--help"], capture_output=True, text=True).stdout:
            self.skipTest("udevadm verify unavailable")
        result = subprocess.run([udevadm, "verify", str(rule)], capture_output=True, text=True)
        self.assert_success(result)

    def test_missing_cuda_data_is_repaired_from_verified_archive(self):
        self.asset.unlink()
        self.assert_success(self.run_fixes())
        self.assertEqual(self.asset.read_text(), "source test.ppm")
        self.assertEqual((self.asset.parent / "reference.ppm").read_text(), "source reference.ppm")
        self.assertFalse(list((self.root / "var/tmp").glob("cuda-sample-assets.*")))

    def test_corrupt_cuda_source_is_rejected_before_installing_data(self):
        self.asset.unlink()
        (self.root / "var/tmp").mkdir(parents=True, exist_ok=True)
        result = self.run_fixes(COMPONENT_VERSIONS=json.dumps({"cuda": {"common": {"samples": {
            "version": "test", "sha256": "0" * 64}}}}))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum verification failed", result.stdout)
        self.assertFalse(self.asset.exists())

    def test_reload_failure_stops_the_fixes(self):
        result = self.run_fixes(FAIL_RELOAD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("/var/run/nvidia-persistenced", self.unit.read_text())

    def test_unmask_failure_stops_the_fixes(self):
        result = self.run_fixes(FAIL_UNMASK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(os.readlink(self.mask), "/dev/null")
        self.assertIn("/var/run/nvidia-persistenced", self.unit.read_text())

    def test_runtime_export_handles_legacy_keys_without_running_the_utils_writer(self):
        original = json.dumps({"NCCL-RDMA_SHARP_PLUGIN": "7daa9c6",
                               "NCCL-RDMA_SHARP_PLUGIN_REPO_REF": "master",
                               "NCCL_TESTS_REPO_REF": "master"})
        manifest = self.put("opt/azurehpc/component_versions.txt", original)
        self.assert_success(self.run_fixes())
        runner = self.root / "repo/tests/run-tests.sh"
        deployed = self.root / "opt/azurehpc/test/run-tests.sh"
        # A later Packer copy must retain the compatibility patch too.
        shutil.copyfile(runner, deployed)
        source = deployed.read_text()
        function = source[source.index("function set_component_versions {"):source.index("function set_module_files_path {")]
        result = subprocess.run(["bash", "-euc", function + '\nset_component_versions\n'
                                 '[[ "$VERSION_NCCL_RDMA_SHARP_PLUGIN" == 7daa9c6 ]]\n'
                                 '[[ "$VERSION_NCCL_RDMA_SHARP_PLUGIN_REPO_REF" == master ]]\n'
                                 '[[ "$VERSION_NCCL_TESTS_REPO_REF" == master ]]\n'],
                                env=dict(self.env, HPC_ENV=str(manifest.parent)),
                                capture_output=True, text=True)
        self.assert_success(result)
        self.assertEqual(manifest.read_text(), original)

    def test_unrecognized_test_runner_fails_before_deploying_it(self):
        self.put("repo/tests/run-tests.sh", "#!/bin/bash\n# no version loader\n")
        result = self.run_fixes()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not locate set_component_versions", result.stderr)
        self.assertEqual((self.root / "opt/azurehpc/test/run-tests.sh").read_text(), "old runner\n")

    def test_packer_copy_keeps_original_unit_checks_after_unmask(self):
        vendor = self.put("usr/lib/systemd/system/vendor.service", "[Service]\nExecStart=/bin/true\n")
        (self.root / "etc/systemd/system/vendor.service").symlink_to(vendor)
        self.assert_success(self.run_fixes())
        source = self.root / "repo/tests/test-definitions.sh"
        deployed = self.root / "opt/azurehpc/test/test-definitions.sh"
        # Simulate the later Packer copy from the VM checkout.
        shutil.copyfile(source, deployed)
        self.assertEqual(source.read_bytes(), self.original_definitions)
        self.assertEqual(deployed.read_bytes(), self.original_definitions)
        command = 'source "$1"; verify_systemd_unit_syntax'
        result = subprocess.run(["bash", "-c", command, "bash", str(deployed)],
                                env=dict(self.env, MOCK_DELTA="[EXTENDED] /vendor-extended.service -> override"),
                                capture_output=True, text=True)
        self.assert_success(result)
        call = next(line for line in (self.root / "calls").read_text().splitlines() if line.startswith("systemd-analyze "))
        self.assertIn("nvidia-persistenced.service", call)
        self.assertIn("/vendor-extended.service", call)
        self.assertIn("./vendor.service", call)
        self.assertNotIn("unattended-upgrades.service", call)
        self.assertFalse(os.path.lexists(self.mask))
        result = subprocess.run(["bash", "-c", command, "bash", str(deployed)],
                                env=dict(self.env, FAIL_UNIT="1"), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid generated unit", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
