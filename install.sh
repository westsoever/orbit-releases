#!/usr/bin/env bash
# Install Orbit for macOS from a prebuilt release. Binary only — no source download or build step.
main() {
  set -eu
  export LC_ALL=C.UTF-8

  ORBIT_GITHUB_REPO="${ORBIT_GITHUB_REPO:-westsoever/orbit-releases}"
  ORBIT_VERSION="${ORBIT_VERSION:-}"
  ORBIT_NO_START="${ORBIT_NO_START:-}"

  APP_PATH="/Applications/Orbit.app"
  ORBIT_CLI="$APP_PATH/Contents/Resources/orbit"

  status() { echo ">>> $*" >&2; }
  error() { echo "ERROR: $*" >&2; exit 1; }

  if [ "$(uname -s)" != "Darwin" ]; then
    error "This installer is macOS-only."
  fi

  NEEDS=""
  for tool in curl unzip; do
    command -v "$tool" >/dev/null 2>&1 || NEEDS="$NEEDS $tool"
  done
  if [ -n "$NEEDS" ]; then
    error "Missing required tools:$NEEDS"
  fi

  TEMP_DIR="$(mktemp -d)"
  cleanup() { rm -rf "$TEMP_DIR"; }
  trap cleanup EXIT

  stop_running_orbit() {
    if curl -sf http://127.0.0.1:8765/health >/dev/null 2>&1; then
      status "Stopping running Orbit daemon…"
      if [ -x "$ORBIT_CLI" ]; then
        "$ORBIT_CLI" stop 2>/dev/null || true
      elif command -v orbit >/dev/null 2>&1; then
        orbit stop 2>/dev/null || true
      fi
      sleep 1
    fi
    if pgrep -x Orbit >/dev/null 2>&1; then
      status "Stopping Orbit app…"
      pkill -x Orbit 2>/dev/null || true
      sleep 1
    fi
  }

  resolve_version() {
    if [ -n "$ORBIT_VERSION" ]; then
      return 0
    fi
    status "Looking up latest release…"
    local tag
    tag="$(curl -fsSL "https://api.github.com/repos/${ORBIT_GITHUB_REPO}/releases/latest" \
      | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/')"
    [ -n "$tag" ] || error "Could not determine latest release. Set ORBIT_VERSION explicitly, e.g. ORBIT_VERSION=0.1.0"
    ORBIT_VERSION="$tag"
  }

  install_from_release() {
    local ver="$1"
    local url="https://github.com/${ORBIT_GITHUB_REPO}/releases/download/v${ver}/Orbit-darwin.zip"
    status "Downloading Orbit v${ver}…"
    curl --fail --show-error --location --progress-bar \
      -o "$TEMP_DIR/Orbit-darwin.zip" "$url"
    status "Installing Orbit to /Applications…"
    if [ -d "$APP_PATH" ]; then
      rm -rf "$APP_PATH"
    fi
    unzip -q "$TEMP_DIR/Orbit-darwin.zip" -d "$TEMP_DIR"
    [ -d "$TEMP_DIR/Orbit.app" ] || error "Orbit.app not found in release zip"
    mv "$TEMP_DIR/Orbit.app" "/Applications/"
  }

  status "Installing Orbit…"
  stop_running_orbit
  resolve_version
  install_from_release "$ORBIT_VERSION"

  [ -x "$ORBIT_CLI" ] || error "Install failed: CLI wrapper missing at $ORBIT_CLI"

  status "Adding 'orbit' command to PATH (may require password)…"
  if mkdir -p /usr/local/bin 2>/dev/null && ln -sf "$ORBIT_CLI" /usr/local/bin/orbit 2>/dev/null; then
    :
  elif sudo -n ln -sf "$ORBIT_CLI" /usr/local/bin/orbit 2>/dev/null; then
    :
  elif sudo ln -sf "$ORBIT_CLI" /usr/local/bin/orbit; then
    :
  else
    status "Could not link /usr/local/bin/orbit. Run manually:"
    status "  sudo ln -sf \"$ORBIT_CLI\" /usr/local/bin/orbit"
    status "Or use: \"$ORBIT_CLI\""
  fi

  if [ -z "$ORBIT_NO_START" ]; then
    status "Opening Orbit…"
    open -a Orbit
  fi

  status "Install complete. Open Orbit from Applications or run 'orbit'."
  status "First launch: if macOS blocks the app, right-click Orbit in Applications -> Open,"
  status "or run: xattr -cr /Applications/Orbit.app"
  status "Grant Accessibility to Orbit: System Settings -> Privacy & Security -> Accessibility."
  status "See docs/PERMISSIONS.md in this repo for details."
  status "User data directory: ~/.orbit/"
}

main "$@"
