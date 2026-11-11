#!/usr/bin/env python3
"""Exercise repair planning against real tiny DEBs; no package installation."""

import csv
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

import private_nvidia_cuda as repair


class PrivateNvidiaCudaTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repos = [self.root / "driver repo", self.root / "cuda repo"]
        for repo in self.repos:
            repo.mkdir()
            (repo / "Packages").write_text("")
        self.inventory = self.root / "installed.tsv"
        self.inventory.write_text("driver\t1\tarm64\tinstalled\n")
        self.public_downloads = {("driver", "arm64"): "1"}
        self.add_package("driver", "2", self.repos[0])
        self.add_package("cuda-library", "3", self.repos[1])

    def add_package(self, name, version, repo, architecture="arm64"):
        package_root = self.root / f"{name}-{version}-{architecture}"
        (package_root / "DEBIAN").mkdir(parents=True, exist_ok=True)
        (package_root / "DEBIAN" / "control").write_text(
            f"Package: {name}\nVersion: {version}\nArchitecture: {architecture}\n"
            "Maintainer: Test <test@example.com>\nDescription: private repair test\n")
        archive = repo / f"{name}_{version}_{architecture}.deb"
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(package_root), str(archive)],
                       check=True, stdout=subprocess.DEVNULL)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        with (repo / "Packages").open("a") as stream:
            stream.write(f"Package: {name}\nVersion: {version}\nArchitecture: {architecture}\n"
                         f"Filename: ./{archive.name}\nSHA256: {digest}\n\n")
        return archive

    def plan(self):
        return repair.make_plan(self.inventory, self.repos, self.public_downloads)

    def write_plan(self, rows):
        report = self.root / "plan.tsv"
        with report.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=repair.FIELDS, delimiter="\t")
            writer.writeheader()
            writer.writerows(rows)
        return report

    def test_old_cuda_without_public_source_evidence_is_left_alone(self):
        self.inventory.write_text("driver\t1\tarm64\tinstalled\n"
                                  "cuda-library\t1\tarm64\tinstalled\n")
        rows = self.plan()
        self.assertEqual({row["package"]: row["action"] for row in rows},
                         {"driver": "upgrade"})

    def test_matching_private_version_is_preferred_over_newer_private_version(self):
        self.add_package("driver", "1", self.repos[0])
        row, = self.plan()
        self.assertEqual((row["action"], row["private_version"]), ("reinstall", "1"))

    def test_equal_version_is_still_selected_with_private_payload_hash(self):
        self.inventory.write_text("driver\t2\tarm64\tinstalled\n")
        self.public_downloads[("driver", "arm64")] = "2"
        row, = self.plan()
        self.assertEqual(row["action"], "reinstall")
        self.assertEqual(row["sha256"], hashlib.sha256(Path(row["archive"]).read_bytes()).hexdigest())

    def test_newer_public_version_is_replaced_by_supplied_private_version(self):
        self.inventory.write_text("driver\t9\tarm64\tinstalled\n")
        self.public_downloads[("driver", "arm64")] = "9"
        row, = self.plan()
        self.assertEqual((row["action"], row["private_version"]), ("downgrade", "2"))

    def test_absent_unrelated_and_other_architecture_packages_are_not_selected(self):
        self.inventory.write_text("driver\t1\tarm64\tinstalled\n"
                                  "cuda-library\t3\tarm64\tconfig-files\n"
                                  "driver\t1\tamd64\tinstalled\n"
                                  "libnccl2\t5\tarm64\tinstalled\n")
        rows = self.plan()
        self.assertEqual([row["package"] for row in rows], ["driver"])

    def test_corrupt_archive_fails_before_installation(self):
        archive, = self.repos[0].glob("*.deb")
        archive.write_bytes(archive.read_bytes() + b"corrupt")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.plan()

    def test_index_metadata_must_match_archive(self):
        index = self.repos[0] / "Packages"
        index.write_text(index.read_text().replace("Version: 2", "Version: 4"))
        with self.assertRaisesRegex(ValueError, "metadata mismatch"):
            self.plan()

    def test_ambiguous_private_versions_fail(self):
        self.add_package("driver", "3", self.repos[0])
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            self.plan()

    def test_index_cannot_reference_an_archive_outside_the_repository(self):
        index = self.repos[0] / "Packages"
        archive, = self.repos[0].glob("*.deb")
        outside = self.root / "outside.deb"
        outside.write_bytes(archive.read_bytes())
        index.write_text(index.read_text().replace(f"./{archive.name}", "../outside.deb"))
        with self.assertRaisesRegex(ValueError, "outside private repository"):
            self.plan()

    def test_verification_rejects_old_versions_and_unconfigured_packages(self):
        report = self.write_plan(self.plan())
        with self.assertRaisesRegex(ValueError, "Expected"):
            repair.verify(self.inventory, report)
        self.inventory.write_text("driver\t2\tarm64\tinstalled\n")
        repair.verify(self.inventory, report)
        self.inventory.write_text("driver\t2\tarm64\tunpacked\n")
        with self.assertRaisesRegex(ValueError, "Expected"):
            repair.verify(self.inventory, report)

    def test_default_target_list_contains_only_the_five_observed_public_downloads(self):
        lines = ["cuda-library\t1\tarm64\tinstalled"]
        for (package, architecture), version in repair.PUBLIC_DOWNLOADS_40806.items():
            self.add_package(package, version, self.repos[0], architecture)
            lines.append(f"{package}\t{version}\t{architecture}\tinstalled")
        self.inventory.write_text("\n".join(lines) + "\n")
        rows = repair.make_plan(self.inventory, self.repos)
        self.assertEqual(len(rows), 5)
        self.assertTrue(all(row["action"] == "reinstall" for row in rows))
        self.assertNotIn("cuda-library", [row["package"] for row in rows])

    def test_source_evidence_is_not_reused_for_another_installed_version(self):
        self.inventory.write_text("driver\t9\tarm64\tinstalled\n")
        with self.assertRaisesRegex(ValueError, "public-source evidence expects"):
            self.plan()

    def test_confirmed_public_package_needs_a_private_replacement(self):
        self.public_downloads[("missing-driver", "arm64")] = "1"
        with self.inventory.open("a") as stream:
            stream.write("missing-driver\t1\tarm64\tinstalled\n")
        with self.assertRaisesRegex(ValueError, "No private replacement"):
            self.plan()

    def test_apt_simulation_rejects_an_extra_cuda_upgrade_or_removal(self):
        report = self.write_plan(self.plan())
        simulation = self.root / "apt.log"
        simulation.write_text("Inst driver [1] (2 local-deb [arm64])\n")
        repair.check_simulation(simulation, report)
        for extra in ("Inst cuda-library [1] (3 localhost [arm64])\n", "Remv cuda-library [1]\n"):
            simulation.write_text("Inst driver [1] (2 local-deb [arm64])\n" + extra)
            with self.assertRaises(ValueError):
                repair.check_simulation(simulation, report)

    def test_verification_rejects_changes_to_non_target_packages(self):
        self.inventory.write_text("driver\t1\tarm64\tinstalled\n"
                                  "cuda-library\t1\tarm64\tinstalled\n")
        report = self.write_plan(self.plan())
        before = self.root / "before.tsv"
        before.write_bytes(self.inventory.read_bytes())
        self.inventory.write_text("driver\t2\tarm64\tinstalled\n"
                                  "cuda-library\t1\tarm64\tinstalled\n")
        repair.verify(self.inventory, report, before)
        self.inventory.write_text("driver\t2\tarm64\tinstalled\n"
                                  "cuda-library\t3\tarm64\tinstalled\n")
        with self.assertRaisesRegex(ValueError, "Non-target package changed"):
            repair.verify(self.inventory, report, before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
