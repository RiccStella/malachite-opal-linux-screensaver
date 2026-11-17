# Malachite Opal native Linux screensaver

**Malachite Opal by Riccardo Stella (Alchemist)**, rendered directly with GTK3 and OpenGL. No Chromium, webview, JavaScript engine or browser profile is launched. A small Python supervisor handles idle/resume and process cleanup; it does not render pixels.

This is **decorative pre-lock artwork, not a secure screen locker**. Keep your desktop's own lock, blanking and suspend settings enabled. No installer or viewer code changes them. The window normally occupies one display, not every monitor.

## Install or upgrade

The same one-line command works, including `--install-deps` when dependencies are missing:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/RiccStella/malachite-opal-linux-screensaver/main/install.sh) --install-deps
```

For safer review, download `install.sh`, inspect it, then run it as your normal desktop user. Never prefix the whole command with sudo. Replace `main` with a reviewed full commit SHA for reproducible installation.

The self-contained installer embeds the native source and shader, compiles locally, and only then replaces its own files. It needs Python 3, a C compiler, pkg-config, GTK3 and libepoxy development packages, plus `swayidle` on Wayland or `xprintidle` on X11. Development packages are needed because the one-file installer builds for your own CPU/distribution rather than downloading an opaque prebuilt binary.

`--install-deps` uses only the existing apt, dnf or pacman repositories and their normal confirmation prompts. It does not add repositories, install Snap/Flatpak, remove packages, alter security settings or silently upgrade Arch's package database. Debian/Ubuntu/Pop!_OS package names include `gcc pkg-config libgtk-3-dev libepoxy-dev`; Fedora uses `gcc pkgconf gtk3-devel libepoxy-devel`; Arch uses `gcc pkgconf gtk3 libepoxy`.

Per-user installation: `${XDG_DATA_HOME:-$HOME/.local/share}/malachite-opal`. Before replacement, an existing supervisor is told to quit and its lock is awaited. Its own previous files are retained as `.bak`. Existing Chromium packages and unrelated applications are left alone. A separately started preview is bounded to 60 seconds; close it before upgrading.

```bash
# Preview immediately (closes on input, or within 60 seconds):
python3 ~/.local/share/malachite-opal/runner.py preview
# Start idle monitoring now, or log out/in for autostart:
python3 ~/.local/share/malachite-opal/runner.py daemon
# Stop automatic monitoring and its own artwork:
python3 ~/.local/share/malachite-opal/runner.py quit
```

Use the paths printed by the installer with custom XDG directories. Configure inactivity with `--timeout 120` (10–86400 seconds). `--no-autostart` removes this application's login entry, without touching other startup entries. The installer never starts the viewer itself. Autostart applies to COSMIC, XFCE, MATE, LXDE and LXQt; other Wayland desktops, especially GNOME, are not advertised as supported.

## Performance and artwork fidelity

The original procedural shader is preserved, translated from WebGL GLSL to desktop GLSL 150. A generated header is checked against `artwork/index.html`; color generation and tentacle/blob distributions match the offline artwork. Colors vary each run; minted FXHash seed reproduction is not supported. Output alpha is made opaque because there is no HTML page beneath the native surface. The original web canvas over black leaves RGB unchanged under its default premultiplied-alpha contract.

Animation is capped at approximately **30 FPS**, with elapsed-time motion independent of frame rate. This lowers animation work but does not promise a particular RAM/CPU reduction. On HiDPI displays the shader renders at logical resolution and is upscaled to the native surface, matching the original web canvas’s resolution policy instead of multiplying shader work by the scale factor squared. Very large logical displays still require substantial shader work. There is no continuously growing image cache or per-frame readback in ordinary operation.

Each launch prints `GL_RENDERER` and `GL_VERSION`. `llvmpipe`, `softpipe` or `SwiftShader` indicates software rendering, which can still be CPU-intensive even without a browser. A native rewrite cannot fix missing GPU drivers by itself. Benchmarks on a cloud software renderer are not predictions for Andrew's hardware.

Advanced manual diagnostics:

```bash
~/.local/share/malachite-opal/malachite-opal-viewer --windowed --fps 30 --duration 10
```

Normal launches terminate on key, button, scroll or pointer movement, and after at most 60 seconds. There are no input grabs, idle inhibitors, network requests or secure-lock claims. The Python supervisor also enforces the duration limit and cleans up only the child process group it created.

## COSMIC acceptance test

Native rendering and COSMIC integration are separate checks. A successful preview does not establish correct idle activation or lock interaction. Before relying on autostart:

1. Keep native locking enabled and verify the desktop's lock shortcut.
2. Run preview. Check image, GL renderer, memory, CPU and input dismissal.
3. Install with `--timeout 15`, start daemon, stop input and verify activation. Move/type and verify dismissal.
4. Lock while visible; verify the real lock screen appears and requires authentication.
5. Test automatic lock, suspend/resume, repeated idle/resume, multi-monitor placement and login autostart.
6. Run `quit`; confirm its renderer is gone and unrelated apps remain open.

If lock behavior differs, stop the daemon and remove its autostart with `--no-autostart`. Never disable the native locker as a workaround. The former browser preview worked on Andrew's COSMIC system; this **new native implementation still needs a real COSMIC test**.

## Legacy installer and uninstall

The original XScreenSaver installer changed lock settings and `~/.xscreensaver`; this version deliberately does not silently undo user settings. Review that legacy setup yourself if `~/malachite-opal-screensaver.sh` exists. Do not run both launchers.

```bash
bash install.sh --uninstall
```

Uninstall stops the automatic supervisor and removes only its current files/autostart. `.bak` recovery files, installed distro packages, legacy XScreenSaver files and desktop settings remain.

## Development

```bash
python3 tools/generate_shader.py --check
python3 tools/bundle_artwork.py --check
bash -n install.sh
shellcheck install.sh tools/build_native.sh tools/install_template.sh
python3 -m unittest discover -s tests -v
bash tools/build_native.sh
xvfb-run -a python3 tools/smoke_native.py
```

Edit `native/` and `tools/install_template.sh`, then regenerate shader/installer. The automated GTK smoke test uses Mesa software rendering, deterministic seed/time capture, bounded execution and RSS reporting. Unit tests use mock build/idle tools; the Unix-socket test skips only where the host explicitly prohibits sockets. CI runs it on an ordinary Linux host. Neither test suite establishes actual COSMIC compositor behavior or real-GPU performance.
