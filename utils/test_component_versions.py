#!/usr/bin/env python3
"""Check the component-name fix in a temporary directory on Linux.

Run: python3 utils/test_component_versions.py
Requires bash, jq and coreutils. No installed image files are modified.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class ComponentVersionsTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="component-versions-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.manifest = self.root / "component_versions.txt"
        self.utilities = self.root / "utilities.sh"
        source = Path(__file__).with_name("utilities.sh").read_text()
        self.utilities.write_text(source.replace("/opt/azurehpc", str(self.root)))

    def write(self, name, version):
        return subprocess.run(["bash", "-euc", 'source "$1"; shift; write_component_version "$@"',
                               "bash", str(self.utilities), name, version], capture_output=True, text=True)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_new_manifest_uses_shell_variable_compatible_keys(self):
        self.assert_success(self.write("NCCL-RDMA_SHARP_PLUGIN", "7daa9c6"))
        self.assertEqual(json.loads(self.manifest.read_text()), {"NCCL_RDMA_SHARP_PLUGIN": "7daa9c6"})
        self.assertEqual(self.manifest.stat().st_mode & 0o777, 0o644)

    def test_update_changes_only_the_requested_field(self):
        existing = {"NCCL-RDMA_SHARP_PLUGIN": "abc1234", "NCCL_RDMA_SHARP_PLUGIN": "def5678",
                    "HPCX": "2.51", "ImageVersion": "inherited"}
        self.manifest.write_text(json.dumps(existing))
        self.assert_success(self.write("NCCL-RDMA_SHARP_PLUGIN", "7daa9c6"))
        self.assert_success(self.write("DOCA", "3.3.3"))
        expected = dict(existing, NCCL_RDMA_SHARP_PLUGIN="7daa9c6", DOCA="3.3.3")
        self.assertEqual(json.loads(self.manifest.read_text()), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
