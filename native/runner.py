#!/usr/bin/env python3
"""Decorative native viewer. Never a lock screen or authentication boundary."""
import fcntl
import os
from pathlib import Path
import selectors
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time

VIEWER = Path(__file__).with_name('malachite-opal-viewer').resolve()
MAX_DISPLAY_SECONDS = 60


def runtime_dir():
    base = Path(os.environ.get('XDG_RUNTIME_DIR', ''))
    if not base.is_absolute():
        raise RuntimeError('A desktop XDG_RUNTIME_DIR is required.')
    info = base.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('XDG_RUNTIME_DIR must be a private directory owned by you.')
    folder = base / 'malachite-opal'
    folder.mkdir(mode=0o700, exist_ok=True)
    info = folder.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('Unsafe runtime directory.')
    return folder


def viewer_command():
    if not VIEWER.is_file() or not os.access(VIEWER, os.X_OK):
        raise RuntimeError('Native viewer missing; rerun the installer.')
    return [str(VIEWER)]


class Viewer:
    def __init__(self):
        self.process = None
        self.started = 0

    def start(self):
        if self.process is not None:
            return  # Repeated idle events must not spawn additional viewers.
        runtime_dir()  # Validate desktop session ownership before launching.
        self.process = subprocess.Popen(viewer_command(), start_new_session=True)
        self.started = time.monotonic()

    def exited(self):
        # Do not reap the leader before group cleanup: its reserved PID prevents
        # an unrelated process group from reusing the ID after a wrapper exits.
        return os.waitid(os.P_PID, self.process.pid,
                         os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None

    def stop(self):
        process, self.process = self.process, None
        if process is not None:
            # The leader is still our unreaped child, even if a wrapper exited.
            # Always clean the group, including children that ignored SIGTERM.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            time.sleep(0.2)
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

    def tick(self):
        if self.process is not None:
            if self.exited():
                process = self.process
                self.stop()
                if process.returncode:
                    raise RuntimeError(f'Native viewer exited ({process.returncode}); check its GL diagnostics above.')
            elif time.monotonic() - self.started >= MAX_DISPLAY_SECONDS:
                self.stop()


def send(action):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        try:
            client.connect(str(runtime_dir() / 'control.sock'))
        except (FileNotFoundError, ConnectionRefusedError):
            return
        client.sendall(action.encode('ascii'))


def daemon():
    wayland = bool(os.environ.get('WAYLAND_DISPLAY'))
    if not wayland and not os.environ.get('DISPLAY'):
        raise RuntimeError('A Wayland or X11 desktop session is required.')
    executable = shutil.which('swayidle' if wayland else 'xprintidle')
    if not executable:
        raise RuntimeError('Install swayidle (Wayland) or xprintidle (X11).')
    seconds = int(Path(__file__).with_name('timeout').read_text().strip())
    if not 10 <= seconds <= 86400:
        raise RuntimeError('Invalid timeout.')
    folder = runtime_dir()
    # flock prevents two supervisors from sharing callbacks or viewer state.
    with open(folder / 'daemon.lock', 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        sockpath = folder / 'control.sock'
        sockpath.unlink(missing_ok=True)
        viewer = Viewer()
        alive = True
        def shutdown(*_):
            nonlocal alive
            alive = False
        signal.signal(signal.SIGTERM, shutdown)
        signal.signal(signal.SIGINT, shutdown)
        prefix = shlex.join([sys.executable, str(Path(__file__).resolve())])
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server, selectors.DefaultSelector() as selector:
            server.bind(str(sockpath))
            os.chmod(sockpath, 0o600)
            server.listen(4)
            selector.register(server, selectors.EVENT_READ)
            # Ignore the user's unrelated swayidle configuration. No -w: callbacks
            # must not block dispatch of the resume event.
            idle = subprocess.Popen([executable, '-C', '/dev/null', 'timeout', str(seconds),
                                     prefix + ' start', 'resume', prefix + ' stop',
                                     'before-sleep', prefix + ' stop', 'lock', prefix + ' stop']) if wayland else None
            was_idle = False
            previous_idle = 0
            try:
                while alive:
                    if idle is not None:
                        status = idle.poll()
                        if status is not None:
                            raise RuntimeError(f'swayidle exited ({status}); compositor/protocol support must be checked.')
                    else:
                        result = subprocess.run([executable], check=True, capture_output=True, text=True, timeout=2)
                        current_idle = int(result.stdout.strip())
                        if current_idle < previous_idle:
                            viewer.stop()
                            was_idle = False
                        if current_idle >= seconds * 1000 and not was_idle:
                            viewer.start()
                            was_idle = True
                        previous_idle = current_idle
                    for _, _ in selector.select(timeout=0.5):
                        with server.accept()[0] as client:
                            client.settimeout(0.2)
                            try:
                                action = client.recv(16)
                            except socket.timeout:
                                continue
                            if action == b'start':
                                viewer.start()
                            elif action == b'stop':
                                viewer.stop()
                            elif action == b'quit':
                                alive = False
                    viewer.tick()
            finally:
                viewer.stop()
                if idle is not None and idle.poll() is None:
                    idle.terminate()
                    try:
                        idle.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        idle.kill()
                        idle.wait()
                sockpath.unlink(missing_ok=True)


def main():
    if os.geteuid() == 0:
        raise RuntimeError('Do not run the artwork viewer as root.')
    action = sys.argv[1] if len(sys.argv) == 2 else 'help'
    if action in ('start', 'stop', 'quit'):
        send(action)
    elif action == 'daemon':
        daemon()
    elif action == 'preview':
        viewer = Viewer()
        def interrupted(*_):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, interrupted)
        try:
            viewer.start()
            while viewer.process is not None:
                time.sleep(0.2)
                viewer.tick()
        finally:
            viewer.stop()
    else:
        print('Usage: runner.py {preview|daemon|stop|quit}')
        return 2
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Malachite Opal: {error}', file=sys.stderr)
        sys.exit(1)
