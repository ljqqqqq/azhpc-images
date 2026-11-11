#!/usr/bin/env python3
"""Test private archive selection with Bash; no root or package tools needed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PrivateReinstallTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="private-reinstall-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.script = self.root / "reinstall.sh"
        self.script.write_text(Path(__file__).with_name("reinstall_private_packages.sh").read_text())
        self.repo = self.root / "private repo"
        self.repo.mkdir()
        self.log = self.root / "apt.log"
        self.archive("driver", "1", "arm64")

    def archive(self, package, version, architecture):
        path = self.repo / f"{package}-{architecture}.deb"
        path.write_text(f"{package}\t{version}\t{architecture}\n")
        return path

    def run_reinstall(self, inventory="driver\t1\tarm64\tinstalled", **overrides):
        env = dict(os.environ, TEST_INVENTORY=inventory, TEST_LOG=self.log.as_posix(),
                   FAIL_INVENTORY="", FAIL_METADATA="", FAIL_INSTALL="")
        env.update(overrides)
        command = r'''
set -e
dpkg-query() {
    if [[ -n "$FAIL_INVENTORY" ]]; then echo "inventory failed" >&2; return 42; fi
    printf '%s\n' "$TEST_INVENTORY"
}
dpkg-deb() {
    if [[ -n "$FAIL_METADATA" ]]; then echo "metadata failed" >&2; return 43; fi
    cat "${@: -1}"
}
apt-get() {
    printf '%s\n' "$@" > "$TEST_LOG"
    if [[ -n "$FAIL_INSTALL" ]]; then echo "installation failed" >&2; return 44; fi
}
script=$1
directory=$(cd "$2" && pwd)
set -- "$directory"
source "$script"
'''
        return subprocess.run([os.environ.get("BASH", "bash"), "-c", command, "bash",
                               self.script.as_posix(), self.repo.as_posix()],
                              env=env, capture_output=True, text=True, timeout=30)

    def test_explicit_archive_reinstall_even_when_version_matches(self):
        result = self.run_reinstall()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = self.log.read_text().splitlines()
        self.assertEqual(args[:5], ["install", "-y", "--reinstall", "--no-remove", "--"])
        self.assertEqual(len(args), 6)
        self.assertTrue(args[5].endswith("/private repo/driver-arm64.deb"))
        self.assertIn("Reinstalling private package: driver:arm64=1", result.stdout)

    def test_all_matching_dependencies_are_explicitly_reinstalled(self):
        self.archive("libdriver", "2", "arm64")
        self.archive("cuda-meta", "3", "all")
        result = self.run_reinstall("driver\t1\tarm64\tinstalled\nlibdriver\t2\tarm64\tinstalled\n"
                                    "cuda-meta\t3\tall\tinstalled")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.log.read_text().splitlines()[5:]), 3)

    def test_other_version_architecture_and_uninstalled_packages_are_skipped(self):
        self.archive("driver", "1", "amd64")
        self.archive("not-installed", "1", "arm64")
        self.archive("older-version", "1", "arm64")
        self.archive("removed", "1", "arm64")
        result = self.run_reinstall("driver\t1\tarm64\tinstalled\nolder-version\t2\tarm64\tinstalled\n"
                                    "removed\t1\tarm64\tconfig-files")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.log.read_text().splitlines()[5:]), 1)

    def test_no_matching_version_leaves_upgrade_to_component_installer(self):
        result = self.run_reinstall("driver\t0\tarm64\tinstalled")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.log.exists())
        self.assertIn("component installers handle upgrades", result.stdout)

    def test_empty_repository_is_an_error(self):
        (self.repo / "driver-arm64.deb").unlink()
        result = self.run_reinstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no package archives", result.stderr)

    def test_invalid_archive_metadata_is_an_error(self):
        (self.repo / "driver-arm64.deb").write_text("driver\n")
        result = self.run_reinstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete package metadata", result.stderr)
        self.assertFalse(self.log.exists())

    def test_query_errors_do_not_start_installation(self):
        for flag, code in (("FAIL_INVENTORY", 42), ("FAIL_METADATA", 43)):
            with self.subTest(flag=flag):
                result = self.run_reinstall(**{flag: "yes"})
                self.assertEqual(result.returncode, code)
                self.assertFalse(self.log.exists())

    def test_installation_failure_propagates(self):
        result = self.run_reinstall(FAIL_INSTALL="yes")
        self.assertEqual(result.returncode, 44)
        self.assertIn("installation failed", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
