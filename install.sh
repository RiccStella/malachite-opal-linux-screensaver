#!/usr/bin/env bash
# Self-contained per-user installer. Does not change screen-lock settings.
set -euo pipefail
umask 077
ID=malachite-opal
install_deps=0
autostart=1
seconds=120
usage() {
  cat <<'HELP'
Usage: bash install.sh [--install-deps] [--no-autostart] [--timeout SECONDS]
                     [--uninstall] [--help]
Installs a decorative pre-lock artwork viewer, NOT a screen locker.
COSMIC/Wayland automatic mode uses swayidle; X11 uses xprintidle.
Missing packages are installed only with --install-deps (may ask for sudo).
Existing screen-lock settings and XScreenSaver configuration are never changed.
HELP
}
while (($#)); do
  case "$1" in
    --install-deps) install_deps=1;;
    --no-autostart) autostart=0;;
    --timeout) shift; seconds=${1:?Missing timeout};;
    --uninstall) action=uninstall;;
    --help|-h) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
  shift
done
if [[ ! $seconds =~ ^[0-9]{1,5}$ ]] || ((10#$seconds < 10 || 10#$seconds > 86400)); then
  echo 'Timeout must be 10–86400 seconds.' >&2; exit 2
fi
((EUID != 0)) || { echo 'Run as your normal desktop user, not root.' >&2; exit 1; }
: "${HOME:?HOME is required}"
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/$ID
AUTO=${XDG_CONFIG_HOME:-$HOME/.config}/autostart/$ID.desktop
[[ $DATA = /* && $AUTO = /* ]] || { echo 'XDG paths must be absolute.' >&2; exit 1; }
# Reject desktop-entry metacharacters we cannot represent safely.
[[ $DATA != *$'\n'* && $DATA != *$'\r'* && $DATA != *'%'* ]] || { echo 'Unsupported characters in installation path.' >&2; exit 1; }
[[ ! -L $DATA && ! -L $AUTO ]] || { echo 'Refusing symlink installation target.' >&2; exit 1; }
if [[ ${action:-install} = uninstall ]]; then
  if [[ -f $DATA/runner.py ]] && command -v python3 >/dev/null; then python3 "$DATA/runner.py" quit || true; fi
  rm -f -- "$AUTO" "$DATA/runner.py" "$DATA/timeout" "$DATA/artwork.html" "$DATA/ARTWORK-NOTICE.md"
  rmdir -- "$DATA" 2>/dev/null || true
  echo 'Removed Malachite Opal files. Native lock settings and legacy XScreenSaver files were not touched.'
  exit 0
fi
browser() { local c; for c in chromium chromium-browser google-chrome-stable google-chrome; do command -v "$c" && return; done; return 1; }
missing=()
command -v python3 >/dev/null || missing+=(python3)
if ! browser >/dev/null; then missing+=(chromium); fi
if [[ ${XDG_SESSION_TYPE:-} = wayland || -n ${WAYLAND_DISPLAY:-} ]]; then
  command -v swayidle >/dev/null || missing+=(swayidle)
elif [[ -n ${DISPLAY:-} ]]; then
  command -v xprintidle >/dev/null || missing+=(xprintidle)
fi
if ((${#missing[@]})); then
  if (( ! install_deps )); then
    echo "Missing dependencies: ${missing[*]}. Install from your distro's trusted packages or rerun with --install-deps." >&2
    exit 1
  fi
  command -v sudo >/dev/null || { echo 'sudo is unavailable; install dependencies with your system administrator.' >&2; exit 1; }
  if command -v apt-get >/dev/null; then
    sudo apt-get update
    # Check the actual repository, not a guessed Debian/Ubuntu package name.
    packages=()
    for p in "${missing[@]}"; do
      if [[ $p = chromium ]]; then
        candidate=$(apt-cache policy chromium | awk '/Candidate:/ {print $2; exit}')
        [[ -n $candidate && $candidate != '(none)' ]] || { echo 'No native chromium package. Install Chromium/Chrome from a trusted source, then rerun. No Snap or third-party repo is added automatically.' >&2; exit 1; }
      fi
      packages+=("$p")
    done
    sudo apt-get install -- "${packages[@]}"
  elif command -v dnf >/dev/null; then
    sudo dnf install -- "${missing[@]}"
  elif command -v pacman >/dev/null; then
    # Do not refresh package databases without a full upgrade (partial upgrades).
    packages=("${missing[@]/python3/python}")
    sudo pacman -S --needed -- "${packages[@]}"
  else
    echo "Unsupported package manager. Install: ${missing[*]}" >&2; exit 1
  fi
fi
if ! command -v python3 >/dev/null || ! browser >/dev/null; then
  echo 'Dependency installation incomplete.' >&2; exit 1
fi
if [[ ${XDG_SESSION_TYPE:-} = wayland || -n ${WAYLAND_DISPLAY:-} ]]; then
  command -v swayidle >/dev/null || { echo 'swayidle is still missing.' >&2; exit 1; }
elif [[ -n ${DISPLAY:-} ]]; then
  command -v xprintidle >/dev/null || { echo 'xprintidle is still missing.' >&2; exit 1; }
fi
mkdir -p -- "$DATA" "$(dirname "$AUTO")"
# Only our own files are replaced; keep an upgrade backup.
for file in "$DATA/runner.py" "$DATA/timeout" "$DATA/artwork.html" "$DATA/ARTWORK-NOTICE.md" "$AUTO"; do
  [[ ! -L $file && ! -L $file.bak ]] || { echo "Refusing symlink: $file" >&2; exit 1; }
  if [[ -f $file ]]; then cp -p -- "$file" "$file.bak"; fi
done
stage=$(mktemp "$DATA/.runner.XXXXXX")
trap 'rm -f -- "$stage"' EXIT
cat > "$stage" <<'PY'
#!/usr/bin/env python3
"""Decorative browser viewer. Never a lock screen or authentication boundary."""
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
import tempfile
import time

URL = Path(__file__).with_name('artwork.html').resolve().as_uri()
MAX_DISPLAY_SECONDS = 60
BROWSERS = ('chromium', 'chromium-browser', 'google-chrome-stable', 'google-chrome')


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


def browser_command(profile):
    browser = next((shutil.which(c) for c in BROWSERS if shutil.which(c)), None)
    if not browser:
        raise RuntimeError('Install native Chromium or Google Chrome first.')
    command = [browser, '--user-data-dir=' + profile, '--no-first-run',
               '--no-default-browser-check', '--disable-sync', '--disable-extensions',
               '--disable-background-networking',
               '--incognito', '--kiosk']
    if os.environ.get('WAYLAND_DISPLAY'):
        command.append('--ozone-platform=wayland')
    return command + [URL]


class Viewer:
    def __init__(self):
        self.process = None
        self.profile = None
        self.started = 0

    def start(self):
        if self.process is not None:
            return  # Repeated idle events must not spawn additional browsers.
        self.profile = tempfile.TemporaryDirectory(prefix='profile-', dir=runtime_dir())
        try:
            self.process = subprocess.Popen(browser_command(self.profile.name), start_new_session=True)
            self.started = time.monotonic()
        except BaseException:
            self.profile.cleanup()
            self.profile = None
            raise

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
        if self.profile is not None:
            self.profile.cleanup()
            self.profile = None

    def tick(self):
        if self.process is not None and (self.exited() or
                time.monotonic() - self.started >= MAX_DISPLAY_SECONDS):
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
    # flock prevents two supervisors from sharing callbacks or browser state.
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
        raise RuntimeError('Do not run the artwork browser as root.')
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
PY
python3 - "$stage" <<'PY'
import ast, sys
with open(sys.argv[1]) as source:
    ast.parse(source.read())
PY
chmod 700 "$stage"
mv -- "$stage" "$DATA/runner.py"
printf '%s\n' "$seconds" > "$DATA/timeout"
# BEGIN GENERATED OFFLINE ARTWORK
python3 - "$DATA/artwork.html" <<'ARTWORK_PY'
import base64, hashlib, os, sys, tempfile
data = base64.b64decode('CjwhRE9DVFlQRSBodG1sPgo8aHRtbCBsYW5nPSJlbiI+CjxoZWFkPgogICAgPG1ldGEgY2hhcnNldD0iVVRGLTgiPgogICAgPCEtLSBNYWxhY2hpdGUgT3BhbCBieSBSaWNjYXJkbyBTdGVsbGEgKEFsY2hlbWlzdCkuCiAgICAgICAgIEFkYXB0ZWQgZnJvbSB0aGUgYXV0aG9yJ3MgNTg5YXJjYWRlLmNvbSBjb3B5IGZvciBvZmZsaW5lIHNjcmVlbnNhdmVyIHVzZS4KICAgICAgICAgRlhIYXNoIHNlZWRpbmcgcmVwbGFjZWQgd2l0aCBNYXRoLnJhbmRvbTsgbm8gZXh0ZXJuYWwgU0RLIGlzIGJ1bmRsZWQuIC0tPgogICAgPG1ldGEgaHR0cC1lcXVpdj0iQ29udGVudC1TZWN1cml0eS1Qb2xpY3kiIGNvbnRlbnQ9ImRlZmF1bHQtc3JjICdub25lJzsgc2NyaXB0LXNyYyAndW5zYWZlLWlubGluZSc7IHN0eWxlLXNyYyAndW5zYWZlLWlubGluZSc7IGltZy1zcmMgZGF0YTo7IGNvbm5lY3Qtc3JjICdub25lJzsgb2JqZWN0LXNyYyAnbm9uZSc7IGJhc2UtdXJpICdub25lJzsgZm9ybS1hY3Rpb24gJ25vbmUnIj4KICAgIDxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MS4wIj4KICAgIDx0aXRsZT5NYWxhY2hpdGUgT3BhbDwvdGl0bGU+CiAgICA8c3R5bGU+CiAgICAgICAgYm9keSB7IG1hcmdpbjogMDsgb3ZlcmZsb3c6IGhpZGRlbjsgYmFja2dyb3VuZDogYmxhY2s7IH0KICAgICAgICBjYW52YXMgeyBkaXNwbGF5OiBibG9jazsgd2lkdGg6IDEwMHZ3OyBoZWlnaHQ6IDEwMHZoOyB9CiAgICA8L3N0eWxlPgo8L2hlYWQ+Cgo8Ym9keT4KICAgIDxjYW52YXMgaWQ9IndlYmdsLWNhbnZhcyI+PC9jYW52YXM+CgogICAgPHNjcmlwdD4KICAgICAgICAvLyBBZGp1c3QgY2FudmFzIHNpemUKCgogICAgICAgIC8vIEhTTCB0byBSR0IgY29udmVyc2lvbgogICAgICAgIGZ1bmN0aW9uIGhzbFRvUmdiKGgsIHMsIGwpIHsKICAgICAgICAgICAgaCAvPSAzNjA7CiAgICAgICAgICAgIGxldCByLCBnLCBiOwoKICAgICAgICAgICAgaWYgKHMgPT09IDApIHsKICAgICAgICAgICAgICAgIHIgPSBnID0gYiA9IGw7IC8vIEFjaHJvbWF0aWMKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIGNvbnN0IGh1ZTJyZ2IgPSAocCwgcSwgdCkgPT4gewogICAgICAgICAgICAgICAgICAgIGlmICh0IDwgMCkgdCArPSAxOwogICAgICAgICAgICAgICAgICAgIGlmICh0ID4gMSkgdCAtPSAxOwogICAgICAgICAgICAgICAgICAgIGlmICh0IDwgMSAvIDYpIHJldHVybiBwICsgKHEgLSBwKSAqIDYgKiB0OwogICAgICAgICAgICAgICAgICAgIGlmICh0IDwgMSAvIDIpIHJldHVybiBxOwogICAgICAgICAgICAgICAgICAgIGlmICh0IDwgMiAvIDMpIHJldHVybiBwICsgKHEgLSBwKSAqICgyIC8gMyAtIHQpICogNjsKICAgICAgICAgICAgICAgICAgICByZXR1cm4gcDsKICAgICAgICAgICAgICAgIH07CgogICAgICAgICAgICAgICAgY29uc3QgcSA9IGwgPCAwLjUgPyBsICogKDEgKyBzKSA6IGwgKyBzIC0gbCAqIHM7CiAgICAgICAgICAgICAgICBjb25zdCBwID0gMiAqIGwgLSBxOwogICAgICAgICAgICAgICAgciA9IGh1ZTJyZ2IocCwgcSwgaCArIDEgLyAzKTsKICAgICAgICAgICAgICAgIGcgPSBodWUycmdiKHAsIHEsIGgpOwogICAgICAgICAgICAgICAgYiA9IGh1ZTJyZ2IocCwgcSwgaCAtIDEgLyAzKTsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgcmV0dXJuIFtyLCBnLCBiXTsKICAgICAgICB9CgogICAgICAgIC8vIEdlbmVyYXRlIFN0ZWxsYSBjb2xvcnMKICAgICAgICBmdW5jdGlvbiBnZW5lcmF0ZVN0ZWxsYUNvbG9ycygpIHsKICAgICAgICAgICAgY29uc3QgY2VudGVySHVlID0gTWF0aC5yYW5kb20oKSAqIDM2MDsgLy8gUmFuZG9tIGNlbnRlciBodWUKICAgICAgICAgICAgY29uc3QgcmFuZ2UgPSAzNjAgKiBNYXRoLnJhbmRvbSgpOyAvLyBSYW5nZSBvZiDCsTM2MMKwCiAgICAgICAgICAgIGNvbnN0IGh1ZXMgPSBbCiAgICAgICAgICAgICAgICBjZW50ZXJIdWUsCiAgICAgICAgICAgICAgICAoY2VudGVySHVlICsgcmFuZ2UpICUgMzYwLAogICAgICAgICAgICAgICAgKGNlbnRlckh1ZSAtIHJhbmdlICsgMzYwKSAlIDM2MAogICAgICAgICAgICBdOwoKICAgICAgICAgICAgLy8gQ29udmVydCBodWVzIHRvIFJHQgogICAgICAgICAgICByZXR1cm4gaHVlcy5tYXAoaCA9PiBoc2xUb1JnYihoLCAxLCAwLjUpKTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IHZlcnRleFNoYWRlclNvdXJjZSA9IGAKICAgICAgICBhdHRyaWJ1dGUgdmVjNCBhX3Bvc2l0aW9uOwogICAgICAgIHZvaWQgbWFpbigpIHsKICAgICAgICAgICAgZ2xfUG9zaXRpb24gPSBhX3Bvc2l0aW9uOwogICAgICAgIH1gCiAgICAgICAgOwoKICAgICAgICBjb25zdCBmcmFnbWVudFNoYWRlclNvdXJjZSA9IGAKICAgICAgICNpZmRlZiBHTF9GUkFHTUVOVF9QUkVDSVNJT05fSElHSApwcmVjaXNpb24gaGlnaHAgZmxvYXQ7CiNlbHNlCnByZWNpc2lvbiBtZWRpdW1wIGZsb2F0OwojZW5kaWYKdW5pZm9ybSB2ZWMyIGlSZXNvbHV0aW9uOwp1bmlmb3JtIGZsb2F0IGlUaW1lOwp1bmlmb3JtIGZsb2F0IHRlbnRhY2xlQ291bnQ7CnVuaWZvcm0gZmxvYXQgYmxvYlNlZWQ7CnVuaWZvcm0gdmVjMyBjb2xvckE7CnVuaWZvcm0gdmVjMyBjb2xvckI7CnVuaWZvcm0gdmVjMyBjb2xvckM7CgpmbG9hdCByYW5kb20odmVjMiBzdCkgewogICAgcmV0dXJuIGZyYWN0KHNpbihkb3Qoc3QueHksIHZlYzIoMTIuOTg5OCwgNzguMjMzKSkpICogNDM3NTguNTQ1MzEyMyk7Cn0KCmZsb2F0IHNtb290aE5vaXNlKHZlYzIgc3QpIHsKICAgIHZlYzIgaSA9IGZsb29yKHN0KTsKICAgIHZlYzIgZiA9IGZyYWN0KHN0KTsKICAgIGYgPSBmICogZiAqICgzLjAgLSAyLjAgKiBmKTsKCiAgICBmbG9hdCBhID0gcmFuZG9tKGkpOwogICAgZmxvYXQgYiA9IHJhbmRvbShpICsgdmVjMigxLjAsIDAuMCkpOwogICAgZmxvYXQgYyA9IHJhbmRvbShpICsgdmVjMigwLjAsIDEuMCkpOwogICAgZmxvYXQgZCA9IHJhbmRvbShpICsgdmVjMigxLjAsIDEuMCkpOwoKICAgIHJldHVybiBtaXgobWl4KGEsIGIsIGYueCksIG1peChjLCBkLCBmLngpLCBmLnkpOwp9Cgp2b2lkIG1haW5JbWFnZShvdXQgdmVjNCBmcmFnQ29sb3IsIGluIHZlYzIgZnJhZ0Nvb3JkKSB7CiAgICBmbG9hdCB0aW1lID0gaVRpbWUgKiAwLjM7CnZlYzIgdXYgPSAoc2luKHRpbWUvYmxvYlNlZWQrMy4wKmJsb2JTZWVkKSsyLjApKigxMi4wKSAvIDEwMC4wICogKGZyYWdDb29yZCAtIGlSZXNvbHV0aW9uLnh5IC8gMi4wKSAvIGlSZXNvbHV0aW9uLnkgCiAgICAgICAgIC0gdmVjMihzbW9vdGhOb2lzZSh2ZWMyKHRpbWUgLyAxMC4wKzEwMDAuMCwgYmxvYlNlZWQpKSAtIDAuNSwgCiAgICAgICAgICAgICAgICBzbW9vdGhOb2lzZSh2ZWMyKHRpbWUgLyAxMC4wICsgYmxvYlNlZWQsIGJsb2JTZWVkICsgMTAwLjApKSAtIDAuNSk7Ci8vIENvbXB1dGUgZHluYW1pYyByb3RhdGlvbiBhbmdsZSB1c2luZyBzbW9vdGggbm9pc2UKZmxvYXQgdGhldGEgPSAzLjAqc21vb3RoTm9pc2UodmVjMih0aW1lL2Jsb2JTZWVkIC0gYmxvYlNlZWQsIGJsb2JTZWVkKSk7CgovLyAyRCBSb3RhdGlvbiBNYXRyaXgKbWF0MiByb3RNYXQgPSBtYXQyKAogICAgY29zKHRoZXRhKSwgLXNpbih0aGV0YSksCiAgICBzaW4odGhldGEpLCBjb3ModGhldGEpCik7CgovLyBBcHBseSByb3RhdGlvbiB0byBVViBjb29yZGluYXRlcwp1diAqPSByb3RNYXQ7CgoKICAgIC8vICoqUkFESUFMIE1FTFRJTkcgRUZGRUNUKioKICAgIGZsb2F0IG1lbHRTdHJlbmd0aCA9ICBzaW4odGltZS82LjArYmxvYlNlZWQpKjAuNSpibG9iU2VlZCAvMTAwLjA7IC8vIEFkanVzdCBmb3Igc3Ryb25nZXIgbWVsdGluZwogICAgZmxvYXQgbWVsdFNwZWVkID0gMC4xICogMTAwLjAgLzEwMC4wOyAvLyBDb250cm9scyBob3cgZmFzdCBpdCAiZHJpcHMiCiAgICAKICAgIC8vIE1ha2UgdGhlIGRpc3RvcnRpb24gKipyYWRpYXRlIGZyb20gdGhlIGNlbnRlcioqCnZlYzIgbWVsdE9mZnNldCA9IG5vcm1hbGl6ZSh1dikgKiAoc21vb3RoTm9pc2UodXYgKiAxMDAuMCArIG1lbHRTcGVlZCAqIDEwMC4wIC8gMTAwLjApLTAuNSkgKiBtZWx0U3RyZW5ndGg7CiAgICAKICAgIC8vIEFwcGx5IG1lbHRpbmcgZGlzdG9ydGlvbgogICAgdXYgKz0gbWVsdE9mZnNldDsKCiAgICBmbG9hdCBhbmdsZSA9IGF0YW4odXYueSwgdXYueCk7CiAgICBmbG9hdCByYWRpdXMgPSBsZW5ndGgodXYpICsgc21vb3RoTm9pc2UodXYgKiAxMC4wICsgYmxvYlNlZWQgKTsKICAgIGZsb2F0IGRpc3RvcnRlZEFuZ2xlID0gYW5nbGUgKiB0ZW50YWNsZUNvdW50ICsgKHNtb290aE5vaXNlKHZlYzIocmFkaXVzICogMTAuMCwgYmxvYlNlZWQgKSktMC41KSA7CiAgICBmbG9hdCB6b29tID0gKHJhZGl1cyAtIDIuMCAqIDEuNSwgMS4wKSArIChzbW9vdGhOb2lzZSh1diAqIDEuMCArIGJsb2JTZWVkICktMC41KSAqIDAuMiA7CgogICAgZmxvYXQgcGFydGljbGVXYXZlID0gc2luKGRpc3RvcnRlZEFuZ2xlIC0gem9vbSAqIDE1MC4wICogKHNtb290aE5vaXNlKHV2ICogMTAuMCArIGJsb2JTZWVkICsgdGltZSkpLTAuNSkgKiBibG9iU2VlZCArIDEuMDsKICAgIGZsb2F0IGludGVuc2l0eSA9IDAuNSArIHBhcnRpY2xlV2F2ZSAqIGV4cCgtcmFkaXVzICogMi41KSAqIDAuNSogKChzbW9vdGhOb2lzZSh1diAqIDIuMCArIGJsb2JTZWVkICsgdGltZSkpLTAuNSk7CgogICAgLy8gKipBUFBMWSBISUdILUZSRVFVRU5DWSBQSVhFTCBOT0lTRSoqCiAgICBmbG9hdCBwaXhlbE5vaXNlID0gcmFuZG9tKHV2ICogaVJlc29sdXRpb24ueHkpICogMC43OyAvLyBBZGp1c3Qgbm9pc2Ugc3RyZW5ndGgKCiAgICB2ZWMzIGNvbG9yID0gbWl4KGNvbG9yQSwgY29sb3JCLCBpbnRlbnNpdHkpOwogICAgY29sb3IgPSBtaXgoY29sb3IsIGNvbG9yQywgc21vb3RoTm9pc2UodXYgKiAxNTAuMCAqIGJsb2JTZWVkICogc2luKCh0aW1lK2Jsb2JTZWVkKS9ibG9iU2VlZC8oMTAuMCkpICAgKyA0LjAgKyBibG9iU2VlZC8xMDAuMCkpOwogICAgY29sb3IgKz0gcGl4ZWxOb2lzZSpibG9iU2VlZCpzaW4odGltZS9ibG9iU2VlZCtibG9iU2VlZCsxNTg5LjApLzEwMC4wOyAvLyBBZGQgcGl4ZWwgbm9pc2UgbGF5ZXIKCiAgICBmcmFnQ29sb3IgPSB2ZWM0KGNvbG9yICogaW50ZW5zaXR5LCBibG9iU2VlZC8xMDAuMCk7Cn0KCnZvaWQgbWFpbigpIHsKICAgIG1haW5JbWFnZShnbF9GcmFnQ29sb3IsIGdsX0ZyYWdDb29yZC54eSk7Cn1gCgoKICAgICAgICA7CgogICAgICAgIGZ1bmN0aW9uIGNyZWF0ZVNoYWRlcihnbCwgdHlwZSwgc291cmNlKSB7CiAgICAgICAgICAgIGNvbnN0IHNoYWRlciA9IGdsLmNyZWF0ZVNoYWRlcih0eXBlKTsKICAgICAgICAgICAgZ2wuc2hhZGVyU291cmNlKHNoYWRlciwgc291cmNlKTsKICAgICAgICAgICAgZ2wuY29tcGlsZVNoYWRlcihzaGFkZXIpOwogICAgICAgICAgICBpZiAoIWdsLmdldFNoYWRlclBhcmFtZXRlcihzaGFkZXIsIGdsLkNPTVBJTEVfU1RBVFVTKSkgewogICAgICAgICAgICAgICAgY29uc29sZS5lcnJvcigiU2hhZGVyIGNvbXBpbGUgZXJyb3I6IiwgZ2wuZ2V0U2hhZGVySW5mb0xvZyhzaGFkZXIpKTsKICAgICAgICAgICAgICAgIGdsLmRlbGV0ZVNoYWRlcihzaGFkZXIpOwogICAgICAgICAgICAgICAgcmV0dXJuIG51bGw7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuIHNoYWRlcjsKICAgICAgICB9CgogICAgICAgIGZ1bmN0aW9uIGNyZWF0ZVByb2dyYW0oZ2wsIHZlcnRleFNoYWRlciwgZnJhZ21lbnRTaGFkZXIpIHsKICAgICAgICAgICAgY29uc3QgcHJvZ3JhbSA9IGdsLmNyZWF0ZVByb2dyYW0oKTsKICAgICAgICAgICAgZ2wuYXR0YWNoU2hhZGVyKHByb2dyYW0sIHZlcnRleFNoYWRlcik7CiAgICAgICAgICAgIGdsLmF0dGFjaFNoYWRlcihwcm9ncmFtLCBmcmFnbWVudFNoYWRlcik7CiAgICAgICAgICAgIGdsLmxpbmtQcm9ncmFtKHByb2dyYW0pOwogICAgICAgICAgICBpZiAoIWdsLmdldFByb2dyYW1QYXJhbWV0ZXIocHJvZ3JhbSwgZ2wuTElOS19TVEFUVVMpKSB7CiAgICAgICAgICAgICAgICBjb25zb2xlLmVycm9yKCJQcm9ncmFtIGxpbmsgZXJyb3I6IiwgZ2wuZ2V0UHJvZ3JhbUluZm9Mb2cocHJvZ3JhbSkpOwogICAgICAgICAgICAgICAgZ2wuZGVsZXRlUHJvZ3JhbShwcm9ncmFtKTsKICAgICAgICAgICAgICAgIHJldHVybiBudWxsOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHJldHVybiBwcm9ncmFtOwogICAgICAgIH0KCiAgICAgICAgZnVuY3Rpb24gbWFpbigpIHsKICAgICAgICAgICAgY29uc3QgY2FudmFzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoIndlYmdsLWNhbnZhcyIpOwogICAgICAgICAgICBjb25zdCBnbCA9IGNhbnZhcy5nZXRDb250ZXh0KCJ3ZWJnbCIpOwoKICAgICAgICAgICAgaWYgKCFnbCkgewogICAgICAgICAgICAgICAgdGhyb3cgbmV3IEVycm9yKCJXZWJHTCBpcyBub3QgYXZhaWxhYmxlIGZvciB0aGlzIGFydHdvcmsuIik7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgd2luZG93LmFyY2FkZVdhbGxSdW50aW1lPy5yZWdpc3RlckNvbnRleHQoZ2wpOwoKICAgICAgICAgICAgLy9jYW52YXMud2lkdGggPSB3aW5kb3cuaW5uZXJXaWR0aDsKICAgICAgICAgICAgLy9jYW52YXMuaGVpZ2h0ID0gd2luZG93LmlubmVySGVpZ2h0OwogICAgICAgICAgICBnbC52aWV3cG9ydCgwLCAwLCBnbC5kcmF3aW5nQnVmZmVyV2lkdGgsIGdsLmRyYXdpbmdCdWZmZXJIZWlnaHQpOwoKICAgICAgICAgICAgY29uc3Qgc3RlbGxhQ29sb3JzID0gZ2VuZXJhdGVTdGVsbGFDb2xvcnMoKTsgLy8gR2VuZXJhdGUgY29sb3JzCgogICAgICAgICAgICBjb25zdCByYW5kb21UZW50YWNsZUNvdW50ID0gTWF0aC5mbG9vcihNYXRoLnJhbmRvbSgpICogMTEpICsgMjsKICAgICAgICAgICAgY29uc3QgcmFuZG9tQmxvYlNlZWQgPSBNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkqOTApKzEwOwoKICAgICAgICAgICAgY29uc3QgdmVydGV4U2hhZGVyID0gY3JlYXRlU2hhZGVyKGdsLCBnbC5WRVJURVhfU0hBREVSLCB2ZXJ0ZXhTaGFkZXJTb3VyY2UpOwogICAgICAgICAgICBjb25zdCBmcmFnbWVudFNoYWRlciA9IGNyZWF0ZVNoYWRlcihnbCwgZ2wuRlJBR01FTlRfU0hBREVSLCBmcmFnbWVudFNoYWRlclNvdXJjZSk7CiAgICAgICAgICAgIGNvbnN0IHByb2dyYW0gPSBjcmVhdGVQcm9ncmFtKGdsLCB2ZXJ0ZXhTaGFkZXIsIGZyYWdtZW50U2hhZGVyKTsKICAgICAgICAgICAgZ2wudXNlUHJvZ3JhbShwcm9ncmFtKTsKCiAgICAgICAgICAgIGNvbnN0IHBvc2l0aW9uQnVmZmVyID0gZ2wuY3JlYXRlQnVmZmVyKCk7CiAgICAgICAgICAgIGdsLmJpbmRCdWZmZXIoZ2wuQVJSQVlfQlVGRkVSLCBwb3NpdGlvbkJ1ZmZlcik7CiAgICAgICAgICAgIGNvbnN0IHBvc2l0aW9ucyA9IFsKICAgICAgICAgICAgICAgIC0xLCAtMSwKICAgICAgICAgICAgICAgIDEsIC0xLAogICAgICAgICAgICAgICAgLTEsICAxLAogICAgICAgICAgICAgICAgLTEsICAxLAogICAgICAgICAgICAgICAgMSwgLTEsCiAgICAgICAgICAgICAgICAxLCAgMQogICAgICAgICAgICBdOwogICAgICAgICAgICBnbC5idWZmZXJEYXRhKGdsLkFSUkFZX0JVRkZFUiwgbmV3IEZsb2F0MzJBcnJheShwb3NpdGlvbnMpLCBnbC5TVEFUSUNfRFJBVyk7CgogICAgICAgICAgICBjb25zdCBwb3NpdGlvbkF0dHJpYnV0ZSA9IGdsLmdldEF0dHJpYkxvY2F0aW9uKHByb2dyYW0sICJhX3Bvc2l0aW9uIik7CiAgICAgICAgICAgIGdsLmVuYWJsZVZlcnRleEF0dHJpYkFycmF5KHBvc2l0aW9uQXR0cmlidXRlKTsKICAgICAgICAgICAgZ2wudmVydGV4QXR0cmliUG9pbnRlcihwb3NpdGlvbkF0dHJpYnV0ZSwgMiwgZ2wuRkxPQVQsIGZhbHNlLCAwLCAwKTsKCiAgICAgICAgICAgIGNvbnN0IGlSZXNvbHV0aW9uTG9jYXRpb24gPSBnbC5nZXRVbmlmb3JtTG9jYXRpb24ocHJvZ3JhbSwgImlSZXNvbHV0aW9uIik7CiAgICAgICAgICAgIGNvbnN0IGlUaW1lTG9jYXRpb24gPSBnbC5nZXRVbmlmb3JtTG9jYXRpb24ocHJvZ3JhbSwgImlUaW1lIik7CiAgICAgICAgICAgIGNvbnN0IHRlbnRhY2xlQ291bnRMb2NhdGlvbiA9IGdsLmdldFVuaWZvcm1Mb2NhdGlvbihwcm9ncmFtLCAidGVudGFjbGVDb3VudCIpOwogICAgICAgICAgICBjb25zdCBibG9iU2VlZExvY2F0aW9uID0gZ2wuZ2V0VW5pZm9ybUxvY2F0aW9uKHByb2dyYW0sICJibG9iU2VlZCIpOwogICAgICAgICAgICBjb25zdCBjb2xvckFMb2NhdGlvbiA9IGdsLmdldFVuaWZvcm1Mb2NhdGlvbihwcm9ncmFtLCAiY29sb3JBIik7CiAgICAgICAgICAgIGNvbnN0IGNvbG9yQkxvY2F0aW9uID0gZ2wuZ2V0VW5pZm9ybUxvY2F0aW9uKHByb2dyYW0sICJjb2xvckIiKTsKICAgICAgICAgICAgY29uc3QgY29sb3JDTG9jYXRpb24gPSBnbC5nZXRVbmlmb3JtTG9jYXRpb24ocHJvZ3JhbSwgImNvbG9yQyIpOwoKICAgICAgICAgICAgZ2wudW5pZm9ybTNmdihjb2xvckFMb2NhdGlvbiwgc3RlbGxhQ29sb3JzWzBdKTsKICAgICAgICAgICAgZ2wudW5pZm9ybTNmdihjb2xvckJMb2NhdGlvbiwgc3RlbGxhQ29sb3JzWzFdKTsKICAgICAgICAgICAgZ2wudW5pZm9ybTNmdihjb2xvckNMb2NhdGlvbiwgc3RlbGxhQ29sb3JzWzJdKTsKCiAgICAgICAgICAgIGZ1bmN0aW9uIHJlbmRlcih0aW1lKSB7CiAgICAgICAgICAgICAgICB0aW1lICo9IDAuMDAxOwogICAgICAgICAgICAgICAgZ2wudW5pZm9ybTJmKGlSZXNvbHV0aW9uTG9jYXRpb24sIGNhbnZhcy53aWR0aCwgY2FudmFzLmhlaWdodCk7CiAgICAgICAgICAgICAgICBnbC51bmlmb3JtMWYoaVRpbWVMb2NhdGlvbiwgdGltZSk7CiAgICAgICAgICAgICAgICBnbC51bmlmb3JtMWYodGVudGFjbGVDb3VudExvY2F0aW9uLCByYW5kb21UZW50YWNsZUNvdW50KTsKICAgICAgICAgICAgICAgIGdsLnVuaWZvcm0xZihibG9iU2VlZExvY2F0aW9uLCByYW5kb21CbG9iU2VlZCk7CiAgICAgICAgICAgICAgICBnbC5kcmF3QXJyYXlzKGdsLlRSSUFOR0xFUywgMCwgNik7CiAgICAgICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUocmVuZGVyKTsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKHJlbmRlcik7CiAgICAgICAgfQoKICAgICAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigibG9hZCIsIG1haW4pOwogICAgICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoImtleWRvd24iLCBmdW5jdGlvbiAoZXZlbnQpIHsKICAgIGlmIChldmVudC5rZXkgPT09ICJzIikgewogICAgICAgIHNhdmVDYW52YXNJbWFnZSgpOwogICAgfQp9KTsKCmZ1bmN0aW9uIHNhdmVDYW52YXNJbWFnZSgpIHsKICAgIGNvbnN0IGNhbnZhcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJ3ZWJnbC1jYW52YXMiKTsKICAgIGNvbnN0IGdsID0gY2FudmFzLmdldENvbnRleHQoIndlYmdsIik7CgogICAgLy8gQ3JlYXRlIGEgZnJhbWVidWZmZXIKICAgIGNvbnN0IGZyYW1lYnVmZmVyID0gZ2wuY3JlYXRlRnJhbWVidWZmZXIoKTsKICAgIGdsLmJpbmRGcmFtZWJ1ZmZlcihnbC5GUkFNRUJVRkZFUiwgZnJhbWVidWZmZXIpOwoKICAgIC8vIENyZWF0ZSBhIHRleHR1cmUgdG8gcmVuZGVyIGludG8KICAgIGNvbnN0IHRleHR1cmUgPSBnbC5jcmVhdGVUZXh0dXJlKCk7CiAgICBnbC5iaW5kVGV4dHVyZShnbC5URVhUVVJFXzJELCB0ZXh0dXJlKTsKICAgIGdsLnRleEltYWdlMkQoZ2wuVEVYVFVSRV8yRCwgMCwgZ2wuUkdCQSwgY2FudmFzLndpZHRoLCBjYW52YXMuaGVpZ2h0LCAwLCBnbC5SR0JBLCBnbC5VTlNJR05FRF9CWVRFLCBudWxsKTsKICAgIGdsLnRleFBhcmFtZXRlcmkoZ2wuVEVYVFVSRV8yRCwgZ2wuVEVYVFVSRV9NSU5fRklMVEVSLCBnbC5MSU5FQVIpOwogICAgZ2wudGV4UGFyYW1ldGVyaShnbC5URVhUVVJFXzJELCBnbC5URVhUVVJFX01BR19GSUxURVIsIGdsLkxJTkVBUik7CgogICAgLy8gQXR0YWNoIHRoZSB0ZXh0dXJlIHRvIHRoZSBmcmFtZWJ1ZmZlcgogICAgZ2wuZnJhbWVidWZmZXJUZXh0dXJlMkQoZ2wuRlJBTUVCVUZGRVIsIGdsLkNPTE9SX0FUVEFDSE1FTlQwLCBnbC5URVhUVVJFXzJELCB0ZXh0dXJlLCAwKTsKCiAgICAvLyBDcmVhdGUgYSByZW5kZXJidWZmZXIgZm9yIGRlcHRoCiAgICBjb25zdCByZW5kZXJidWZmZXIgPSBnbC5jcmVhdGVSZW5kZXJidWZmZXIoKTsKICAgIGdsLmJpbmRSZW5kZXJidWZmZXIoZ2wuUkVOREVSQlVGRkVSLCByZW5kZXJidWZmZXIpOwogICAgZ2wucmVuZGVyYnVmZmVyU3RvcmFnZShnbC5SRU5ERVJCVUZGRVIsIGdsLkRFUFRIX0NPTVBPTkVOVDE2LCBjYW52YXMud2lkdGgsIGNhbnZhcy5oZWlnaHQpOwogICAgZ2wuZnJhbWVidWZmZXJSZW5kZXJidWZmZXIoZ2wuRlJBTUVCVUZGRVIsIGdsLkRFUFRIX0FUVEFDSE1FTlQsIGdsLlJFTkRFUkJVRkZFUiwgcmVuZGVyYnVmZmVyKTsKCiAgICAvLyBDaGVjayBmcmFtZWJ1ZmZlciBzdGF0dXMKICAgIGlmIChnbC5jaGVja0ZyYW1lYnVmZmVyU3RhdHVzKGdsLkZSQU1FQlVGRkVSKSAhPT0gZ2wuRlJBTUVCVUZGRVJfQ09NUExFVEUpIHsKICAgICAgICBjb25zb2xlLmVycm9yKCJGcmFtZWJ1ZmZlciBpcyBub3QgY29tcGxldGUuIik7CiAgICAgICAgcmV0dXJuOwogICAgfQoKICAgIC8vIFJlbmRlciB0byBmcmFtZWJ1ZmZlcgogICAgZ2wuY2xlYXIoZ2wuQ09MT1JfQlVGRkVSX0JJVCB8IGdsLkRFUFRIX0JVRkZFUl9CSVQpOwogICAgZ2wuZHJhd0FycmF5cyhnbC5UUklBTkdMRVMsIDAsIDYpOwoKICAgIC8vIFJlYWQgcGl4ZWxzCiAgICBjb25zdCBwaXhlbHMgPSBuZXcgVWludDhBcnJheShjYW52YXMud2lkdGggKiBjYW52YXMuaGVpZ2h0ICogNCk7CiAgICBnbC5yZWFkUGl4ZWxzKDAsIDAsIGNhbnZhcy53aWR0aCwgY2FudmFzLmhlaWdodCwgZ2wuUkdCQSwgZ2wuVU5TSUdORURfQllURSwgcGl4ZWxzKTsKCiAgICAvLyBSZXN0b3JlIGRlZmF1bHQgZnJhbWVidWZmZXIKICAgIGdsLmJpbmRGcmFtZWJ1ZmZlcihnbC5GUkFNRUJVRkZFUiwgbnVsbCk7CgogICAgLy8gRmxpcCBpbWFnZSB2ZXJ0aWNhbGx5IChXZWJHTCBzdG9yZXMgcGl4ZWxzIGJvdHRvbS11cCkKICAgIGNvbnN0IGZsaXBwZWRQaXhlbHMgPSBuZXcgVWludDhBcnJheShjYW52YXMud2lkdGggKiBjYW52YXMuaGVpZ2h0ICogNCk7CiAgICBmb3IgKGxldCByb3cgPSAwOyByb3cgPCBjYW52YXMuaGVpZ2h0OyByb3crKykgewogICAgICAgIGNvbnN0IHNyY1N0YXJ0ID0gcm93ICogY2FudmFzLndpZHRoICogNDsKICAgICAgICBjb25zdCBkZXN0U3RhcnQgPSAoY2FudmFzLmhlaWdodCAtIHJvdyAtIDEpICogY2FudmFzLndpZHRoICogNDsKICAgICAgICBmbGlwcGVkUGl4ZWxzLnNldChwaXhlbHMuc3ViYXJyYXkoc3JjU3RhcnQsIHNyY1N0YXJ0ICsgY2FudmFzLndpZHRoICogNCksIGRlc3RTdGFydCk7CiAgICB9CgogICAgLy8gQ3JlYXRlIGFuIG9mZnNjcmVlbiBjYW52YXMgdG8gc3RvcmUgdGhlIGltYWdlCiAgICBjb25zdCBvZmZzY3JlZW5DYW52YXMgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCJjYW52YXMiKTsKICAgIG9mZnNjcmVlbkNhbnZhcy53aWR0aCA9IGNhbnZhcy53aWR0aDsKICAgIG9mZnNjcmVlbkNhbnZhcy5oZWlnaHQgPSBjYW52YXMuaGVpZ2h0OwogICAgY29uc3QgY3R4ID0gb2Zmc2NyZWVuQ2FudmFzLmdldENvbnRleHQoIjJkIik7CgogICAgLy8gQ3JlYXRlIEltYWdlRGF0YSBhbmQgcHV0IGl0IG9uIHRoZSBvZmZzY3JlZW4gY2FudmFzCiAgICBjb25zdCBpbWFnZURhdGEgPSBuZXcgSW1hZ2VEYXRhKG5ldyBVaW50OENsYW1wZWRBcnJheShmbGlwcGVkUGl4ZWxzKSwgY2FudmFzLndpZHRoLCBjYW52YXMuaGVpZ2h0KTsKICAgIGN0eC5wdXRJbWFnZURhdGEoaW1hZ2VEYXRhLCAwLCAwKTsKCiAgICAvLyBDcmVhdGUgZG93bmxvYWQgbGluawogICAgY29uc3QgbGluayA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoImEiKTsKICAgIGxpbmsuaHJlZiA9IG9mZnNjcmVlbkNhbnZhcy50b0RhdGFVUkwoImltYWdlL3BuZyIpOwogICAgbGluay5kb3dubG9hZCA9ICJtYWxhY2hpdGVPcGFsLnBuZyI7CiAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKGxpbmspOwogICAgbGluay5jbGljaygpOwogICAgZG9jdW1lbnQuYm9keS5yZW1vdmVDaGlsZChsaW5rKTsKCiAgICAvLyBDbGVhbnVwIFdlYkdMIHJlc291cmNlcwogICAgZ2wuZGVsZXRlRnJhbWVidWZmZXIoZnJhbWVidWZmZXIpOwogICAgZ2wuZGVsZXRlVGV4dHVyZSh0ZXh0dXJlKTsKICAgIGdsLmRlbGV0ZVJlbmRlcmJ1ZmZlcihyZW5kZXJidWZmZXIpOwp9CndpbmRvdy5hZGRFdmVudExpc3RlbmVyKCJyZXNpemUiLCAoKSA9PiB7CiAgICBpbml0KCk7Cn0pOwpmdW5jdGlvbiBpbml0KCl7CiAgICBjb25zdCBjYW52YXMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgid2ViZ2wtY2FudmFzIik7CiAgICBjb25zdCBnbCA9IGNhbnZhcy5nZXRDb250ZXh0KCJ3ZWJnbCIpOwogICAgaWYgKCFnbCkgdGhyb3cgbmV3IEVycm9yKCJXZWJHTCBpcyBub3QgYXZhaWxhYmxlIGZvciB0aGlzIGFydHdvcmsuIik7CgogICAgLy8gVXBkYXRlIGNhbnZhcyBzaXplCiAgICBjYW52YXMud2lkdGggPSB3aW5kb3cuaW5uZXJXaWR0aDsKICAgIGNhbnZhcy5oZWlnaHQgPSB3aW5kb3cuaW5uZXJIZWlnaHQ7CgogICAgLy8gVXBkYXRlIFdlYkdMIHZpZXdwb3J0CiAgICBnbC52aWV3cG9ydCgwLCAwLCBjYW52YXMud2lkdGgsIGNhbnZhcy5oZWlnaHQpOwoKICAgIC8vIFRoZSByZW5kZXIgbG9vcCB1cGRhdGVzIGlSZXNvbHV0aW9uIGFmdGVyIHRoZSBzaGFkZXIgcHJvZ3JhbSBpcyByZWFkeS4KfQppbml0KCk7CiAgICA8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==', validate=True)
if hashlib.sha256(data).hexdigest() != '48ac42b0f8ad0163fe4333582ab098279e303959319da0204c6491bb94064086':
    raise SystemExit('Embedded artwork checksum mismatch')
fd, stage = tempfile.mkstemp(dir=os.path.dirname(sys.argv[1]))
try:
    with os.fdopen(fd, 'wb') as output:
        output.write(data)
    os.replace(stage, sys.argv[1])
finally:
    if os.path.exists(stage): os.unlink(stage)
ARTWORK_PY
python3 - "$DATA/ARTWORK-NOTICE.md" <<'ARTWORK_PY'
import base64, hashlib, os, sys, tempfile
data = base64.b64decode('IyBBcnR3b3JrIGF0dHJpYnV0aW9uCgoqKk1hbGFjaGl0ZSBPcGFsIGJ5IFJpY2NhcmRvIFN0ZWxsYSAoQWxjaGVtaXN0KSoqLgoKQnVuZGxlZCBhdCB0aGUgcmVwb3NpdG9yeSBvd25lcidzIGRpcmVjdGlvbiBmcm9tIHRoZWlyIGV4aXN0aW5nIGhvc3RlZCBjb3B5IGF0IGh0dHBzOi8vNTg5YXJjYWRlLmNvbS9hc3NldHMvYXJ0L3pvb21pbmcvaW5kZXguaHRtbCAocmV0cmlldmVkIDIwMjYtMTEtMTcpLiBSaWNjYXJkbyBjb25maXJtZWQgdGhhdCBoZSBpcyBBbGNoZW1pc3QgYW5kIGF1dGhvcml6ZWQgdGhpcyBidW5kbGVkIGNvcHkuIE9yaWdpbmFsIGFydGlzdCBhdHRyaWJ1dGlvbiBpcyBwcmVzZXJ2ZWQ7IHRoaXMgbm90aWNlIGRvZXMgbm90IGNoYW5nZSB0aGUgYXJ0d29yaydzIGxpY2Vuc2luZyB0ZXJtcy4KCk9mZmxpbmUgYWRhcHRhdGlvbiByZW1vdmVzIHRoZSBhcmNhZGUtd2FsbCBoZWxwZXIgKGEgbm8tb3Agd2hlbiBzdGFuZGFsb25lKSBhbmQgdGhlIEZYSGFzaCBTREsuIENhbGxzIHRvIGAkZngucmFuZCgpYCBhcmUgcmVwbGFjZWQgd2l0aCBgTWF0aC5yYW5kb20oKWAuIFRoZSB2aXN1YWwgYWxnb3JpdGhtIGFuZCBzaGFkZXIgYXJlIHJldGFpbmVkOyByYW5kb20gc2VlZCByZXByb2R1Y2liaWxpdHkgYW5kIG1pbnRlZCBGWEhhc2ggbWV0YWRhdGEgYXJlIG5vdC4gTm8gdGhpcmQtcGFydHkgRlhIYXNoIFNESyBjb2RlIGlzIGJ1bmRsZWQuCgpBIHJlc3RyaWN0aXZlIENvbnRlbnQgU2VjdXJpdHkgUG9saWN5IGRpc2FsbG93cyBuZXR3b3JrIGNvbm5lY3Rpb25zIGFuZCBleHRlcm5hbCBzY3JpcHRzL3Jlc291cmNlcy4gVGhpcyBjb3B5IGlzIHVwZGF0ZWQgdGhyb3VnaCByZXZpZXdlZCByZXBvc2l0b3J5IGNoYW5nZXMsIG5vdCBmZXRjaGVkIGF0IGFjdGl2YXRpb24uCg==', validate=True)
if hashlib.sha256(data).hexdigest() != '30943d76280a4c7e6a041213ac1db740451d64a36ceb84f8403e2b3173e4ef3f':
    raise SystemExit('Embedded artwork checksum mismatch')
fd, stage = tempfile.mkstemp(dir=os.path.dirname(sys.argv[1]))
try:
    with os.fdopen(fd, 'wb') as output:
        output.write(data)
    os.replace(stage, sys.argv[1])
finally:
    if os.path.exists(stage): os.unlink(stage)
ARTWORK_PY
# END GENERATED OFFLINE ARTWORK
if ((autostart)); then
  # Escape Desktop Entry Exec argument syntax without invoking a shell.
  python3 - "$DATA/runner.py" "$AUTO" <<'PY'
import os, sys, tempfile
path, destination = sys.argv[1:]
def quote(value):
    value = value.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$')
    # General desktop-entry escaping is decoded before Exec escaping.
    return '"' + value.replace('\\', '\\\\') + '"'
text = ('[Desktop Entry]\nType=Application\nName=Malachite Opal artwork\n'
        'Comment=Decorative pre-lock artwork; does not replace screen locking\n'
        'Exec=' + quote(sys.executable) + ' ' + quote(path) + ' daemon\n'
        'OnlyShowIn=COSMIC;XFCE;MATE;LXDE;LXQt;\nTerminal=false\n')
fd, stage = tempfile.mkstemp(dir=os.path.dirname(destination))
try:
    with os.fdopen(fd, 'w') as output:
        output.write(text)
    os.replace(stage, destination)
finally:
    if os.path.exists(stage): os.unlink(stage)
PY
else
  rm -f -- "$AUTO"
fi
printf 'Installed. Preview: python3 %q preview\n' "$DATA/runner.py"
printf 'Automatic mode: python3 %q daemon\n' "$DATA/runner.py"
echo 'Autostart takes effect at the next supported desktop login (unless --no-autostart). Nothing has been launched now.'
echo 'Existing native lock/blank/suspend settings are unchanged. Set artwork timeout shorter than native lock timeout if desired.'
echo 'Artwork closes after at most 60 seconds. This is NOT a screen locker.'
if [[ -f $HOME/malachite-opal-screensaver.sh ]]; then
  echo 'Legacy installer detected: review its GNOME lock changes and XScreenSaver autostart manually. They were not reset or removed.'
fi
