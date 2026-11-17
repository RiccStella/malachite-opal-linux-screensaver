import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='malachite test ')
        self.home = Path(self.tmp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        for name in ('chromium', 'swayidle', 'xprintidle'):
            self.fake(name, '#!/bin/sh\nexit 0\n')
        self.env = {**os.environ, 'HOME': str(self.home), 'XDG_DATA_HOME': str(self.home / 'data'),
                    'XDG_CONFIG_HOME': str(self.home / 'config'), 'XDG_RUNTIME_DIR': str(self.home),
                    'PATH': str(self.bin) + ':' + os.environ['PATH'], 'WAYLAND_DISPLAY': 'wayland-test',
                    'XDG_SESSION_TYPE': 'wayland'}
        self.runner = self.home / 'data/malachite-opal/runner.py'

    def tearDown(self):
        self.tmp.cleanup()

    def fake(self, name, script):
        p = self.bin / name
        p.write_text(script)
        p.chmod(0o700)

    def install(self, *args):
        return subprocess.run(['bash', str(ROOT / 'install.sh'), *args], env=self.env, text=True, capture_output=True)

    def load(self):
        spec = importlib.util.spec_from_file_location('runner', self.runner)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_install_repeat_uninstall_preserves_lock_configuration(self):
        conf = self.home / '.xscreensaver'
        conf.write_text('lock: True\nprograms: existing\n')
        self.assertEqual(self.install().returncode, 0)
        self.assertTrue(self.runner.exists())
        auto = self.home / 'config/autostart/malachite-opal.desktop'
        self.assertIn('OnlyShowIn=COSMIC;', auto.read_text())
        self.assertEqual(self.install('--timeout', '45').returncode, 0)
        self.assertTrue(self.runner.with_name('runner.py.bak').exists())
        self.assertEqual(self.runner.with_name('timeout').read_text(), '45\n')
        self.assertEqual(conf.read_text(), 'lock: True\nprograms: existing\n')
        self.assertEqual(self.install('--uninstall').returncode, 0)
        self.assertFalse(self.runner.exists())
        self.assertFalse(auto.exists())
        self.assertTrue(conf.exists())

    def test_invalid_timeout_no_changes(self):
        for value in ('0', 'x', '1;echo bad', '86401'):
            self.assertNotEqual(self.install('--timeout', value).returncode, 0)
        self.assertFalse(self.runner.exists())

    def test_symlink_refused(self):
        target = self.home / 'data/malachite-opal'
        target.parent.mkdir()
        target.symlink_to(self.bin)
        self.assertNotEqual(self.install().returncode, 0)

    def test_no_autostart(self):
        self.assertEqual(self.install('--no-autostart').returncode, 0)
        self.assertFalse((self.home / 'config/autostart/malachite-opal.desktop').exists())

    def test_private_profile_and_sandbox(self):
        self.assertEqual(self.install().returncode, 0)
        module = self.load()
        with patch.dict(os.environ, self.env):
            command = module.browser_command('/tmp/private profile')
        self.assertIn('--user-data-dir=/tmp/private profile', command)
        self.assertIn('--ozone-platform=wayland', command)
        self.assertNotIn('--no-sandbox', command)
        self.assertNotIn('--disable-web-security', command)

    def test_viewer_idempotent_cleanup(self):
        self.fake('chromium', '#!/bin/sh\nexec sleep 30\n')
        self.assertEqual(self.install().returncode, 0)
        module = self.load()
        with patch.dict(os.environ, self.env):
            viewer = module.Viewer()
            viewer.start()
            process = viewer.process
            profile = Path(viewer.profile.name)
            self.assertEqual(profile.stat().st_mode & 0o777, 0o700)
            viewer.start()
            self.assertIs(viewer.process, process)
            viewer.stop()
            viewer.stop()
            self.assertIsNotNone(process.poll())
            self.assertFalse(profile.exists())

    def test_exited_launcher_does_not_leave_children_running(self):
        # A wrapper exits immediately but its foreground group child survives.
        self.fake('chromium', '#!/bin/sh\nsleep 30 &\necho $! > "$HOME/child.pid"\nexit 0\n')
        self.assertEqual(self.install().returncode, 0)
        module = self.load()
        with patch.dict(os.environ, self.env):
            import time
            viewer = module.Viewer()
            viewer.start()
            for _ in range(100):
                if (self.home / 'child.pid').exists():
                    break
                time.sleep(.01)
            child = int((self.home / 'child.pid').read_text())
            time.sleep(.05)
            viewer.tick()
            self.assertIsNone(viewer.process)
            # A terminated orphan may remain a zombie briefly until init reaps it.
            proc = Path(f'/proc/{child}/stat')
            self.assertTrue(not proc.exists() or proc.read_text().split()[2] == 'Z')

    def test_unsafe_runtime_rejected(self):
        self.assertEqual(self.install().returncode, 0)
        module = self.load()
        unsafe = self.home / 'unsafe'
        unsafe.mkdir(mode=0o755)
        with patch.dict(os.environ, {**self.env, 'XDG_RUNTIME_DIR': str(unsafe)}):
            with self.assertRaises(RuntimeError):
                module.runtime_dir()

    def test_daemon_callbacks_and_clean_shutdown(self):
        # Some managed build environments prohibit local sockets. Never mask a
        # daemon failure: probe the exact OS capability before skipping.
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                probe.bind(str(self.home / 'probe.sock'))
        except PermissionError:
            self.skipTest('Environment prohibits AF_UNIX sockets; run this test on Linux desktop/CI')
        self.fake('swayidle', '''#!/usr/bin/env python3
import subprocess, sys, time
args = sys.argv
subprocess.run(args[args.index('timeout')+2], shell=True, check=True)
time.sleep(.2)
subprocess.run(args[args.index('resume')+1], shell=True, check=True)
time.sleep(30)
''')
        self.fake('chromium', '#!/bin/sh\nexec sleep 30\n')
        self.assertEqual(self.install().returncode, 0)
        p = subprocess.Popen(['python3', str(self.runner), 'daemon'], env=self.env)
        try:
            import time
            time.sleep(1)
            self.assertIsNone(p.poll())
            subprocess.run(['python3', str(self.runner), 'quit'], env=self.env, check=True)
            self.assertEqual(p.wait(timeout=5), 0)
            self.assertFalse((self.home / 'malachite-opal/control.sock').exists())
            self.assertEqual(list((self.home / 'malachite-opal').glob('profile-*')), [])
        finally:
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
