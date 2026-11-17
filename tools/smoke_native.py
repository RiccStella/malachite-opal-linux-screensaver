#!/usr/bin/env python3
"""Exercise the real GTK/OpenGL renderer on DISPLAY (CI: xvfb-run -a).

This uses the available GPU/driver, including software Mesa on CI. Reported
memory is this native process's peak RSS, not a cross-machine comparison.
"""
from pathlib import Path
import os
import resource
import signal
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
VIEWER = ROOT / 'native/malachite-opal-viewer'


def ppm(path):
    with path.open('rb') as stream:
        assert stream.readline() == b'P6\n'
        width, height = map(int, stream.readline().split())
        assert stream.readline() == b'255\n'
        pixels = stream.read()
    assert len(pixels) == width * height * 3
    assert width > 0 and height > 0
    assert max(pixels) - min(pixels) >= 10, 'Uniform/empty native rendering'
    assert len(set(zip(pixels[::3], pixels[1::3], pixels[2::3]))) > 100
    return width, height, pixels


def main():
    if not os.environ.get('DISPLAY') and not os.environ.get('WAYLAND_DISPLAY'):
        raise SystemExit('A test display is required (use xvfb-run -a).')
    with tempfile.TemporaryDirectory(prefix='native-smoke-') as tmp:
        outputs = []
        for n in range(2):
            path = Path(tmp) / f'frame-{n}.ppm'
            run = subprocess.run([str(VIEWER), '--windowed', '--seed', '589',
                                  '--time', '3', '--smoke-frames', '10',
                                  '--capture', str(path)], capture_output=True,
                                 text=True, timeout=15)
            print(run.stderr)
            assert run.returncode == 0, run.stderr
            assert 'Gtk-CRITICAL' not in run.stderr, run.stderr
            assert 'NATIVE_SMOKE_OK' in run.stderr
            outputs.append(ppm(path))
        assert outputs[0] == outputs[1], 'Fixed seed/time rendering is not deterministic'
        start = time.monotonic()
        run = subprocess.run([str(VIEWER), '--windowed', '--duration', '1'],
                             capture_output=True, text=True, timeout=8)
        assert run.returncode == 0, run.stderr
        assert time.monotonic() - start < 5, 'Native duration did not bound display time'
        process = subprocess.Popen([str(VIEWER), '--windowed'], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(.5)
            assert process.poll() is None, 'Viewer exited before SIGTERM'
            process.send_signal(signal.SIGTERM)
            _, stderr = process.communicate(timeout=5)
            assert process.returncode == 0, stderr
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        if os.environ.get('DISPLAY') and shutil.which('xdotool'):
            for action in ('key', 'motion', 'click'):
                process = subprocess.Popen([str(VIEWER), '--windowed'], stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True)
                try:
                    # Scope window lookup to our own PID, never unrelated desktop windows.
                    ids = subprocess.check_output(['xdotool', 'search', '--sync', '--onlyvisible', '--pid',
                                                   str(process.pid), '--name', 'Malachite Opal'],
                                                  text=True, timeout=5).splitlines()
                    window = ids[0]
                    subprocess.run(['xdotool', 'windowfocus', window], check=True)
                    time.sleep(.3)
                    if action == 'key':
                        subprocess.run(['xdotool', 'key', 'Escape'], check=True)
                    elif action == 'click':
                        subprocess.run(['xdotool', 'mousemove', '--window', window, '100', '100',
                                        'click', '1'], check=True)
                    else:
                        # First motion may only establish a baseline; second must dismiss.
                        subprocess.run(['xdotool', 'mousemove', '--window', window, '100', '100'], check=True)
                        time.sleep(.1)
                        subprocess.run(['xdotool', 'mousemove', '--window', window, '130', '130'], check=True)
                    _, stderr = process.communicate(timeout=5)
                    assert process.returncode == 0, stderr
                    assert 'Gtk-CRITICAL' not in stderr, stderr
                    print(f'Native {action} dismissal passed')
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
        else:
            print('X11 input dismissal checks not run: require DISPLAY and xdotool.')
        peak_kib = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        print(f'Native smoke passed: {outputs[0][0]}x{outputs[0][1]}, repeat parity, '
              f'duration, SIGTERM. Child peak RSS: {peak_kib / 1024:.1f} MiB '
              '(Linux native viewer only; not a hardware comparison).')


if __name__ == '__main__':
    main()
