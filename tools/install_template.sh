#!/usr/bin/env bash
# Self-contained native per-user installer. Never changes screen-lock settings.
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
Installs native GTK/OpenGL decorative pre-lock artwork, NOT a screen locker.
COSMIC/Wayland uses swayidle; X11 uses xprintidle. No browser is required.
--install-deps allows trusted distro build/runtime packages (may ask for sudo).
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
[[ $DATA != *$'\n'* && $DATA != *$'\r'* && $DATA != *'%'* ]] || { echo 'Unsupported characters in installation path.' >&2; exit 1; }
[[ ! -L $DATA && ! -L $AUTO ]] || { echo 'Refusing symlink installation target.' >&2; exit 1; }
files=(runner.py timeout malachite-opal-viewer ARTWORK-NOTICE.md artwork.html)
for name in "${files[@]}"; do
  [[ ! -L $DATA/$name && ! -L $DATA/$name.bak ]] || { echo "Refusing symlink: $DATA/$name" >&2; exit 1; }
done
[[ ! -L $AUTO.bak ]] || { echo 'Refusing symlink autostart backup.' >&2; exit 1; }
stop_old() {
  if [[ -f $DATA/runner.py ]]; then
    command -v python3 >/dev/null || { echo 'Python is needed to stop the old daemon safely.' >&2; return 1; }
    if [[ -n ${XDG_RUNTIME_DIR:-} && -S $XDG_RUNTIME_DIR/malachite-opal/control.sock ]]; then
      python3 "$DATA/runner.py" quit
    fi
    # Wait for the supervisor to release its flock, not merely accept the message.
    python3 - <<'PY'
import fcntl, os, time
from pathlib import Path
runtime = os.environ.get('XDG_RUNTIME_DIR')
if runtime:
    path = Path(runtime) / 'malachite-opal/daemon.lock'
    if path.exists():
        with path.open('r') as lock:
            deadline = time.monotonic()+5
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic()>=deadline:
                        raise SystemExit('Old daemon did not stop; installation left unchanged.')
                    time.sleep(.1)
PY
  fi
}
if [[ ${action:-install} = uninstall ]]; then
  stop_old
  rm -f -- "$AUTO"
  for name in "${files[@]}"; do rm -f -- "$DATA/$name"; done
  rmdir -- "$DATA" 2>/dev/null || true
  echo 'Removed Malachite Opal files. Packages, native lock settings and legacy XScreenSaver files untouched.'
  exit 0
fi
missing=()
command -v python3 >/dev/null || missing+=(python3)
command -v cc >/dev/null || missing+=(compiler)
command -v pkg-config >/dev/null || missing+=(pkgconfig)
if ! command -v pkg-config >/dev/null || ! pkg-config --exists gtk+-3.0 epoxy; then missing+=(gtk-devel); fi
if [[ ${XDG_SESSION_TYPE:-} = wayland || -n ${WAYLAND_DISPLAY:-} ]]; then
  command -v swayidle >/dev/null || missing+=(swayidle)
elif [[ -n ${DISPLAY:-} ]]; then
  command -v xprintidle >/dev/null || missing+=(xprintidle)
fi
if ((${#missing[@]})); then
  if (( ! install_deps )); then
    echo "Missing dependencies: ${missing[*]}. Rerun with --install-deps or install Python, C compiler, pkg-config, GTK3/epoxy development packages and your idle tool." >&2
    exit 1
  fi
  command -v sudo >/dev/null || { echo 'sudo unavailable; ask your administrator to install build/runtime packages.' >&2; exit 1; }
  packages=()
  if command -v apt-get >/dev/null; then manager=apt
  elif command -v dnf >/dev/null; then manager=dnf
  elif command -v pacman >/dev/null; then manager=pacman
  else echo 'Unsupported package manager; install dependencies manually.' >&2; exit 1; fi
  for dep in "${missing[@]}"; do
    case "$manager:$dep" in
      apt:compiler|dnf:compiler|pacman:compiler) packages+=(gcc);;
      apt:pkgconfig) packages+=(pkg-config);;
      dnf:pkgconfig|pacman:pkgconfig) packages+=(pkgconf);;
      apt:gtk-devel) packages+=(libgtk-3-dev libepoxy-dev);;
      dnf:gtk-devel) packages+=(gtk3-devel libepoxy-devel);;
      pacman:gtk-devel) packages+=(gtk3 libepoxy);;
      pacman:python3) packages+=(python);;
      *) packages+=("$dep");;
    esac
  done
  case "$manager" in
    apt) sudo apt-get update; sudo apt-get install -- "${packages[@]}";;
    dnf) sudo dnf install -- "${packages[@]}";;
    pacman) sudo pacman -S --needed -- "${packages[@]}";;
  esac
