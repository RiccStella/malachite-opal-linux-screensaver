# Malachite Opal Linux artwork screensaver

Display **Malachite Opal by Alchemist** in a separate Chromium kiosk window after inactivity. Supports a COSMIC/Wayland idle path using `swayidle`, plus an X11 idle path using `xprintidle`.

**This is decorative pre-lock artwork, not a secure screen locker.** Your desktop remains responsible for locking, blanking and suspend. The installer never disables those settings. If the native lock/blank timeout happens first, the artwork may not be visible. Configure the artwork timeout shorter than the native timeout if you want to see it.

## Install

Download and inspect before executing; don't run the installer with `sudo`:

```bash
curl --proto '=https' --tlsv1.2 -fL \
  https://raw.githubusercontent.com/RiccStella/malachite-opal-linux-screensaver/main/install.sh \
  -o install-malachite-opal.sh
less install-malachite-opal.sh
bash install-malachite-opal.sh
```

For reproducible installs, replace `main` in the URL with a reviewed full commit SHA. Downloading `main` always retrieves the latest code; HTTPS does not establish that its contents are safe.

If dependencies are missing, install them from your distribution's trusted package manager, or explicitly allow the installer to invoke it:

```bash
bash install-malachite-opal.sh --install-deps --timeout 120
```

Packages are Python 3, a native Chromium/Google Chrome executable, and `swayidle` on Wayland or `xprintidle` on X11. Existing browsers are reused **with a new private profile**, never your normal signed-in browser profile. Firefox is intentionally not treated as a Chromium drop-in.

Debian uses the `chromium` package. The installer checks package availability rather than guessing `chromium-browser`. Systems without a native Chromium package (including some Ubuntu/Pop!_OS configurations) should install a supported browser from a trusted source first. It does not silently add third-party repositories, install Snap/Flatpak, or disable browser sandboxing. Package installation errors stop installation. Arch uses `pacman -S --needed`, not a partial database refresh/upgrade.

Installation is per-user under `${XDG_DATA_HOME:-$HOME/.local/share}/malachite-opal`. A dedicated desktop autostart file is created for COSMIC, XFCE, MATE, LXDE and LXQt. Nothing is launched during installation; log out/in or start the daemon manually:

```bash
python3 ~/.local/share/malachite-opal/runner.py daemon
# Or a bounded manual preview:
python3 ~/.local/share/malachite-opal/runner.py preview
# Stop the running automatic supervisor and its own artwork browser:
python3 ~/.local/share/malachite-opal/runner.py quit
```

Use the path printed by the installer if you use a custom `XDG_DATA_HOME`. `--no-autostart` installs manual commands without enabling login startup. Re-running installation backs up this application's files as `.bak`; it never rewrites another screensaver's configuration. Quit an existing daemon before upgrading so it can restart using the new code.

## COSMIC and compatibility status

The Wayland path uses `swayidle` timeout/resume events, with its own empty configuration, to show and dismiss the artwork. COSMIC's compositor supports the idle notification mechanism used by its own `cosmic-idle`. Existing COSMIC locking remains enabled and independent; this application is not a replacement for `cosmic-idle` or the lock screen.

**Implemented, but not yet visually tested on a real COSMIC session.** Automated tests cover installation, configuration preservation, profile isolation, cleanup and mocked idle callbacks. They cannot establish compositor rendering, GPU behavior, multi-monitor placement, native lock visibility or input behavior. Other Wayland desktops are not automatically enabled. GNOME Wayland is not advertised as supported.

X11 uses `xprintidle` to detect idle/resume, rather than pretending a Chromium kiosk window is an embedded XScreenSaver module. No XScreenSaver dependency or configuration changes are required. The native locker must continue to provide password protection. Preview is a normal fullscreen browser window, normally on one display, and should not be expected to cover every monitor.

### COSMIC acceptance test before relying on autostart

1. Keep native locking enabled and confirm it works with the keyboard shortcut.
2. Run `runner.py preview`. Confirm the artwork renders and closes within 60 seconds.
3. Run the daemon in a terminal with a short timeout (`--timeout 15` during installation).
4. Stop input; confirm artwork appears. Move the mouse/type; confirm it disappears and your existing browser remains open.
5. While artwork is visible, lock the screen. Confirm the desktop's real lock screen is displayed and authentication is still required.
6. Test native automatic locking, suspend/resume, multi-monitor placement, repeated idle/resume and login autostart. Check for remaining browser processes after `quit`.
7. If any lock behavior differs, stop the daemon and disable its autostart with `--no-autostart`. Do not disable the native locker to work around it.

## Security boundaries

- No changes to GNOME/COSMIC lock, idle, blank or suspend settings.
- No root browser, `--no-sandbox`, `--disable-web-security`, personal cookies or extensions.
- Temporary mode-0700 browser profile in your private `XDG_RUNTIME_DIR`; it is removed on normal cleanup.
- Native Wayland browser backend on Wayland; process cleanup targets only the child process group this application created, never `pkill chromium`.
- Artwork is fetched from the external HTTPS FXHash gateway at runtime. That server and browser remain trust dependencies; its page and dependencies have **not** been audited or vendored. A separate profile does not prevent all network access or renderer vulnerabilities.
- An artwork window lasts at most 60 seconds to limit resource use and interference from web content. Native lock events and suspend events are also used for cleanup when supplied by `swayidle`. This does **not** prove a malicious web page cannot affect the desktop's idle timing; verify native locking with the acceptance test.
- Hard termination/power loss can leave a temporary profile until the runtime directory is cleared at logout. No persistent browser profile is reused.

## Upgrade from the original installer

The old installer disabled GNOME's lock and idle activation, changed `~/.xscreensaver`, and added `~/.config/autostart/xscreensaver.desktop`. **Installing this version does not silently undo those changes**, since you may have deliberately configured them afterward.

Review your native desktop's lock settings, restore your preferred lock policy, and remove the old Malachite Opal entry/autostart only if you no longer use it. The new installer warns if the old `~/malachite-opal-screensaver.sh` exists. Do not run both old and new artwork launchers together.

## Uninstall

```bash
bash install-malachite-opal.sh --uninstall
```

This stops the new supervisor and removes its runner, timeout and autostart file. Upgrade `.bak` files remain for recovery. System packages and native lock settings are left alone. It does not remove or alter legacy XScreenSaver files.

## Development checks

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
shellcheck install.sh
```

The local-socket integration test explicitly skips on hosts that prohibit Unix socket binding; run it on an ordinary Linux host/CI. Browser and idle commands in tests are mocks, not proof of COSMIC runtime compatibility.
