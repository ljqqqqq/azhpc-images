#!/usr/bin/env python3
"""Test driver-only refresh with mocked APT/DKMS in a temporary filesystem."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
DRIVER_PACKAGES = """nvidia-dkms-open nvidia-headless-open nvidia-headless-no-dkms-open
nvidia-kernel-common nvidia-kernel-source-open nvidia-firmware nvidia-modprobe
nvidia-persistenced libnvidia-compute libnvidia-cfg1 libnvidia-gpucomp libnvidia-imex1""".split()

MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['MOCK_ROOT'])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / 'calls.log').open('a') as f: f.write(name + ' ' + ' '.join(args) + '\n')
def read(name): return json.loads((root / name).read_text())
def write(name, data): (root / name).write_text(json.dumps(data))
if name == 'uname':
    print(os.environ.get('MOCK_ARCH', 'aarch64') if args == ['-m'] else '7.0-test')
elif name == 'dpkg':
    if args == ['--print-architecture']: print('arm64')
    elif args != ['--audit']: sys.exit(90)
elif name == 'dpkg-deb':
    assert args[0] == '-f' and args[2] == 'Package'
    print(pathlib.Path(args[1]).name.split('_')[0])
elif name == 'dpkg-query':
    if args[-1].startswith('-f='):
        if 'Status-Status' in args[-1]:
            print('\n'.join(p + '\t' + s for p, s in read('repos.json').items()))
        else: print('\n'.join(p + '\t' + v for p, v in read('packages.json').items()))
    else:
        package, fmt = args[-1], args[-2]
        if 'Status-Status' in fmt: print('installed' if package in read('packages.json') else 'not-installed')
        else: print(read('packages.json')[package])
elif name == 'apt-mark':
    holds = set(read('holds.json'))
    if args == ['showhold']: print('\n'.join(sorted(holds)))
    elif args[0] == 'hold': write('holds.json', sorted(holds | set(args[1:])))
    elif args[0] == 'unhold': write('holds.json', sorted(holds - set(args[1:])))
    else: sys.exit(91)
elif name == 'apt-get':
    if args in (['check'], ['update']): sys.exit()
    assert 'exit 101' in (root / 'usr/sbin/policy-rc.d').read_text()
    assert '"--force-confnew"' in pathlib.Path(os.environ['APT_CONFIG']).read_text()
    assert {'libnccl2', 'doca-ofed', 'nvidia-imex-direct'} <= set(read('holds.json'))
    if args[:3] == ['install', '-y', '--reinstall']:
        repo = pathlib.Path(args[-1]).name.split('_')[0]
        directory = root / 'var' / repo
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'nvidia-driver-local-test-keyring.gpg').write_text('new keyring')
        repos = read('repos.json'); repos[repo] = 'installed'; write('repos.json', repos)
    elif args[:3] == ['purge', '-y', '--']:
        repos = read('repos.json')
        for p in args[3:]:
            assert p.startswith('nvidia-driver-local-repo-')
            repos[p] = 'not-installed'
        write('repos.json', repos)
    elif args[0] == '--simulate':
        for arg in args:
            if '=' in arg:
                p, v = arg.split('=', 1)
                print(f'Inst {p} [old] ({v} local [arm64])')
        if os.environ.get('EXTRA_PLAN'): print(os.environ['EXTRA_PLAN'])
    else:
        assert args[:4] == ['install', '-y', '--no-remove', '--no-install-recommends']
        if os.environ.get('FAIL_APT'): sys.exit(42)
        packages = read('packages.json')
        for arg in args[4:]:
            p, v = arg.split('=', 1); packages[p] = v
        write('packages.json', packages)
elif name == 'dkms':
    assert args[:3] == ['status', '-m', 'nvidia']
    version = 'old' if os.environ.get('BAD_DKMS') else args[4]
    print(f'{args[2]}/{version}, 7.0-test, aarch64: installed')
elif name == 'modinfo':
    print('old' if os.environ.get('BAD_MODULE') else read('packages.json')['nvidia-dkms-open'].split('-')[0])
elif name not in ('ldconfig', 'update-initramfs'): sys.exit(92)
'''


class DriverRefreshTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='vr200-driver-mock-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.repo = self.root / 'repo'
        self.env = dict(os.environ, MOCK_ROOT=str(self.root), GPU='NVIDIA', SKU='VR200',
                        TARGET_NODE_TYPE='azure_vm_regular', IMAGE_EVIDENCE_RUN_NAME='mock-run')
        self.put('calls.log', '')
        self.holds = ['libnccl2', 'doca-ofed', 'nvidia-imex-direct', 'nvidia-dkms-open:arm64']
        self.put('holds.json', json.dumps(self.holds))
        self.before = dict.fromkeys(DRIVER_PACKAGES, '620.70.08-1ubuntu1')
        self.before.update({'libnccl2': 'old-nccl', 'cuda-toolkit-13-5': 'old-cuda',
                            'doca-ofed': 'old-ofed', 'nvidia-imex-direct': 'old-imex',
                            'nvidia-dkms-open:arm64': '620.70.08-1ubuntu1'})
        self.put('packages.json', json.dumps(self.before))
        self.put('repos.json', json.dumps({'nvidia-driver-local-repo-ubuntu2604-620.70.08': 'installed',
                                        'cuda-repo-ubuntu2604-13-5-local': 'installed'}))
        for file in ('fixups/upgrade_ubuntu2604_vr200.sh', 'fixups/vr200_refresh/preserve_settings.sh',
                     'fixups/vr200_refresh/verify_versions.sh', 'components/configure_nvidia_repositories.sh'):
            source = (REPO / file).read_text()
            source = re.sub(r'/(?:var/tmp|var|etc|opt|usr/sbin|usr/share/keyrings|lib/modules)(?=[/"\s]|$)',
                            lambda m: str(self.root) + m[0], source)
            source = source.replace('[[ ${EUID} -eq 0 ]]', 'true')
            self.put('repo/' + file, source)
        self.put('repo/utils/utilities.sh', r'''
get_component_config() { jq -ec --arg c "$1" '.[$c]."ubuntu26.04".aarch64.azure_vm_regular.nvidia_vr200' <<< "$COMPONENT_VERSIONS"; }
verify_checksum() { [[ "$(sha256sum "$1" | awk '{print $1}')" == "$2" ]]; }
write_component_version() {
    python3 -c 'import json,sys; from pathlib import Path; p=Path(sys.argv[1]); d=json.loads(p.read_text()); d[sys.argv[2]]=sys.argv[3]; p.write_text(json.dumps(d))' "$MOCK_ROOT/manifest.json" "$1" "$2"
}
''')
        self.driver = json.loads((REPO / 'versions.json').read_text())['nvidia']['ubuntu26.04']['aarch64']['azure_vm_regular']['nvidia_vr200']['driver']
        payload = b'mock driver repository\n'
        self.driver['sha256'] = hashlib.sha256(payload).hexdigest()
        # Only NVIDIA metadata and its repository are available to this refresh.
        self.put('repo/versions.json', json.dumps({'nvidia': {'ubuntu26.04': {'aarch64': {'azure_vm_regular': {'nvidia_vr200': {'driver': self.driver}}}}}}))
        self.put('repo/internal_bits/' + self.driver['repo_file'], payload)
        self.put('etc/os-release', 'ID=ubuntu\nVERSION_ID=26.04\n')
        self.put('custom-policy', '#!/bin/sh\nexit 0\n', 0o751)
        (self.root / 'usr/sbin').mkdir(parents=True)
        (self.root / 'usr/sbin/policy-rc.d').symlink_to(self.root / 'custom-policy')
        (self.root / 'lib/modules/7.0-test/build').mkdir(parents=True)
        (self.root / 'var/tmp').mkdir(parents=True)
        (self.root / 'etc/apt/preferences.d').mkdir(parents=True)
        tool = self.put('bin/mock-tool', MOCK_TOOL, 0o755)
        for name in ('uname', 'dpkg', 'dpkg-deb', 'dpkg-query', 'apt-mark', 'apt-get', 'dkms',
                     'modinfo', 'ldconfig', 'update-initramfs'):
            (self.root / 'bin' / name).symlink_to(tool)
        self.env['PATH'] = str(self.root / 'bin') + os.pathsep + os.environ['PATH']
        self.manifest = {'NVIDIA': '620.70.08', 'CUDA': 'old-cuda', 'NCCL': 'old-nccl'}
        self.put('manifest.json', json.dumps(self.manifest))

    def put(self, name, content, mode=0o644):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        path.chmod(mode)
        return path

    def run_refresh(self, **env):
        return subprocess.run(['bash', str(self.repo / 'fixups/upgrade_ubuntu2604_vr200.sh')],
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=30)

    def assert_restored(self):
        policy = self.root / 'usr/sbin/policy-rc.d'
        self.assertEqual(os.readlink(policy), str(self.root / 'custom-policy'))
        self.assertEqual(json.loads((self.root / 'holds.json').read_text()), sorted(self.holds))

    def test_driver_only_success_and_evidence(self):
        result = self.run_refresh()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_restored()
        after = json.loads((self.root / 'packages.json').read_text())
        for p in DRIVER_PACKAGES: self.assertEqual(after[p], self.driver['version'])
        for p in self.before.keys() - set(DRIVER_PACKAGES): self.assertEqual(after[p], self.before[p])
        self.assertEqual(json.loads((self.root / 'manifest.json').read_text()),
                         dict(self.manifest, NVIDIA=self.driver['version'].split('-')[0]))
        reports = self.root / 'var/tmp/azhpc-image-evidence/mock-run/upgrade'
        for name in ('packages-before.tsv', 'packages-after.tsv', 'nvidia-plan.log', 'nvidia.log', 'verify-versions.log'):
            self.assertTrue((reports / name).is_file(), name)
        calls = (self.root / 'calls.log').read_text()
        self.assertNotIn('cuda-source', calls)
        self.assertNotIn('systemctl', calls)
        self.assertNotIn('update-grub', calls)
        self.assertNotIn('apt-mark unhold libnccl2', calls)
        repos = json.loads((self.root / 'repos.json').read_text())
        self.assertEqual(repos['cuda-repo-ubuntu2604-13-5-local'], 'installed')
        self.assertEqual(repos['nvidia-driver-local-repo-ubuntu2604-620.70.08'], 'not-installed')
        self.assertFalse(list((self.root / 'var/tmp').glob('vr200-in-place-upgrade.*')))

    def test_unrelated_changes_or_removals_are_rejected_before_driver_install(self):
        for plan in ('Inst libnccl2 [old] (new public [arm64])', 'Inst nvidia-imex-direct [old] (new local [arm64])',
                     'Remv nvidia-firmware [old]'):
            with self.subTest(plan=plan):
                result = self.run_refresh(EXTRA_PLAN=plan)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('driver-only refresh would', result.stderr)
                self.assertEqual(json.loads((self.root / 'packages.json').read_text()), self.before)
                self.assert_restored()

    def test_package_failure_restores_holds_and_policy(self):
        result = self.run_refresh(FAIL_APT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored()
        self.assertEqual(json.loads((self.root / 'manifest.json').read_text()), self.manifest)

    def test_failed_dkms_or_module_version_is_rejected(self):
        for flag in ('BAD_DKMS', 'BAD_MODULE'):
            with self.subTest(flag=flag):
                result = self.run_refresh(**{flag: '1'})
                self.assertNotEqual(result.returncode, 0)
                self.assert_restored()
                self.assertEqual(json.loads((self.root / 'manifest.json').read_text()), self.manifest)

    def test_corrupt_repository_stops_before_package_operations(self):
        self.put('repo/internal_bits/' + self.driver['repo_file'], b'corrupt')
        result = self.run_refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('apt-get', (self.root / 'calls.log').read_text())

    def test_missing_kernel_headers_stops_before_package_operations(self):
        (self.root / 'lib/modules/7.0-test/build').rmdir()
        result = self.run_refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('headers are missing', result.stderr)
        self.assertNotIn('apt-get', (self.root / 'calls.log').read_text())

    def test_absent_policy_is_removed_after_refresh(self):
        (self.root / 'usr/sbin/policy-rc.d').unlink()
        result = self.run_refresh()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'usr/sbin/policy-rc.d').exists())

    def test_wrong_architecture_is_rejected(self):
        result = self.run_refresh(MOCK_ARCH='x86_64')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('apt-get', (self.root / 'calls.log').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