fi
if ! command -v python3 >/dev/null || ! command -v cc >/dev/null || ! pkg-config --exists gtk+-3.0 epoxy; then
  echo 'Build dependencies are incomplete.' >&2; exit 1
fi
if [[ ${XDG_SESSION_TYPE:-} = wayland || -n ${WAYLAND_DISPLAY:-} ]]; then
  command -v swayidle >/dev/null || { echo 'swayidle is still missing.' >&2; exit 1; }
elif [[ -n ${DISPLAY:-} ]]; then
  command -v xprintidle >/dev/null || { echo 'xprintidle is still missing.' >&2; exit 1; }
fi
mkdir -p -- "$DATA" "$(dirname "$AUTO")"
stage=$(mktemp -d "$DATA/.install.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
# GENERATED PAYLOAD
# Build before touching a working installation, and never run the renderer here.
# shellcheck disable=SC2046
cc -std=c11 -O2 -Wall -Wextra -Werror "$stage/viewer.c" -o "$stage/malachite-opal-viewer" $(pkg-config --cflags --libs gtk+-3.0 epoxy) -lm
python3 - "$stage/runner.py" <<'PY'
import ast, sys
ast.parse(open(sys.argv[1]).read())
PY
chmod 700 "$stage/malachite-opal-viewer" "$stage/runner.py"
printf '%s\n' "$seconds" > "$stage/timeout"
# Stage a safely quoted desktop entry (including spaces and backslashes).
python3 - "$DATA/runner.py" "$stage/autostart.desktop" <<'PY'
import sys
path=sys.argv[1]
# Desktop Exec parsing has a second layer of backslash escaping.
quoted='"'+path.replace('\\','\\\\\\\\').replace('"','\\\\"').replace('`','\\\\`').replace('$','\\\\$')+'"'
open(sys.argv[2],'w').write('[Desktop Entry]\nType=Application\nName=Malachite Opal\nExec=python3 '+quoted+' daemon\nTerminal=false\nOnlyShowIn=COSMIC;XFCE;MATE;LXDE;LXQt;\n')
PY
stop_old
for name in "${files[@]}"; do
  if [[ -f $DATA/$name ]]; then cp -p -- "$DATA/$name" "$DATA/$name.bak"; fi
done
if [[ -f $AUTO ]]; then cp -p -- "$AUTO" "$AUTO.bak"; fi
for name in runner.py timeout malachite-opal-viewer ARTWORK-NOTICE.md; do mv -- "$stage/$name" "$DATA/$name"; done
rm -f -- "$DATA/artwork.html"
if ((autostart)); then mv -- "$stage/autostart.desktop" "$AUTO"; else rm -f -- "$AUTO"; fi
if [[ -e $HOME/malachite-opal-screensaver.sh ]]; then echo 'Legacy installer detected: review old XScreenSaver and lock settings yourself; they were not changed.'; fi
printf 'Installed native GTK/OpenGL viewer at %s\nPreview: python3 "%s/runner.py" preview\nLog out/in for autostart, or run: python3 "%s/runner.py" daemon\n' "$DATA" "$DATA" "$DATA"
echo 'No browser required. Keep native locking enabled. COSMIC idle/lock behavior still requires desktop testing.'
