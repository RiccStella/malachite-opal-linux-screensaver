#!/usr/bin/env bash
set -e

SAVER_NAME="Malachite Opal Screensaver"
URL="https://onchfs.fxhash2.xyz/c9355da324616274e112b28bf33d79c90ed8d79d32ff66f0e2bd77fc5350a2e3/"
SCRIPT_PATH="$HOME/malachite-opal-screensaver.sh"
CONF="$HOME/.xscreensaver"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/xscreensaver.desktop"

echo "==> Malachite Opal Linux screensaver installer"
echo "   This may ask for your password to install packages."

# --- Best-effort package install for major distros ---

if command -v dnf >/dev/null 2>&1; then
  echo "==> Detected Fedora / RHEL-like (dnf)"
  sudo dnf install -y xscreensaver xscreensaver-base xscreensaver-extras xscreensaver-extras-gss chromium || true
elif command -v apt-get >/dev/null 2>&1; then
  echo "==> Detected Debian / Ubuntu (apt)"
  sudo apt-get update
  sudo apt-get install -y xscreensaver xscreensaver-data-extra xscreensaver-gl-extra chromium-browser || true
elif command -v pacman >/dev/null 2>&1; then
  echo "==> Detected Arch / Manjaro (pacman)"
  sudo pacman -Sy --noconfirm xscreensaver chromium || true
else
  echo "!! Could not detect a known package manager (dnf/apt/pacman)."
  echo "   Please install XScreenSaver and a browser manually, then re-run this script."
fi

# --- Pick a browser command ---

BROWSER_CMD=""

for cmd in chromium chromium-browser google-chrome-stable google-chrome firefox; do
  if command -v "$cmd" >/dev/null 2>&1; then
    BROWSER_CMD="$cmd"
    break
  fi
done

if [ -z "$BROWSER_CMD" ]; then
  echo "!! No supported browser found (chromium / firefox / chrome)."
  echo "   Please install one, then re-run this script."
  exit 1
fi

echo "==> Using browser: $BROWSER_CMD"

# --- Create the screensaver runner script ---

cat > "$SCRIPT_PATH" <<EOF
#!/usr/bin/env bash
"$BROWSER_CMD" --kiosk --noerrdialogs --disable-infobars "$URL"
EOF

chmod +x "$SCRIPT_PATH"
echo "==> Created saver script at $SCRIPT_PATH"

# --- Disable GNOME's own blanker if present (so XScreenSaver wins) ---

if command -v gsettings >/dev/null 2>&1; then
  echo "==> Disabling GNOME blank screen / screensaver (if any)"
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
  gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null || true
  gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
fi

# --- Ensure XScreenSaver autostarts on login ---

mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Exec=xscreensaver -nosplash
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=XScreenSaver
EOF

echo "==> Created autostart entry at $AUTOSTART_FILE"

# --- Ensure ~/.xscreensaver exists ---

if [ ! -f "$CONF" ]; then
  echo "==> Generating initial ~/.xscreensaver configuration"
  xscreensaver -nosplash >/dev/null 2>&1 &
  sleep 1
  xscreensaver-command -exit >/dev/null 2>&1 || true
fi

if [ ! -f "$CONF" ]; then
  echo "!! Could not create $CONF. Is X11/XScreenSaver available?"
  exit 1
fi

# --- Make sure there is a programs: section ---

grep -q "^programs:" "$CONF" 2>/dev/null || echo -e "\nprograms:\n" >> "$CONF"

# --- Add our saver entry if missing ---

if ! grep -q "$SAVER_NAME" "$CONF" 2>/dev/null; then
  echo "==> Adding $SAVER_NAME to XScreenSaver programs"
  # Insert immediately after the 'programs:' line
  sed -i "/^programs:/a \  \"$SAVER_NAME\"  $SCRIPT_PATH \\\\" "$CONF"
fi

# --- Force XScreenSaver to use only this saver ---

if grep -q "^mode:" "$CONF"; then
  sed -i "s/^mode:.*/mode: one/" "$CONF"
else
  echo "mode: one" >> "$CONF"
fi

if grep -q "^selected:" "$CONF"; then
  sed -i "s/^selected:.*/selected: 0/" "$CONF"
else
  echo "selected: 0" >> "$CONF"
fi

if grep -q "^name:" "$CONF"; then
  sed -i "s/^name:.*/name: $SAVER_NAME/" "$CONF"
else
  echo "name: $SAVER_NAME" >> "$CONF"
fi

# --- Restart XScreenSaver so changes apply immediately ---

if xscreensaver-command -version >/dev/null 2>&1; then
  xscreensaver-command -restart >/dev/null 2>&1 || xscreensaver -nosplash &
else
  xscreensaver -nosplash &
fi

echo
echo "✅ Done!"
echo "Malachite Opal should now run automatically as your screensaver after inactivity."
echo "You can also test it manually with:  xscreensaver-command -activate"
