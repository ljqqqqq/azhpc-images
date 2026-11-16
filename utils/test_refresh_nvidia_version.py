#!/usr/bin/env python3
"""Check NVIDIA manifest detection with mocked package/module metadata on Linux.

Run: python3 utils/test_refresh_nvidia_version.py
Requires bash and jq; no GPU, root or package installation needed.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class NvidiaVersionTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nvidia-version-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = self.root / "component_versions.txt"
        self.manifest.write_text(json.dumps({"NVIDIA": "620.70", "HPCX": "2.51"}))
        utilities = (REPO / "utils/utilities.sh").read_text()
        self.utilities = self.root / "utilities.sh"
        self.utilities.write_text(utilities.replace("/opt/azurehpc", str(self.root)))
        source = (REPO / "components/refresh_component_versions.sh").read_text()
        # Execute the real NVIDIA detector and manifest writer in isolation.
        self.detector = source.split('    NVIDIA_VERSION=""', 1)[1].split('    # CUDA', 1)[0]
        self.detector = 'NVIDIA_VERSION=""' + self.detector

    def detect(self, package_version="620.70.08-1ubuntu1", status="installed",
               module_version="620.70", missing=False):
        command = r'''
set -euo pipefail
source "$1"
dpkg-query() {
    [[ "${@: -1}" == nvidia-dkms-open ]] || return 1
    [[ "$TEST_MISSING" != 1 ]] || return 1
    printf '%s\t%s\n' "$TEST_STATUS" "$TEST_VERSION"
}
modinfo() { printf 'version: %s\n' "$TEST_MODULE_VERSION"; }
write_version() { write_component_version "$@"; }
''' + self.detector
        environment = dict(os.environ, TEST_VERSION=package_version, TEST_STATUS=status,
                           TEST_MODULE_VERSION=module_version, TEST_MISSING="1" if missing else "0")
        result = subprocess.run(["bash", "-c", command, "bash", str(self.utilities)],
                                env=environment, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(self.manifest.read_text())

    def test_package_patch_overrides_truncated_module_version(self):
        self.assertEqual(self.detect(), {"NVIDIA": "620.70.08", "HPCX": "2.51"})

    def test_records_actual_installed_patch(self):
        self.assertEqual(self.detect(package_version="620.70.09-1ubuntu1")["NVIDIA"], "620.70.09")

    def test_strips_debian_epoch_and_revision_without_losing_patch(self):
        self.assertEqual(self.detect(package_version="1:620.70.08-2ubuntu1")["NVIDIA"], "620.70.08")

    def test_removed_package_does_not_override_module_version(self):
        self.assertEqual(self.detect(status="config-files", module_version="580.167.08")["NVIDIA"],
                         "580.167.08")

    def test_missing_unversioned_package_keeps_module_fallback(self):
        self.assertEqual(self.detect(missing=True, module_version="580.167.08")["NVIDIA"],
                         "580.167.08")


if __name__ == "__main__":
    unittest.main(verbosity=2)
