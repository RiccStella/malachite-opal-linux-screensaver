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
  rm -f -- "$AUTO" "$DATA/runner.py" "$DATA/timeout"
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
for file in "$DATA/runner.py" "$DATA/timeout" "$AUTO"; do
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

URL = 'https://onchfs.fxhash2.xyz/c9355da324616274e112b28bf33d79c90ed8d79d32ff66f0e2bd77fc5350a2e3/'
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
