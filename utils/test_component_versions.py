#!/usr/bin/env python3
"""Exercise the shared manifest writer in a temporary directory on Linux.

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
        self.assert_success(self.write("NCCL-RDMA_SHARP_PLUGIN", "commit"))
        self.assertEqual(json.loads(self.manifest.read_text()), {"NCCL_RDMA_SHARP_PLUGIN": "commit"})
        self.assertEqual(self.manifest.stat().st_mode & 0o777, 0o644)

    def test_inherited_keys_are_migrated_without_losing_versions_or_provenance(self):
        self.manifest.write_text(json.dumps({
            "NCCL-RDMA_SHARP_PLUGIN": "plugin-commit",
            "NCCL-RDMA_SHARP_PLUGIN_REPO_COMMIT": "plugin-commit",
            "NCCL-RDMA_SHARP_PLUGIN_REPO_REF": "master",
            "HPCX": "2.51", "ImageVersion": "inherited"}))
        self.assert_success(self.write("DOCA", "3.3.3"))
        actual = json.loads(self.manifest.read_text())
        self.assertEqual(actual, {
            "NCCL_RDMA_SHARP_PLUGIN": "plugin-commit",
            "NCCL_RDMA_SHARP_PLUGIN_REPO_COMMIT": "plugin-commit",
            "NCCL_RDMA_SHARP_PLUGIN_REPO_REF": "master",
            "HPCX": "2.51", "ImageVersion": "inherited", "DOCA": "3.3.3"})

    def test_existing_canonical_values_win_over_legacy_aliases(self):
        for entries in ([('A-B', 'old'), ('A_B', 'new')], [('A_B', 'new'), ('A-B', 'old')]):
            with self.subTest(entries=entries):
                self.manifest.write_text(json.dumps(dict(entries)))
                self.assert_success(self.write("DOCA", "3.3.3"))
                self.assertEqual(json.loads(self.manifest.read_text()), {"A_B": "new", "DOCA": "3.3.3"})

    def test_current_component_overwrites_both_spellings(self):
        for name in ("A-B", "A_B"):
            with self.subTest(name=name):
                self.manifest.write_text('{"A-B":"old", "A_B":"previous", "CUDA":"keep"}')
                self.assert_success(self.write(name, "installed"))
                self.assertEqual(json.loads(self.manifest.read_text()), {"A_B": "installed", "CUDA": "keep"})

    def test_values_round_trip_without_json_or_shell_interpretation(self):
        value = 'quote " backslash \\ newline\n$(touch ' + str(self.root / "injected") + ')'
        self.assert_success(self.write("COMPONENT.with/slash", value))
        self.assertEqual(json.loads(self.manifest.read_text()), {"COMPONENT_with_slash": value})
        self.assertFalse((self.root / "injected").exists())

    def test_invalid_existing_json_is_preserved_and_no_partial_file_remains(self):
        for original in ('{"DOCA": broken', '', '  \n'):
            with self.subTest(original=original):
                self.manifest.write_text(original)
                result = self.write("DOCA", "new")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.manifest.read_text(), original)
                self.assertFalse(list(self.root.glob("component_versions.txt.*")))

    def test_inherited_manifest_can_be_exported_by_the_original_test_runner(self):
        self.manifest.write_text('{"NCCL-RDMA_SHARP_PLUGIN":"commit", '
                                 '"NCCL-RDMA_SHARP_PLUGIN_REPO_REF":"master"}')
        self.assert_success(self.write("DOCA", "3.3.3"))
        runner = (Path(__file__).resolve().parents[1] / "tests/run-tests.sh").read_text()
        function = runner[runner.index("function set_component_versions {"):runner.index("function set_module_files_path {")]
        command = ('HPC_ENV=$1\n' + function + '\nset_component_versions\n'
                   '[[ "$VERSION_NCCL_RDMA_SHARP_PLUGIN" == commit && '
                   '"$VERSION_NCCL_RDMA_SHARP_PLUGIN_REPO_REF" == master ]]')
        result = subprocess.run(["bash", "-euc", command, "bash", str(self.root)],
                                capture_output=True, text=True)
        self.assert_success(result)

    def test_writer_does_not_change_callers_variables(self):
        command = ('source "$1"; component=outer; version=outer; install_dir=outer; '
                   'component_versions_json=outer; component_versions=outer; '
                   'write_component_version DOCA 3.3.3; '
                   '[[ "$component" == outer && "$version" == outer && "$install_dir" == outer '
                   '&& "$component_versions_json" == outer && "$component_versions" == outer ]]')
        result = subprocess.run(["bash", "-euc", command, "bash", str(self.utilities)],
                                capture_output=True, text=True)
        self.assert_success(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
