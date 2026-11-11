#!/usr/bin/env python3
"""Exercise the wrapper in a temporary filesystem with all package tools mocked.

No vendor installer, package operation, service operation, or reboot runs here.
Run on Linux with bash, jq, and coreutils available.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
OFED = "26.01.OFED.26.01.2.0.0.0.617.1-1"
NVIDIA_REPO = "nvidia-driver-local-repo-ubuntu2604-620.70.06"

MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['MOCK_ROOT'])
holds = root / 'holds.json'
with (root / 'calls.log').open('a') as log:
    log.write(name + ' ' + ' '.join(args) + '\n')
if name == 'uname':
    print('aarch64' if args == ['-m'] else '6.17-test')
elif name == 'dpkg':
    if args == ['--print-architecture']: print('arm64')
    elif args != ['--audit']: sys.exit(90)
elif name == 'dpkg-deb':
    if args[0] == '--show':
        if os.environ.get('FAIL_DEB_QUERY'): sys.exit(42)
        metadata = json.loads(pathlib.Path(args[-1]).read_text())
        print('\t'.join(metadata[field] for field in ('Package', 'Version', 'Architecture')))
        sys.exit()
    assert args[0] == '-f' and args[2] == 'Package'
    print(os.environ.get('REPO_DEB_PACKAGE', 'nvidia-driver-local-repo-ubuntu2604-620.70.06'))
elif name == 'dpkg-query':
    if args[-1].startswith('-f='):
        if 'Architecture' in args[-1]:
            if os.environ.get('FAIL_INVENTORY'): sys.exit(42)
            packages = json.loads((root / 'packages.json').read_text())
            print('\n'.join(package + '\t' + version + '\tarm64\tinstalled'
                            for package, version in packages.items()))
        elif 'Status-Status' in args[-1]:
            repositories = json.loads((root / 'repo-packages.json').read_text())
            print('\n'.join(package + '\t' + status for package, status in repositories.items()))
        else: print('base-package\t1.0')
        sys.exit()
    package = args[-1]
    fmt = args[-2]
    if 'Status-Status' in fmt:
        removed = json.loads((root / 'removed-packages.json').read_text())
        print('not-installed' if package in removed else 'installed')
    elif 'Depends' in fmt:
        print('mlnx-ofed-kernel-dkms (= ' + os.environ['OFED_VERSION'] + ')')
    else:
        versions = json.loads((root / 'packages.json').read_text())
        print(versions[package])
elif name == 'apt-mark':
    current = set(json.loads(holds.read_text()))
    if args == ['showhold']: print('\n'.join(sorted(current)))
    elif args[0] == 'hold':
        current.update(args[1:]); holds.write_text(json.dumps(sorted(current)))
    elif args[0] == 'unhold':
        current.difference_update(args[1:]); holds.write_text(json.dumps(sorted(current)))
    else: sys.exit(91)
elif name == 'systemctl':
    if args[0] == 'enable':
        for service in args[1:]:
            unit = root / 'etc/systemd/system' / service
            if unit.is_symlink() and os.readlink(unit) == '/dev/null':
                print('Cannot enable masked service: ' + service, file=sys.stderr)
                sys.exit(1)
            link = root / 'etc/systemd/system/multi-user.target.wants' / service
            link.parent.mkdir(parents=True, exist_ok=True)
            if os.path.lexists(link): link.unlink()
            link.symlink_to('/usr/lib/systemd/system/' + service)
    elif args != ['daemon-reload']: sys.exit(92)
elif name == 'dkms':
    module = args[2]
    version = args[4] if len(args) > 3 else os.environ['OFED_VERSION']
    if os.environ.get('BAD_DKMS') == module: version = 'old-version'
    kernel = os.environ.get('DKMS_KERNEL', '6.17-test')
    state = os.environ.get('DKMS_STATE', 'installed')
    suffix = os.environ.get('DKMS_SUFFIX', '' if module == 'nvidia' else ' (Original modules exist)')
    print(f'{module}/{version}, {kernel}, aarch64: {state}{suffix}')
elif name == 'modinfo': print('620.70.06')
elif name in ('apt-get', 'apt'):
    assert (args in (['check'], ['update'], ['-y', 'install', 'doca-ofed'])
            or args[:3] == ['install', '-y', '--reinstall']
            or (name == 'apt' and args[:2] == ['install', '-y'])
            or args[:3] == ['purge', '-y', '--'])
    config = pathlib.Path(os.environ['APT_CONFIG']).read_text()
    assert 'APT::Get::Remove' not in config
    assert '"--force-confnew"' in config
    assert 'force-confold' not in config
    assert 'UCF_FORCE_CONFFOLD' not in os.environ
    assert os.environ['UCF_FORCE_CONFFNEW'] == '1'
    assert os.environ['NEEDRESTART_MODE'] == 'l'
    if args[:3] == ['purge', '-y', '--']:
        if os.environ.get('FAIL_REPO_PURGE'): sys.exit(42)
        repositories = json.loads((root / 'repo-packages.json').read_text())
        removed = json.loads((root / 'removed-packages.json').read_text())
        for package in args[3:]:
            assert package.startswith('nvidia-driver-local-repo-')
            assert package != 'nvidia-driver-local-repo-ubuntu2604-620.70.06'
            repositories[package] = 'not-installed'
            removed.append(package)
        (root / 'repo-packages.json').write_text(json.dumps(repositories))
        (root / 'removed-packages.json').write_text(json.dumps(removed))
    elif args[:3] == ['install', '-y', '--reinstall'] and pathlib.Path(args[-1]).name.startswith('nvidia-driver-local-repo-'):
        package = 'nvidia-driver-local-repo-ubuntu2604-620.70.06'
        directory = root / 'var' / package
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'nvidia-driver-local-new-keyring.gpg').write_text('new keyring\n')
        (directory / 'contents').write_text('new repository payload\n')
        repositories = json.loads((root / 'repo-packages.json').read_text())
        repositories[package] = 'installed'
        (root / 'repo-packages.json').write_text(json.dumps(repositories))
    elif args[:3] == ['install', '-y', '--reinstall'] and pathlib.Path(args[-1]).name.startswith('nccl-local-repo-'):
        directory = root / 'var' / pathlib.Path(args[-1]).name.split('_')[0]
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'nccl-local-test-keyring.gpg').write_text('NCCL keyring\n')
    if os.environ.get('REMOVE_OLD_PACKAGE') and 'install' in args:
        (root / 'removed-packages.json').write_text(json.dumps([os.environ['REMOVE_OLD_PACKAGE']]))
    if os.environ.get('FAIL_APT') and 'install' in args: sys.exit(42)
    if '--no-remove' in args and os.environ.get('FAIL_PRIVATE_REINSTALL'): sys.exit(42)
elif name == 'ofed_info': print('MLNX_OFED_LINUX-26.01-2.0.0.0.617:')
elif name == 'sudo':
    assert args[:2] == ['tee', '-a'] and str(root) in args[-1]
    os.execvp(args[0], args)
elif name == 'update-grub':
    if os.environ.get('FAIL_UPDATE_GRUB'): sys.exit(42)
    sources = [root / 'etc/default/grub', *sorted((root / 'etc/default/grub.d').glob('*.cfg'))]
    arguments = ' '.join(path.read_text().replace('\n', ' ') for path in sources if path.is_file())
    if os.environ.get('KEEP_NOLPI'): arguments += ' irqchip.gicv3_nolpi=y'
    (root / 'boot/grub/grub.cfg').write_text('linux /vmlinuz ' + arguments + '\n')
elif name not in ('ldconfig', 'update-initramfs'): sys.exit(93)
'''

INSTALLER = r'''#!/bin/bash
set -euo pipefail
name=$(basename "$0")
echo "$name" >> "$MOCK_ROOT/install-order"
[[ "$PWD" == "$MOCK_ROOT"/var/tmp/vr200-in-place-upgrade.*/work/* ]]
grep -q 'exit 101' "$MOCK_ROOT/usr/sbin/policy-rc.d"
apt-mark showhold > "$MOCK_ROOT/during-holds"
! grep -qx libnccl2 "$MOCK_ROOT/during-holds"
grep -qx nvidia-container-toolkit "$MOCK_ROOT/during-holds"
grep -qx unrelated "$MOCK_ROOT/during-holds"
printf changed > "$MOCK_ROOT/etc/profile.d/cuda.sh"
printf introduced > "$MOCK_ROOT/etc/modprobe.d/nvidia-openrm.conf"
mkdir -p "$MOCK_ROOT/etc/apt/preferences.d"
printf 'new installer pin\n' > "$MOCK_ROOT/etc/apt/preferences.d/00-nvidia-prefer"
if [[ "$name" == install_doca.sh ]]; then
    mkdir -p "$MOCK_ROOT/etc/systemd/system/openibd.service.d"
    printf 'new installer override\n' > "$MOCK_ROOT/etc/systemd/system/openibd.service.d/override.conf"
    systemctl daemon-reload
    systemctl enable openibd.service
elif [[ "$name" == install_nvidiagpudriver.sh ]]; then
    systemctl enable nvidia-imex.service nvidia-persistenced.service
fi
if [[ -n "${NEW_PACKAGE_UNIT:-}" ]]; then
    ln -sfn "$MOCK_ROOT/new-package-unit" "$NEW_PACKAGE_UNIT"
fi
apt-mark hold gdrcopy libnccl-dev
if [[ "$name" == install_nccl.sh ]]; then
    [[ ! -e "$MOCK_ROOT/opt/nccl-tests" && ! -e "$MOCK_ROOT/tmp/nccl-tests" ]]
    [[ ! -e "$MOCK_ROOT/usr/local/nccl-rdma-sharp-plugins" && ! -L "$MOCK_ROOT/usr/local/nccl-rdma-sharp-plugins" ]]
    mkdir -p "$MOCK_ROOT/opt/nccl-tests" "$MOCK_ROOT/tmp/nccl-tests" "$MOCK_ROOT/tmp/nccl-rdma-sharp-plugins" \
        "$MOCK_ROOT/usr/local/nccl-rdma-sharp-plugins/lib"
    echo new > "$MOCK_ROOT/opt/nccl-tests/version"
    echo new > "$MOCK_ROOT/usr/local/nccl-rdma-sharp-plugins/lib/libnccl-net.so"
fi
if [[ "$name" == install_nvbandwidth_tool.sh ]]; then
    [[ ! -e "$MOCK_ROOT/opt/nvidia/nvbandwidth" && ! -L "$MOCK_ROOT/opt/nvidia/nvbandwidth" ]]
    mkdir -p "$MOCK_ROOT/opt/nvidia/nvbandwidth"
    cp "$TOP_DIR/internal_bits/nvbandwidth_main_0.10_v6" "$MOCK_ROOT/opt/nvidia/nvbandwidth/"
    ln -sfn "$MOCK_ROOT/opt/nvidia/nvbandwidth/nvbandwidth_main_0.10_v6" "$MOCK_ROOT/opt/nvidia/nvbandwidth/nvbandwidth"
fi
[[ "${FAIL_COMPONENT:-}" != "$name" ]] || exit 42
'''


class UpgradeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vr200-mock-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.env = dict(os.environ, MOCK_ROOT=str(self.root), OFED_VERSION=OFED)
        self.env.update(GPU="NVIDIA", SKU="VR200", TARGET_NODE_TYPE="azure_vm_regular",
                        IMAGE_EVIDENCE_RUN_NAME="mock-run")
        self.original_holds = ["libnccl2", "nvidia-container-toolkit", "unrelated"]
        self.put("holds.json", json.dumps(self.original_holds))
        self.put("removed-packages.json", "[]")
        self.put("repo-packages.json", json.dumps({
            "nvidia-driver-local-repo-ubuntu2604-610.57.04": "installed",
            "nvidia-driver-local-repo-ubuntu2604-620.62": "config-files",
            NVIDIA_REPO: "installed", "cuda-repo-ubuntu2604-13-5-local": "installed",
            "nvidia-container-toolkit": "installed"}))
        self.put(f"var/{NVIDIA_REPO}/contents", "old repository payload\n")
        tool = self.put("bin/mock-tool", MOCK_TOOL, 0o755)
        for name in ("uname", "dpkg", "dpkg-deb", "dpkg-query", "apt-mark", "systemctl", "dkms",
                     "apt", "ofed_info", "sudo",
                     "modinfo", "apt-get", "ldconfig", "update-initramfs", "update-grub"):
            (self.root / "bin" / name).symlink_to(tool)
        self.env["PATH"] = str(self.root / "bin") + os.pathsep + os.environ["PATH"]
        for file in ("fixups/upgrade_ubuntu2604_vr200.sh", "fixups/vr200_refresh/preserve_settings.sh",
                     "fixups/vr200_refresh/verify_versions.sh", "fixups/vr200_refresh/remove_nolpi.sh",
                     "fixups/vr200_refresh/refresh_nvidia_repo.sh",
                     "fixups/vr200_refresh/reinstall_private_packages.sh",
                     "utils/utilities.sh"):
            source = (REPO / file).read_text()
            source = re.sub(r"/(?:var/tmp|var|tmp|etc|opt|boot|usr/sbin|usr/local|usr/share/keyrings|run/systemd|lib/modules)(?=[/\"'\s]|$)",
                            lambda match: str(self.root) + match[0], source)
            # Only the fixture copy omits the root guard, so tests run unprivileged.
            source = source.replace("[[ ${EUID} -eq 0 ]]", "true")
            if file == "utils/utilities.sh":
                # Repository filtering has its own tests; never use real APT/network here.
                source += '\nconfigure_cuda_online_repo() { echo "cuda-source $*" >> "$MOCK_ROOT/calls.log"; }\n'
            self.put("repo/" + file, source)
        versions = json.loads((REPO / "versions.json").read_text())
        config = lambda name: versions[name]["ubuntu26.04"]["aarch64"]["azure_vm_regular"]["nvidia_vr200"]
        payload = b"mock verified payload\n"
        checksum = hashlib.sha256(payload).hexdigest()
        for component in ("nvidia", "cuda", "doca", "nccl", "nvbandwidth"):
            data = config(component)
            if component in ("nvidia", "cuda"): data = data["driver"]
            for key in ("sha256",):
                if key in data: data[key] = checksum
            names = [data[k] for k in ("repo_file", "binary_file") if k in data]
            for name in names: self.put("repo/internal_bits/" + name, payload)
        self.put("repo/versions.json", json.dumps(versions))
        driver_packages = ("nvidia-dkms-open nvidia-headless-open nvidia-headless-no-dkms-open "
                           "nvidia-kernel-common nvidia-firmware nvidia-modprobe nvidia-persistenced "
                           "libnvidia-compute libnvidia-cfg1 libnvidia-gpucomp libnvidia-imex1").split()
        packages = dict.fromkeys(driver_packages, config("nvidia")["driver"]["version"])
        packages.update({"nvidia-imex-direct": config("nvidia")["imex"]["version"], "cuda-toolkit-13-5": "13.5.0-1",
                         "doca-ofed": config("doca")["package_version"], "libnccl2": config("nccl")["version"],
                         "libnccl-dev": config("nccl")["version"]})
        packages.update({name + "-dkms": OFED for name in ("mlnx-ofed-kernel", "iser", "isert", "srp")})
        self.put("packages.json", json.dumps(packages))
        for component, package in (("nvidia", "nvidia-dkms-open"), ("cuda", "cuda-toolkit-13-5"),
                                   ("nccl", "libnccl2")):
            data = config(component)
            if component in ("nvidia", "cuda"):
                data = data["driver"]
            directory = "var/" + data["repo_file"].split("_")[0]
            self.put(directory + "/" + package + ".deb",
                     json.dumps({"Package": package, "Version": packages[package], "Architecture": "arm64"}))
        self.put("etc/os-release", "ID=ubuntu\nVERSION_ID=26.04\n")
        self.put("etc/default/grub", 'GRUB_CMDLINE_LINUX_DEFAULT="quiet irqchip.gicv3_nolpi=y"\n')
        self.put("etc/default/grub.d/50-cloudimg-settings.cfg",
                 'GRUB_CMDLINE_LINUX="console=ttyS0 iommu.passthrough=1 irqchip.gicv3_nolpi=y arm_smmu_v3.disable_msipolling=1"\n')
        self.put("boot/grub/grub.cfg", 'linux /vmlinuz irqchip.gicv3_nolpi=y\n')
        self.put("etc/profile.d/cuda.sh", "custom cuda settings\n", 0o640)
        self.put("etc/apt/preferences.d/00-nvidia-prefer", "old image pin\n")
        self.put("etc/profile.d/modules.sh", f'module() {{ export HPCX_MPI_DIR="{self.root}/hpcx" HPCX_SHARP_DIR="{self.root}/hpcx" HPCX_UCX_DIR="{self.root}/hpcx"; }}\n')
        for path in ("hpcx", "lib/modules/6.17-test/build", "etc/modprobe.d", "etc/infiniband", "var/tmp", "usr/sbin",
                     "etc/systemd/system/custom.target.wants", "run/systemd/system/example.target.wants"):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        self.put("custom-policy", "#!/bin/sh\nexit 0\n", 0o751)
        (self.root / "usr/sbin/policy-rc.d").symlink_to(self.root / "custom-policy")
        self.put("etc/systemd/system/openibd.service.d/override.conf", "old custom override\n")
        (self.root / "etc/systemd/system/custom.target.wants/openibd.service").symlink_to("/usr/lib/systemd/system/openibd.service")
        (self.root / "run/systemd/system/example.target.wants/alias.service").symlink_to("/usr/lib/systemd/system/nvidia-persistenced.service")
        for path in ("tmp/nccl-tests", "tmp/nccl-rdma-sharp-plugins", "opt/nccl-tests"):
            self.put(path + "/version", "old\n")
        self.put("usr/local/nccl-rdma-sharp-plugins/lib/libnccl-net.so", "old\n")
        self.put("usr/local/nccl-rdma-sharp-plugins/lib/libobsolete.so", "old\n")
        self.put("opt/nvidia/nvbandwidth/old-binary", "old\n")
        self.put("opt/nvidia/nvbandwidth/nvbandwidth_main_0.10_v6", "old\n")
        (self.root / "opt/nvidia/nvbandwidth/nvbandwidth").symlink_to("old-binary")
        for name in ("doca", "nvidiagpudriver", "nccl", "nvbandwidth_tool"):
            self.put(f"repo/components/install_{name}.sh", INSTALLER)
        # The isolated image-fix behavior is exercised in test_image_fixes.py.
        self.put("repo/fixups/vr200_refresh/apply_image_fixes.sh",
                 '#!/bin/bash\nset -euo pipefail\n'
                 'echo "Applied isolated image fixes"\n'
                 '[[ "${FAIL_IMAGE_FIXES:-}" != 1 ]] || exit 42\n')

    def put(self, path, content, mode=0o644):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        path.chmod(mode)
        return path

    def run_upgrade(self, **overrides):
        return subprocess.run(["bash", str(self.repo / "fixups/upgrade_ubuntu2604_vr200.sh")],
                              env=dict(self.env, **overrides), capture_output=True, text=True, timeout=30)

    def assert_restored(self):
        self.assertEqual(os.readlink(self.root / "usr/sbin/policy-rc.d"), str(self.root / "custom-policy"))
        self.assertEqual((self.root / "custom-policy").read_text(), "#!/bin/sh\nexit 0\n")
        self.assertEqual((self.root / "custom-policy").stat().st_mode & 0o777, 0o751)
        self.assertEqual(sorted(json.loads((self.root / "holds.json").read_text())), sorted(self.original_holds))
        for path in ("tmp/nccl-tests", "tmp/nccl-rdma-sharp-plugins"):
            self.assertEqual((self.root / path / "version").read_text(), "old\n")

    def test_success_and_evidence(self):
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_restored()
        self.assertEqual((self.root / "etc/profile.d/cuda.sh").read_text(), "changed")
        self.assertEqual((self.root / "etc/modprobe.d/nvidia-openrm.conf").read_text(), "introduced")
        self.assertEqual((self.root / "etc/apt/preferences.d/00-nvidia-prefer").read_text(), "new installer pin\n")
        self.assertEqual((self.root / "opt/nccl-tests/version").read_text(), "new\n")
        plugin = self.root / "usr/local/nccl-rdma-sharp-plugins/lib"
        self.assertEqual(sorted(path.name for path in plugin.iterdir()), ["libnccl-net.so"])
        self.assertEqual((plugin / "libnccl-net.so").read_text(), "new\n")
        bandwidth = self.root / "opt/nvidia/nvbandwidth"
        self.assertEqual(sorted(path.name for path in bandwidth.iterdir()),
                         ["nvbandwidth", "nvbandwidth_main_0.10_v6"])
        self.assertEqual((bandwidth / "nvbandwidth").read_bytes(), b"mock verified payload\n")
        self.assertEqual((self.root / "install-order").read_text().splitlines(),
                         [f"install_{name}.sh" for name in ("doca", "nvidiagpudriver", "nccl", "nvbandwidth_tool")])
        self.assertIn("--reinstall", (self.root / "calls.log").read_text())
        repositories = json.loads((self.root / "repo-packages.json").read_text())
        self.assertEqual([name for name, state in repositories.items()
                          if name.startswith("nvidia-driver-local-repo-") and state != "not-installed"], [NVIDIA_REPO])
        self.assertEqual(repositories["cuda-repo-ubuntu2604-13-5-local"], "installed")
        self.assertEqual(repositories["nvidia-container-toolkit"], "installed")
        self.assertEqual((self.root / f"var/{NVIDIA_REPO}/contents").read_text(), "new repository payload\n")
        self.assertEqual((self.root / "usr/share/keyrings/nvidia-driver-local-new-keyring.gpg").read_text(), "new keyring\n")
        self.assertFalse(list((self.root / "var/tmp").glob("vr200-in-place-upgrade.*")))
        self.assertTrue((self.root / "var/tmp/azhpc-image-evidence/mock-run/upgrade/packages-after.tsv").is_file())
        self.assertIn("Applied isolated image fixes",
                      (self.root / "var/tmp/azhpc-image-evidence/mock-run/upgrade/image-fixes.log").read_text())
        self.assertIn("reboot to apply", (self.root / "var/tmp/azhpc-image-evidence/mock-run/upgrade/remove-nolpi.log").read_text())
        self.assertNotIn("irqchip.gicv3_nolpi", (self.root / "boot/grub/grub.cfg").read_text())
        self.assertEqual((self.root / "etc/default/grub.d/50-cloudimg-settings.cfg").read_text(),
                         'GRUB_CMDLINE_LINUX="console=ttyS0 iommu.passthrough=1  arm_smmu_v3.disable_msipolling=1"\n')
        for service in ("openibd", "nvidia-imex", "nvidia-persistenced"):
            link = self.root / f"etc/systemd/system/multi-user.target.wants/{service}.service"
            self.assertEqual(os.readlink(link), f"/usr/lib/systemd/system/{service}.service")
        self.assertEqual((self.root / "etc/systemd/system/openibd.service.d/override.conf").read_text(),
                         "new installer override\n")
        calls = (self.root / "calls.log").read_text()
        self.assertNotIn("systemctl is-enabled", calls)
        self.assertNotIn("systemctl unmask", calls)

    def test_each_installer_failure_restores_temporary_state(self):
        for name in ("doca", "nvidiagpudriver", "nccl", "nvbandwidth_tool"):
            with self.subTest(component=name):
                # Each run gets a fresh base image fixture.
                case = UpgradeTest()
                case.setUp()
                try:
                    result = case.run_upgrade(FAIL_COMPONENT=f"install_{name}.sh")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("backups retained", result.stderr)
                    case.assert_restored()
                    # Completed installer writes are not reverted after failure.
                    self.assertEqual((case.root / "etc/profile.d/cuda.sh").read_text(), "changed")
                    self.assertEqual((case.root / "etc/modprobe.d/nvidia-openrm.conf").read_text(), "introduced")
                    if name != "nvbandwidth_tool":
                        self.assertEqual((case.root / "opt/nccl-tests/version").read_text(), "old\n")
                    plugin = case.root / "usr/local/nccl-rdma-sharp-plugins/lib"
                    self.assertEqual((plugin / "libnccl-net.so").read_text(),
                                     "new\n" if name == "nvbandwidth_tool" else "old\n")
                    self.assertEqual((plugin / "libobsolete.so").exists(), name != "nvbandwidth_tool")
                    bandwidth = case.root / "opt/nvidia/nvbandwidth"
                    self.assertEqual(os.readlink(bandwidth / "nvbandwidth"), "old-binary")
                    self.assertEqual((bandwidth / "nvbandwidth_main_0.10_v6").read_text(), "old\n")
                finally:
                    case.doCleanups()

    def test_apt_failure_stops_and_restores(self):
        result = self.run_upgrade(FAIL_APT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()
        self.assertEqual((self.root / "install-order").read_text().splitlines(), ["install_doca.sh"])

    def test_inherited_keep_old_policy_is_overridden(self):
        result = self.run_upgrade(UCF_FORCE_CONFFOLD="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_restored()

    def test_service_unit_keeps_installer_changes(self):
        unit = self.root / "etc/systemd/system/nvidia-persistenced.service"
        unit.symlink_to(self.root / "old-custom-unit")
        result = self.run_upgrade(NEW_PACKAGE_UNIT=str(unit))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(os.readlink(unit), str(self.root / "new-package-unit"))

    def test_wrapper_does_not_unmask_service(self):
        unit = self.root / "etc/systemd/system/nvidia-imex.service"
        unit.symlink_to("/dev/null")
        result = self.run_upgrade()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot enable masked service: nvidia-imex.service", result.stdout)
        self.assertEqual(os.readlink(unit), "/dev/null")
        self.assertNotIn("systemctl unmask", (self.root / "calls.log").read_text())
        self.assert_restored()

    def test_dependency_removal_does_not_restore_obsolete_hold(self):
        self.original_holds.append("cuda-obsolete")
        self.put("holds.json", json.dumps(self.original_holds))
        result = self.run_upgrade(REMOVE_OLD_PACKAGE="cuda-obsolete")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Not restoring hold on removed package: cuda-obsolete", result.stdout)
        self.original_holds.remove("cuda-obsolete")
        self.assert_restored()

    def test_component_config_symlink_keeps_installer_contents(self):
        path = self.root / "etc/profile.d/cuda.sh"
        target = self.root / "custom-cuda-profile"
        path.rename(target)
        path.symlink_to(target)
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(os.readlink(path), str(target))
        self.assertEqual(target.read_text(), "changed")
        self.assert_restored()

    def test_absent_policy_is_removed_after_success(self):
        (self.root / "usr/sbin/policy-rc.d").unlink()
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(os.path.lexists(self.root / "usr/sbin/policy-rc.d"))

    def test_absent_policy_is_removed_after_failure(self):
        (self.root / "usr/sbin/policy-rc.d").unlink()
        result = self.run_upgrade(FAIL_COMPONENT="install_nccl.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(os.path.lexists(self.root / "usr/sbin/policy-rc.d"))
        self.assertEqual(sorted(json.loads((self.root / "holds.json").read_text())), sorted(self.original_holds))

    def test_regular_policy_file_and_mode_are_restored(self):
        policy = self.root / "usr/sbin/policy-rc.d"
        policy.unlink()
        original = "#!/bin/sh\n# original image policy\nexit 0\n"
        self.put("usr/sbin/policy-rc.d", original, 0o750)
        result = self.run_upgrade(FAIL_COMPONENT="install_nvidiagpudriver.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(policy.is_symlink())
        self.assertEqual(policy.read_text(), original)
        self.assertEqual(policy.stat().st_mode & 0o777, 0o750)

    def test_dangling_policy_symlink_is_restored(self):
        policy = self.root / "usr/sbin/policy-rc.d"
        policy.unlink()
        missing_target = self.root / "missing-policy-target"
        policy.symlink_to(missing_target)
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(policy.is_symlink())
        self.assertEqual(os.readlink(policy), str(missing_target))
        self.assertFalse(missing_target.exists())

    def test_wrong_installed_package_version_is_rejected(self):
        packages = json.loads((self.root / "packages.json").read_text())
        packages["libnccl2"] = "old-version"
        self.put("packages.json", json.dumps(packages))
        result = self.run_upgrade()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected installed", result.stdout)
        self.assert_restored()

    def test_old_ofed_dkms_is_rejected(self):
        result = self.run_upgrade(BAD_DKMS="mlnx-ofed-kernel")
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()
        self.assertIn("backups retained", result.stderr)

    def test_old_nvidia_dkms_is_rejected(self):
        result = self.run_upgrade(BAD_DKMS="nvidia")
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()

    def test_original_modules_suffix_is_accepted_for_nvidia_too(self):
        result = self.run_upgrade(DKMS_SUFFIX=" (Original modules exist)")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def run_verification(self, **overrides):
        env = dict(self.env, TOP_DIR=str(self.repo), UTILS_DIR=str(self.repo / "utils"),
                   DISTRIBUTION="ubuntu26.04", ARCHITECTURE="aarch64",
                   COMPONENT_VERSIONS=(self.repo / "versions.json").read_text())
        return subprocess.run(["bash", str(self.repo / "fixups/vr200_refresh/verify_versions.sh")],
                              env=dict(env, **overrides), capture_output=True, text=True, timeout=30)

    def test_dkms_warning_and_uninstalled_state_are_rejected(self):
        for state, suffix in (("installed", " (WARNING! Diff between built and installed module!)"),
                              ("installed", " (Original modules exist) (WARNING! Diff between built and installed module!)"),
                              ("built", "")):
            with self.subTest(state=state, suffix=suffix):
                result = self.run_verification(DKMS_STATE=state, DKMS_SUFFIX=suffix)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR: expected nvidia/", result.stderr)

    def test_dkms_for_other_kernel_is_rejected(self):
        result = self.run_verification(DKMS_KERNEL="old-kernel")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR: expected nvidia/", result.stderr)

    def test_missing_doca_package_is_rejected(self):
        self.put("removed-packages.json", '["doca-ofed"]')
        result = self.run_verification()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("doca-ofed: expected installed", result.stderr)

    def test_unexpected_doca_version_is_rejected(self):
        for version in ("3.3.1-057000", "3.3.4-022000"):
            with self.subTest(version=version):
                packages = json.loads((self.root / "packages.json").read_text())
                packages["doca-ofed"] = version
                self.put("packages.json", json.dumps(packages))
                result = self.run_verification()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("doca-ofed: expected installed 3.3.3-036000", result.stderr)
                self.assertIn("found installed " + version, result.stderr)

    def test_unpinned_doca_installer_records_actual_version(self):
        # Run the real Ubuntu installer against mocked package/service tools.
        source = (REPO / "components/install_doca.sh").read_text()
        source = re.sub(r"/(?:tmp|etc|opt)(?=[/\"'\s]|$)", lambda match: str(self.root) + match[0], source)
        self.put("repo/components/install_doca.sh", source)
        # A different declared target must still install without an APT version pin.
        versions = json.loads((self.repo / "versions.json").read_text())
        doca = versions["doca"]["ubuntu26.04"]["aarch64"]["azure_vm_regular"]["nvidia_vr200"]
        doca.update(version="3.3.4", package_version="3.3.4-022000")
        self.put("repo/versions.json", json.dumps(versions))
        packages = json.loads((self.root / "packages.json").read_text())
        packages["doca-ofed"] = "3.3.4-022000"
        new_ofed = "26.01.OFED.26.01.2.0.0.0.700.1-1"
        for name in ("mlnx-ofed-kernel", "iser", "isert", "srp"):
            packages[name + "-dkms"] = new_ofed
        self.put("packages.json", json.dumps(packages))
        result = self.run_upgrade(OFED_VERSION=new_ofed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("apt-get -y install doca-ofed\n", (self.root / "calls.log").read_text())
        manifest = json.loads((self.root / "opt/azurehpc/component_versions.txt").read_text())
        self.assertEqual(manifest["DOCA"], "3.3.4")

    def test_nvidia_repo_cleanup_without_old_repositories(self):
        self.put("repo-packages.json", json.dumps({"cuda-repo-ubuntu2604-13-5-local": "installed"}))
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("apt-get purge", (self.root / "calls.log").read_text())
        self.assertEqual(json.loads((self.root / "repo-packages.json").read_text())[NVIDIA_REPO], "installed")

    def test_nvidia_repo_purge_failure_stops_before_driver(self):
        result = self.run_upgrade(FAIL_REPO_PURGE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()
        self.assertEqual((self.root / "install-order").read_text().splitlines(), ["install_doca.sh"])

    def test_same_version_private_packages_are_reinstalled_from_archives(self):
        result = self.run_upgrade()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "calls.log").read_text()
        installs = [line for line in calls.splitlines() if '--no-remove' in line]
        self.assertEqual(len(installs), 2)
        self.assertIn("apt-get install -y --reinstall --no-remove -- ", installs[0])
        self.assertIn("/nvidia-dkms-open.deb", installs[0])
        self.assertIn("/cuda-toolkit-13-5.deb", installs[0])
        self.assertIn("/libnccl2.deb", installs[1])
        self.assertLess(calls.index("cuda-source ubuntu2604 sbsa disabled"), calls.index(installs[0]))
        self.assertLess(calls.index(installs[1]), calls.index("cuda-source ubuntu2604 sbsa dcgm"))
        self.assert_restored()

    def run_private_reinstall(self, **overrides):
        env = dict(self.env, APT_CONFIG=str(self.put("apt.conf", 'Dpkg::Options { "--force-confnew"; };\n')),
                   UCF_FORCE_CONFFNEW="1", NEEDRESTART_MODE="l")
        env.pop("UCF_FORCE_CONFFOLD", None)
        return subprocess.run(["bash", str(self.repo / "fixups/vr200_refresh/reinstall_private_packages.sh"),
                               str(self.root / "var" / NVIDIA_REPO)],
                              env=dict(env, **overrides), capture_output=True, text=True, timeout=30)

    def test_private_reinstall_skips_uninstalled_other_versions_and_architectures(self):
        for package, version, arch in (("not-installed", "1", "arm64"),
                                       ("nvidia-modprobe", "old-version", "arm64"),
                                       ("libnvidia-cfg1", "620.70.06-1ubuntu1", "amd64")):
            self.put(f"var/{NVIDIA_REPO}/{package}.deb",
                     json.dumps({"Package": package, "Version": version, "Architecture": arch}))
        result = self.run_private_reinstall()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        install = next(line for line in (self.root / "calls.log").read_text().splitlines()
                       if '--no-remove' in line)
        self.assertIn("/nvidia-dkms-open.deb", install)
        for name in ("not-installed.deb", "nvidia-modprobe.deb", "libnvidia-cfg1.deb"):
            self.assertNotIn(name, install)

    def test_private_reinstall_inventory_or_archive_query_failure_stops(self):
        for failure in ("FAIL_INVENTORY", "FAIL_DEB_QUERY"):
            with self.subTest(failure=failure):
                result = self.run_private_reinstall(**{failure: "1"})
                self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("apt-get install", (self.root / "calls.log").read_text())

    def test_private_reinstall_requires_nonempty_repository(self):
        (self.root / "var" / NVIDIA_REPO / "nvidia-dkms-open.deb").unlink()
        result = self.run_private_reinstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no package archives", result.stderr)

    def test_private_reinstall_failure_stops_before_driver_and_restores_settings(self):
        result = self.run_upgrade(FAIL_PRIVATE_REINSTALL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()
        self.assertEqual((self.root / "install-order").read_text().splitlines(), ["install_doca.sh"])

    def test_unexpected_repo_package_is_rejected_before_removal(self):
        result = self.run_upgrade(REPO_DEB_PACKAGE="nvidia-dkms-open")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected NVIDIA repository package", result.stdout)
        self.assertNotIn("apt-get purge", (self.root / "calls.log").read_text())

    def test_corrupt_input_stops_before_installer(self):
        self.put("repo/internal_bits/nvbandwidth_main_0.10_v6", "corrupt")
        result = self.run_upgrade()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum verification failed", result.stdout)
        self.assertFalse((self.root / "install-order").exists())

    def test_missing_nccl_repository_stops_before_installer(self):
        repository = next((self.repo / "internal_bits").glob("nccl-local-repo-*.deb"))
        repository.unlink()
        result = self.run_upgrade()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing private input/checksum: nccl-local-repo-", result.stderr)
        self.assertFalse((self.root / "install-order").exists())

    def test_private_nccl_repository_installs_exact_versions(self):
        source = (REPO / "components/install_nccl.sh").read_text()
        source = source.split("# Install the nccl rdma sharp plugin.")[0] + "\npopd\n"
        source = re.sub(r"/(?:tmp|var|usr/share/keyrings)(?=[/\"'\s]|$)",
                        lambda match: str(self.root) + match[0], source)
        script = self.put("repo/components/install_nccl_packages.sh", source)
        env = dict(self.env, TOP_DIR=str(self.repo), UTILS_DIR=str(self.repo / "utils"),
                   DISTRIBUTION="ubuntu26.04", ARCHITECTURE="aarch64",
                   COMPONENT_VERSIONS=(self.repo / "versions.json").read_text(),
                   APT_CONFIG=str(self.put("apt.conf", 'Dpkg::Options { "--force-confnew"; };\n')),
                   UCF_FORCE_CONFFNEW="1", NEEDRESTART_MODE="l")
        env.pop("UCF_FORCE_CONFFOLD", None)
        result = subprocess.run(["bash", str(script)], env=env, capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "calls.log").read_text()
        self.assertIn("apt-get install -y --reinstall " + str(self.repo / "internal_bits/nccl-local-repo-"), calls)
        self.assertIn("apt-get update\n", calls)
        self.assertIn("apt install -y libnccl2=2.32.5-1+cuda13.5 libnccl-dev=2.32.5-1+cuda13.5\n", calls)
        self.assertEqual((self.root / "usr/share/keyrings/nccl-local-test-keyring.gpg").read_text(),
                         "NCCL keyring\n")

    def run_remove_nolpi(self, **overrides):
        return subprocess.run(["bash", str(self.repo / "fixups/vr200_refresh/remove_nolpi.sh")],
                              env=dict(self.env, **overrides), capture_output=True, text=True, timeout=30)

    def test_remove_nolpi_preserves_other_arguments_and_symlink(self):
        target = self.put("custom-grub", "GRUB_CMDLINE_LINUX='irqchip.gicv3_nolpi=y irqchip.gicv3_nolpi=1 quiet irqchip.gicv3_nolpi'\n", 0o640)
        config = self.root / "etc/default/grub"
        config.unlink()
        config.symlink_to(target)
        self.put("etc/default/grub.d/extra.cfg",
                 'GRUB_CMDLINE_LINUX_DEFAULT="irqchip.gicv3_nolpi=y console=ttyS0 other_irqchip.gicv3_nolpi=y irqchip.gicv3_nolpi_extra=y"\n')
        result = self.run_remove_nolpi()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(config.is_symlink())
        self.assertEqual(target.read_text(), "GRUB_CMDLINE_LINUX='  quiet '\n")
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)
        self.assertEqual((self.root / "etc/default/grub.d/extra.cfg").read_text(),
                         'GRUB_CMDLINE_LINUX_DEFAULT=" console=ttyS0 other_irqchip.gicv3_nolpi=y irqchip.gicv3_nolpi_extra=y"\n')

    def test_remove_nolpi_without_parameter_regenerates_grub(self):
        # A stale generated entry must be replaced even when no source needs editing.
        (self.root / "etc/default/grub.d/50-cloudimg-settings.cfg").unlink()
        self.put("etc/default/grub", 'GRUB_CMDLINE_LINUX="quiet console=ttyS0"\n')
        for _ in range(2):
            result = self.run_remove_nolpi()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "etc/default/grub").read_text(), 'GRUB_CMDLINE_LINUX="quiet console=ttyS0"\n')
        self.assertNotIn("irqchip.gicv3_nolpi", (self.root / "boot/grub/grub.cfg").read_text())

    def test_update_grub_failure_stops_upgrade(self):
        result = self.run_upgrade(FAIL_UPDATE_GRUB="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()
        self.assertFalse((self.root / "var/tmp/azhpc-image-evidence/mock-run/upgrade/verify-versions.log").exists())

    def test_generated_nolpi_parameter_is_rejected(self):
        result = self.run_remove_nolpi(KEEP_NOLPI="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("remains in generated kernel boot entries", result.stderr)

    def test_image_fixes_failure_stops_and_restores_temporary_state(self):
        result = self.run_upgrade(FAIL_IMAGE_FIXES="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()
        self.assertFalse((self.root / "var/tmp/azhpc-image-evidence/mock-run/upgrade/packages-after.tsv").exists())


if __name__ == "__main__":
    if not shutil.which("jq"):
        raise SystemExit("jq is required")
    unittest.main(verbosity=2)
