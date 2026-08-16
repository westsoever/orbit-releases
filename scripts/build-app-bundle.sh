#!/usr/bin/env bash
# Build a complete Orbit.app for /Applications (embedded Python venv + Swift UI).
# Pattern: scripts/run_orbit_access_app.sh bundle assembly; README.md Python venv setup.
set -euo pipefail
export LC_ALL=C.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=orbit_access_bundle_resources.sh
source "$ROOT/scripts/orbit_access_bundle_resources.sh"
SOURCE_ROOT="${ORBIT_SOURCE_ROOT:-$ROOT}"
APP_DIR="$SOURCE_ROOT/OrbitAccessApp"
ORBIT_OUTPUT="${ORBIT_OUTPUT:-}"
ORBIT_PYTHON="${ORBIT_PYTHON:-}"
ORBIT_SKIP_SWIFT="${ORBIT_SKIP_SWIFT:-0}"
SWIFT_CONFIG="release"
# Stamped into the bundle as OrbitBuildTime; a daemon whose started_at precedes it is older
# than this build. Taken up front so the long pip install does not skew it.
BUILD_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

status() { echo ">>> $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-app-bundle.sh --output /path/to/Orbit.app

Environment:
  ORBIT_SOURCE_ROOT   Repo root (default: parent of scripts/)
  ORBIT_PYTHON        Python 3.13 interpreter (auto-detected if unset)
  ORBIT_SKIP_SWIFT=1  Skip Swift build (Python-only bundle)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || usage
      ORBIT_OUTPUT="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -n "$ORBIT_OUTPUT" ]] || usage

# Normalise --output to an absolute path before anything uses it. The build cds into
# the Swift package directory (`cd "$APP_DIR"` below) to run `swift build`, so a
# RELATIVE output path silently starts resolving against a different directory
# part-way through: the bundle skeleton gets created next to the caller's cwd, then
# the binary copy fails with
#   cp: <path>/Contents/MacOS/Orbit: No such file or directory
# after several minutes of compiling. `.github/workflows/release.yml` passed a bare
# `Orbit.app`, so the release build hit exactly this.
#
# Resolved by hand rather than with `realpath`/`readlink -f`: the target does not
# exist yet (that is the point), and macOS `readlink` has no -f.
case "$ORBIT_OUTPUT" in
  /*) ;;
  *)
    # `|| true` is load-bearing under `set -e` (line 4): when the cd fails the
    # substitution exits non-zero, which would abort the script right here — silently,
    # before the guard below can say why. Swallow it so the error message survives.
    _out_parent="$(cd "$(dirname "$ORBIT_OUTPUT")" 2>/dev/null && pwd)" || true
    # Check the resolved PARENT, not the joined result. An unreadable parent makes
    # the subshell print nothing, and naively joining that empty string would yield
    # "/Orbit.app" — an absolute path pointing at the filesystem root, which then
    # sails past any "is it absolute?" test and gets rm -rf'd later.
    [[ -n "$_out_parent" ]] || error "--output parent directory does not exist: $(dirname "$ORBIT_OUTPUT")"
    ORBIT_OUTPUT="$_out_parent/$(basename "$ORBIT_OUTPUT")"
    unset _out_parent
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  error "Orbit.app builds are macOS-only."
fi

for tool in swift git; do
  command -v "$tool" >/dev/null 2>&1 || error "Required tool not found: $tool"
done

if [[ "$ORBIT_SKIP_SWIFT" != "1" ]]; then
  command -v swift >/dev/null 2>&1 || error "swift is required (set ORBIT_SKIP_SWIFT=1 to skip)"
fi

resolve_python() {
  if [[ -n "$ORBIT_PYTHON" ]]; then
    echo "$ORBIT_PYTHON"
    return
  fi
  for candidate in /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done
  error "Homebrew Python 3.13 not found. Install: brew install python@3.13"
}

probe_sqlite_extensions() {
  local py="$1"
  "$py" -c "import sqlite3; sqlite3.connect(':memory:').enable_load_extension(True)" 2>/dev/null
}

free_gb() {
  df -g "$(dirname "$ORBIT_OUTPUT")" 2>/dev/null | awk 'NR==2 {print $4}'
}

ORBIT_PYTHON="$(resolve_python)"
if ! probe_sqlite_extensions "$ORBIT_PYTHON"; then
  error "Python at $ORBIT_PYTHON lacks loadable SQLite extensions (use Homebrew python@3.13)."
fi

FREE_GB="$(free_gb || echo 0)"
if [[ "${FREE_GB:-0}" -lt 5 ]]; then
  status "WARNING: less than 5 GB free on target volume (have ${FREE_GB}G). Build may fail."
fi

[[ -f "$SOURCE_ROOT/pyproject.toml" ]] || error "Source root missing pyproject.toml: $SOURCE_ROOT"

FINAL_OUTPUT="$ORBIT_OUTPUT"
STAGING=""

status "Building Orbit.app at $FINAL_OUTPUT"
if [[ "$FINAL_OUTPUT" == /Applications/* ]]; then
  STAGING="$(mktemp -d)/Orbit.app"
  ORBIT_OUTPUT="$STAGING"
  status "Staging build in $STAGING (moves to $FINAL_OUTPUT when complete)…"
else
  ORBIT_OUTPUT="$FINAL_OUTPUT"
fi

RESOURCES="$ORBIT_OUTPUT/Contents/Resources"
MACOS="$ORBIT_OUTPUT/Contents/MacOS"
VENV="$RESOURCES/orbit-venv"
ORBIT_CORE="$RESOURCES/orbit-core"
CLI_WRAPPER="$RESOURCES/orbit"

cleanup_staging() {
  if [[ -n "${STAGING:-}" && -d "$STAGING" ]]; then
    rm -rf "$STAGING"
  fi
}
trap cleanup_staging EXIT

rm -rf "$ORBIT_OUTPUT"
mkdir -p "$MACOS" "$RESOURCES" "$ORBIT_CORE/docs/gdpr"

status "Creating embedded Python venv…"
"$ORBIT_PYTHON" -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
status "Upgrading pip…"
pip install --upgrade pip
status "Installing Orbit into venv (PyTorch + sentence-transformers; often 5–15 min, downloads ~1–2 GB)…"
pip install "$SOURCE_ROOT"

status "Verifying embedded package data…"
SCHEMA="$VENV/lib/python3.13/site-packages/orbit/storage/schema.sql"
if [[ ! -f "$SCHEMA" ]]; then
  echo "ERROR: schema.sql missing from embedded venv ($SCHEMA)." >&2
  echo "Ensure pyproject.toml [tool.setuptools.package-data] ships storage/schema.sql." >&2
  exit 1
fi

# A non-editable install has no repo above it, so the embedded daemon cannot ask git which build
# it is. Record it beside the package; _recorded_build_sha() in browser_bridge/server.py reads it.
INSTALLED_SHA="$(orbit_build_sha "$SOURCE_ROOT")"
if [[ -n "$INSTALLED_SHA" ]]; then
  printf '%s\n' "$INSTALLED_SHA" >"$VENV/lib/python3.13/site-packages/orbit/BUILD_SHA"
  status "Recorded build SHA $INSTALLED_SHA in the embedded package."
else
  status "WARNING: $SOURCE_ROOT is not a git checkout; the embedded daemon cannot report a build SHA."
fi

status "Smoke-testing DB open…"
# ORBIT_DB_KEY bypasses the real macOS Keychain (orbit/storage/crypto.py) — this
# just opens a throwaway temp DB to prove the schema applies; it must not create
# or read a persistent Keychain entry on the build machine.
ORBIT_DB_KEY="build-app-bundle-smoke-test-key" "$VENV/bin/python3.13" -c "import tempfile, os; from orbit.storage.db import open_db_plain; open_db_plain(os.path.join(tempfile.mkdtemp(),'t.db')); print('db ok')"

status "Copying docs into orbit-core…"
# Two layouts are supported on purpose. The development tree keeps drafting templates
# alongside the policy in docs/gdpr/; the public distribution repo publishes the finished
# documents flat in docs/, because that is the path shipped builds link to from the About
# panel and those URLs must not move. Copying whichever exists lets one build script serve
# both trees — without this, a flat-docs checkout died here under `set -e` with
# "cp: docs/gdpr/.: No such file or directory" after the whole Swift compile had run.
if [[ -d "$SOURCE_ROOT/docs/gdpr" ]]; then
  cp -R "$SOURCE_ROOT/docs/gdpr/." "$ORBIT_CORE/docs/gdpr/"
elif [[ -d "$SOURCE_ROOT/docs" ]]; then
  cp -R "$SOURCE_ROOT/docs/." "$ORBIT_CORE/docs/gdpr/"
else
  error "No docs/ directory found at $SOURCE_ROOT — the privacy policy must ship inside the bundle"
fi

status "Writing CLI wrapper…"
cat >"$CLI_WRAPPER" <<'WRAPPER'
#!/usr/bin/env bash
RESOURCES="$(cd "$(dirname "$0")" && pwd)"
export ORBIT_ROOT="$RESOURCES/orbit-core"
exec "$RESOURCES/orbit-venv/bin/python3.13" -m orbit "$@"
WRAPPER
chmod +x "$CLI_WRAPPER"

SWIFT_BIN=""
if [[ "$ORBIT_SKIP_SWIFT" != "1" ]]; then
  cd "$APP_DIR"
  if ! swift build -c release 2>&1; then
    status "Release build failed; falling back to debug…"
    SWIFT_CONFIG="debug"
    swift build -c debug 2>&1
  fi
  SWIFT_BIN="$APP_DIR/.build/$SWIFT_CONFIG/OrbitAccessApp"
  [[ -f "$SWIFT_BIN" ]] || error "Swift binary not found at $SWIFT_BIN"
  cp "$SWIFT_BIN" "$MACOS/Orbit"
  chmod +x "$MACOS/Orbit"

  if [[ -f "$APP_DIR/Resources/Info.bundle.plist" ]]; then
    cp "$APP_DIR/Resources/Info.bundle.plist" "$ORBIT_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Orbit" "$ORBIT_OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Orbit" "$ORBIT_OUTPUT/Contents/Info.plist"

    # Stamp the marketing version from orbit/__init__.py, the single source of truth
    # that pyproject.toml already AST-reads. Info.bundle.plist carries a static
    # "1.0", so before this a v0.1.0 release shipped an About panel reading
    # "Orbit 1.0 (1)" — and a tester quoting that version in a bug report would
    # send you looking at the wrong build. Derived rather than duplicated so the
    # two cannot drift apart again.
    ORBIT_PKG_VERSION="$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$SOURCE_ROOT/orbit/__init__.py" | head -1)"
    if [[ -n "$ORBIT_PKG_VERSION" ]]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ORBIT_PKG_VERSION" "$ORBIT_OUTPUT/Contents/Info.plist"
      status "Bundle version: $ORBIT_PKG_VERSION"
    else
      status "WARNING: could not read __version__; leaving CFBundleShortVersionString as-is"
    fi
    stamp_orbit_build_identity "$ORBIT_OUTPUT/Contents/Info.plist" "$SOURCE_ROOT" "$BUILD_STARTED_AT"
    status "Build identity: $(format_build_identity "$ORBIT_BUILD_SHA" "$ORBIT_BUILD_DIRTY")"
    if [[ -n "${ORBIT_RELAY_URL:-}" ]]; then
      status "Injecting ORBIT_RELAY_URL into LSEnvironment ($ORBIT_RELAY_URL)…"
      set_plist_lsenvironment "$ORBIT_OUTPUT/Contents/Info.plist" ORBIT_RELAY_URL "$ORBIT_RELAY_URL"
    fi
    # Cloud sign-in reads ORBIT_CLOUD_AUTH_ENABLED from the process environment
    # (UserAuthService.swift:335-341), and a double-clicked .app inherits no shell
    # environment — LSEnvironment is the only channel that reaches it.
    #
    # Until now only run_orbit_access_app.sh set this key, so a *release* bundle had
    # no way to enable cloud sign-in at all: the flag read absent, defaulted false,
    # and the sign-in UI stayed hidden no matter how the app was built or deployed.
    # Release builds could therefore never offer accounts, which is precisely what
    # the relay exists to serve.
    #
    # Default stays 0 — an undeployed relay must never surface sign-in UI (decision
    # D2: the app is a complete local-only product). Turn on deliberately, and only
    # together with a relay URL:
    #   ORBIT_CLOUD_AUTH_ENABLED=1 ORBIT_RELAY_URL=https://… scripts/build-app-bundle.sh …
    status "Setting ORBIT_CLOUD_AUTH_ENABLED=${ORBIT_CLOUD_AUTH_ENABLED:-0} in LSEnvironment…"
    set_plist_lsenvironment "$ORBIT_OUTPUT/Contents/Info.plist" ORBIT_CLOUD_AUTH_ENABLED \
      "${ORBIT_CLOUD_AUTH_ENABLED:-0}"
  else
    error "Missing Info.bundle.plist"
  fi

  install_orbit_access_bundle_resources "$APP_DIR" "$ORBIT_OUTPUT" "$SWIFT_CONFIG"

  ENTITLEMENTS="$APP_DIR/OrbitAccessApp.entitlements"
  if [[ -f "$ENTITLEMENTS" ]]; then
    status "Codesigning (ad-hoc)…"
    codesign_orbit_access_bundle "$ORBIT_OUTPUT" Orbit "$ENTITLEMENTS" \
      || status "WARNING: codesign failed; app icon and sandbox entitlements may be missing."
  fi
else
  status "Skipping Swift build (ORBIT_SKIP_SWIFT=1)"
fi

status "Running orbit doctor…"
"$CLI_WRAPPER" doctor

if [[ -n "$STAGING" ]]; then
  status "Installing to ${FINAL_OUTPUT}…"
  rm -rf "$FINAL_OUTPUT"
  mv "$STAGING" "$FINAL_OUTPUT"
  trap - EXIT
  STAGING=""
fi

status "Done: $FINAL_OUTPUT"
if [[ -n "$SWIFT_BIN" ]]; then
  status "Launch with: open \"$FINAL_OUTPUT\""
fi
status "CLI: \"$FINAL_OUTPUT/Contents/Resources/orbit\""
