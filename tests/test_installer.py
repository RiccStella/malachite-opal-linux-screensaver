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
        for name in ('swayidle', 'xprintidle'):
            self.fake(name, '#!/bin/sh\nexit 0\n')
        self.fake('pkg-config', '#!/bin/sh\nexit 0\n')
        self.fake('cc', """#!/usr/bin/env python3
import os, pathlib, sys
out=pathlib.Path(sys.argv[sys.argv.index('-o')+1])
out.write_text(os.environ.get('FAKE_VIEWER', '#!/bin/sh'+chr(10)+'exec sleep 30'+chr(10)))
out.chmod(0o700)
""")
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
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.install('--no-autostart').returncode, 0)
        self.assertFalse((self.home / 'config/autostart/malachite-opal.desktop').exists())

    def test_native_viewer_installed_no_browser_dependency(self):
        self.assertEqual(self.install().returncode, 0)
        self.assertFalse(self.runner.with_name('artwork.html').exists())
        self.assertTrue(os.access(self.runner.with_name('malachite-opal-viewer'), os.X_OK))
        self.assertIn('Alchemist', self.runner.with_name('ARTWORK-NOTICE.md').read_text())
        module=self.load()
        self.assertEqual(module.viewer_command(), [str(self.runner.with_name('malachite-opal-viewer'))])

    def test_compile_failure_preserves_previous_install(self):
        self.assertEqual(self.install().returncode, 0)
        before=self.runner.read_bytes()
        self.fake('cc', '#!/bin/sh\nexit 1\n')
        self.assertNotEqual(self.install('--timeout','45').returncode, 0)
        self.assertEqual(self.runner.read_bytes(),before)
        self.assertEqual(self.runner.with_name('timeout').read_text(),'120\n')

    def test_missing_build_dependency_preserves_install(self):
        self.assertEqual(self.install().returncode, 0)
        before=self.runner.read_bytes()
        self.fake('pkg-config', '#!/bin/sh\nexit 1\n')
        run=self.install()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('Missing dependencies',run.stderr)
        self.assertEqual(self.runner.read_bytes(),before)

    def test_native_failure_is_reported(self):
        self.env['FAKE_VIEWER'] = '#!/bin/sh\nexit 7\n'
        self.assertEqual(self.install().returncode,0)
        module=self.load()
        with patch.dict(os.environ,self.env):
            import time
            viewer=module.Viewer()
            viewer.start()
            time.sleep(.1)
            with self.assertRaisesRegex(RuntimeError,r'exited \(7\)'):
                viewer.tick()
            self.assertIsNone(viewer.process)

    def test_viewer_time_limit(self):
        self.assertEqual(self.install().returncode,0)
        module=self.load()
        with patch.dict(os.environ,self.env):
            viewer=module.Viewer()
            viewer.start()
            viewer.started-=61
            viewer.tick()
            self.assertIsNone(viewer.process)

    def test_viewer_idempotent_cleanup(self):
        self.assertEqual(self.install().returncode, 0)
        module = self.load()
        with patch.dict(os.environ, self.env):
            viewer = module.Viewer()
            viewer.start()
            process = viewer.process
            viewer.start()
            self.assertIs(viewer.process, process)
            viewer.stop()
            viewer.stop()
            self.assertIsNotNone(process.poll())

    def test_exited_launcher_does_not_leave_children_running(self):
        # A wrapper exits immediately but its foreground group child survives.
        self.env['FAKE_VIEWER'] = '#!/bin/sh\nsleep 30 &\necho $! > "$HOME/child.pid"\nexit 0\n'
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
