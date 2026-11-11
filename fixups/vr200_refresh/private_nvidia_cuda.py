#!/usr/bin/env python3
"""Plan and verify a reinstall from the supplied NVIDIA/CUDA repository payloads."""

import csv
import hashlib
from pathlib import Path
import re
import subprocess
import sys


FIELDS = ("repository", "package", "architecture", "installed_version", "private_version",
          "action", "sha256", "archive")

# Confirmed Get: ... developer.download.nvidia.com entries in build 40806's
# upgrade/nvidia.log. A different/older version alone is NOT source evidence.
PUBLIC_DOWNLOADS_40806 = {
    (package, "arm64"): "620.70.06-1ubuntu1"
    for package in ("nvidia-dkms-open", "nvidia-modprobe", "nvidia-persistenced",
                    "nvidia-headless-open")
}
PUBLIC_DOWNLOADS_40806[("nvidia-imex-direct", "arm64")] = "2.0.0.rel49-1"


def paragraphs(text):
    for block in re.split(r"\n\s*\n", text.strip()):
        record = {}
        key = None
        for line in block.splitlines():
            if line.startswith((" ", "\t")) and key:
                record[key] += " " + line.strip()
            elif ":" in line:
                key, value = line.split(":", 1)
                record[key] = value.strip()
        if record:
            yield record


def installed_packages(inventory):
    installed = {}
    for line in inventory.read_text().splitlines():
        package, version, architecture, status = line.split("\t")
        if status == "installed":
            installed[(package.split(":")[0], architecture)] = version
    return installed


def repository_packages(directories):
    packages = {}
    for directory in directories:
        directory = directory.resolve(strict=True)
        records = list(paragraphs((directory / "Packages").read_text()))
        if not records:
            raise ValueError(f"Empty private repository: {directory}")
        for record in records:
            key = (record["Package"], record["Architecture"])
            archive = (directory / record["Filename"]).resolve(strict=True)
            if not archive.is_relative_to(directory) or not archive.is_file():
                raise ValueError(f"Archive outside private repository: {archive}")
            if not re.fullmatch(r"[a-fA-F0-9]{64}", record.get("SHA256", "")):
                raise ValueError(f"Missing SHA256 for {key}")
            packages.setdefault(key, []).append(
                dict(record, archive=archive, repository=directory.name))
    return packages


def make_plan(inventory, directories, public_downloads=None):
    if public_downloads is None:
        public_downloads = PUBLIC_DOWNLOADS_40806
    installed = installed_packages(inventory)
    packages = repository_packages(directories)
    rows = []
    for key, observed_version in sorted(public_downloads.items()):
        if installed.get(key) != observed_version:
            raise ValueError(f"Build 40806 public-source evidence expects {key}={observed_version}; "
                             f"found {installed.get(key)}")
        candidates = packages.get(key, [])
        if not candidates:
            raise ValueError(f"No private replacement for public package: {key}")
        # Prefer the current version even when a newer private version exists.
        matching = [record for record in candidates if record["Version"] == installed[key]]
        choices = matching or candidates
        if len(choices) != 1:
            raise ValueError(f"Ambiguous private replacement for {key}; supply a repository "
                             "with the installed version or one explicit replacement version")
        record = choices[0]
        current, target = installed[key], record["Version"]
        archive = record["archive"]
        with archive.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest.lower() != record["SHA256"].lower():
            raise ValueError(f"Private archive checksum mismatch: {archive}")
        metadata = subprocess.check_output(
            ["dpkg-deb", "--show", "--showformat=${Package}\t${Version}\t${Architecture}",
             str(archive)], text=True).split("\t")
        if metadata != [key[0], target, key[1]]:
            raise ValueError(f"Private archive metadata mismatch: {archive}")
        action = "reinstall"
        if current != target:
            older = subprocess.run(["dpkg", "--compare-versions", current, "lt", target],
                                   check=False).returncode
            if older not in (0, 1):
                raise ValueError(f"Cannot compare versions: {current}, {target}")
            action = "upgrade" if older == 0 else "downgrade"
        rows.append(dict(zip(FIELDS, [record["repository"], *key, current, target,
                                      action, digest, str(archive)])))
    if not rows:
        raise ValueError("No confirmed public packages selected")
    return rows


def read_plan(report):
    with report.open(newline="") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    if not rows:
        raise ValueError("Empty private package plan")
    return rows


def check_simulation(simulation, report):
    targets = {row["package"] for row in read_plan(report)}
    for line in simulation.read_text().splitlines():
        if line.startswith("Remv "):
            raise ValueError(f"APT would remove a package: {line}")
        if line.startswith("Inst ") and line.split()[1].split(":")[0] not in targets:
            raise ValueError(f"APT would change a package outside the public-source repair: {line}")
    print("APT simulation changes only the confirmed public packages.")


def verify(inventory, report, before=None):
    installed = installed_packages(inventory)
    rows = read_plan(report)
    for row in rows:
        key = (row["package"], row["architecture"])
        if installed.get(key) != row["private_version"]:
            raise ValueError(f"Expected {key}={row['private_version']}; found {installed.get(key)}")
    if before is not None:
        original = installed_packages(before)
        targets = {(row["package"], row["architecture"]) for row in rows}
        for key in (original.keys() | installed.keys()) - targets:
            if installed.get(key) != original.get(key):
                raise ValueError(f"Non-target package changed: {key}: "
                                 f"{original.get(key)} -> {installed.get(key)}")
    print(f"Verified {len(rows)} packages at their private archive versions.")


def main():
    if len(sys.argv) >= 7 and sys.argv[1] == "plan":
        inventory, report, archives = map(Path, sys.argv[2:5])
        rows = make_plan(inventory, list(map(Path, sys.argv[5:])))
        with report.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=FIELDS, delimiter="\t")
            writer.writeheader()
            writer.writerows(rows)
        Path(archives).write_bytes(b"".join(str(row["archive"]).encode() + b"\0" for row in rows))
        for row in rows:
            print(f"{row['action']}: {row['package']}:{row['architecture']} "
                  f"{row['installed_version']} -> {row['private_version']}")
        print(f"Selected {len(rows)} private packages; report: {report}")
    elif len(sys.argv) in (4, 5) and sys.argv[1] == "verify":
        verify(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]) if len(sys.argv) == 5 else None)
    elif len(sys.argv) == 4 and sys.argv[1] == "check-simulation":
        check_simulation(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        raise ValueError("Usage: private_nvidia_cuda.py plan INVENTORY REPORT ARCHIVES REPO REPO | "
                         "verify INVENTORY REPORT [BEFORE] | check-simulation LOG REPORT")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"ERROR: {error}")
